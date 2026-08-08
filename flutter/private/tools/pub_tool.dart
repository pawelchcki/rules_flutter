// Build-action helper for rules_flutter, run with the toolchain SDK's own
// `dart` binary — which is already a declared input of every action that needs
// it. This replaces the embedded Python that the action scripts used to pipe
// into a host `python3`, removing an undeclared host tool from the build.
//
// Subcommands:
//   package-config     write .dart_tool/package_config.json and
//                      package_graph.json from the workspace's pubspec.lock
//   resolve-entrypoint print a `package:executable` command's bin/<exe>.dart path
//   pubspec-info       print "name|version|sdk constraint" for a pubspec.yaml
//   strip-pubspec      remove whole top-level sections from a pubspec.yaml
//   rewrite-path-deps  point path dependencies at their staged cache copies
//   has-package        exit 0 iff a pubspec.lock lists the named package

import 'dart:convert';
import 'dart:io';

void fail(String message) {
  stderr.writeln(message);
  exit(1);
}

String env(String name) {
  final value = Platform.environment[name];
  if (value == null || value.isEmpty) {
    fail('rules_flutter pub_tool: required environment variable $name is unset');
  }
  return value as String;
}

/// The `sdk:` constraint from a pubspec's `environment:` block, or null.
String? readLanguageSpec(String rootPath) {
  final pubspec = File('$rootPath/pubspec.yaml');
  if (!pubspec.existsSync()) return null;
  var capture = false;
  for (final line in pubspec.readAsLinesSync()) {
    final stripped = line.trim();
    if (stripped.startsWith('environment:')) {
      capture = true;
      continue;
    }
    if (!capture) continue;
    if (stripped.startsWith('sdk:')) {
      return unquote(stripped.split(':').sublist(1).join(':').trim());
    }
    if (stripped.isNotEmpty &&
        !stripped.startsWith('#') &&
        !stripped.startsWith('flutter:') &&
        !stripped.startsWith('flutter_test:') &&
        !stripped.startsWith('dart:')) {
      break;
    }
  }
  return null;
}

/// The `name:` of a pubspec.yaml, or null when there is none.
String? readPubspecName(String rootPath) {
  final pubspec = File('$rootPath/pubspec.yaml');
  if (!pubspec.existsSync()) return null;
  for (final line in pubspec.readAsLinesSync()) {
    final stripped = line.trim();
    if (stripped.startsWith('#')) continue;
    if (stripped.startsWith('name:')) {
      return unquote(stripped.substring('name:'.length));
    }
  }
  return null;
}

String unquote(String value) {
  var out = value.trim();
  if (out.length >= 2 &&
      ((out.startsWith('"') && out.endsWith('"')) ||
          (out.startsWith("'") && out.endsWith("'")))) {
    out = out.substring(1, out.length - 1);
  }
  return out;
}

/// "major.minor" language version from an SDK constraint like ">=3.0.0 <4.0.0".
String parseLanguage(String? spec) {
  if (spec == null || spec.isEmpty) return '3.0';
  final tokens = spec
      .replaceAll('>=', ' ')
      .replaceAll('<=', ' ')
      .replaceAll('>', ' ')
      .replaceAll('<', ' ')
      .replaceAll('^', ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .toList();
  if (tokens.isEmpty) return '3.0';
  final parts = tokens.first.split('+').first.split('.');
  final numeric = <String>[];
  for (final part in parts) {
    if (part.isNotEmpty && int.tryParse(part) != null) {
      numeric.add(part);
    } else {
      break;
    }
  }
  if (numeric.length >= 2) return '${numeric[0]}.${numeric[1]}';
  if (numeric.length == 1) return '${numeric[0]}.0';
  return '3.0';
}

/// `path:` dependency locations declared in a pubspec.
///
/// `flutter pub deps --json` reports source == "path" but omits where the
/// package lives, so recover the location from the pubspec declaring it.
Map<String, String> pathDepsFromPubspec(String rootPath) {
  final locations = <String, String>{};
  final pubspec = File('$rootPath/pubspec.yaml');
  if (!pubspec.existsSync()) return locations;

  var inDeps = false;
  String? current;
  for (final line in pubspec.readAsLinesSync()) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final indent = line.length - line.trimLeft().length;
    final stripped = line.trim();
    if (indent == 0) {
      inDeps = stripped.startsWith('dependencies:') ||
          stripped.startsWith('dev_dependencies:');
      current = null;
    } else if (!inDeps) {
      continue;
    } else if (indent <= 2) {
      current = stripped.endsWith(':')
          ? stripped.substring(0, stripped.length - 1)
          : null;
    } else if (current != null && stripped.startsWith('path:')) {
      locations[current] = unquote(stripped.split(':').sublist(1).join(':'));
    }
  }
  return locations;
}

String relativeTo(String target, String base) {
  final targetParts = _absoluteParts(target);
  final baseParts = _absoluteParts(base);
  var shared = 0;
  while (shared < targetParts.length &&
      shared < baseParts.length &&
      targetParts[shared] == baseParts[shared]) {
    shared++;
  }
  final up = List.filled(baseParts.length - shared, '..');
  final rest = targetParts.sublist(shared);
  final joined = [...up, ...rest].join('/');
  return joined.isEmpty ? '.' : joined;
}

List<String> _absoluteParts(String path) =>
    path.split('/').where((p) => p.isNotEmpty && p != '.').toList();

/// One `packages:` entry of a `pubspec.lock`.
class LockPackage {
  LockPackage(this.name);

  final String name;
  String dependency = '';
  String source = '';
  String version = '';

  /// Nested `description:` map. Empty when the description is a bare scalar.
  final Map<String, String> description = <String, String>{};

  /// `description: dart` — the scalar form used by sdk sources.
  String scalar = '';

  String get path => description['path'] ?? '';
  String get url => description['url'] ?? '';
}

/// Parse a `pubspec.lock`.
///
/// pub writes the lock with fixed two-space indentation and a stable key
/// order, and this tool runs with no package config (so no `package:yaml`).
/// A line-based scanner keyed on that indentation is therefore both
/// sufficient and the only option. `flutter/private/pubspec_lock.bzl` is the
/// Starlark counterpart and is kept structurally parallel; change them
/// together.
///
///     packages:
///       collection:
///         dependency: transitive
///         description:
///           name: collection
///           sha256: "a1ace0a..."
///           url: "https://pub.dev"
///         source: hosted
///         version: "1.19.0"
Map<String, LockPackage> readLock(String lockPath) {
  final file = File(lockPath);
  if (!file.existsSync()) fail('pubspec.lock not found: $lockPath');

  final packages = <String, LockPackage>{};
  var section = '';
  var sawPackages = false;
  LockPackage? current;
  var inDescription = false;

  for (final line in file.readAsLinesSync()) {
    final stripped = line.trim();
    if (stripped.isEmpty || stripped.startsWith('#')) continue;
    final indent = line.length - line.replaceFirst(RegExp(r'^ *'), '').length;

    if (indent == 0) {
      section = stripped.split(':').first;
      if (section == 'packages') sawPackages = true;
      current = null;
      inDescription = false;
      continue;
    }
    if (section != 'packages') continue;

    if (indent == 2) {
      inDescription = false;
      if (!stripped.endsWith(':')) {
        current = null;
        continue;
      }
      final name = stripped.substring(0, stripped.length - 1);
      current = LockPackage(name);
      packages[name] = current;
      continue;
    }
    if (current == null) continue;

    final colon = stripped.indexOf(':');
    if (colon < 0) continue;
    final key = stripped.substring(0, colon);
    final value = unquote(stripped.substring(colon + 1));

    if (indent == 4) {
      if (key == 'description') {
        inDescription = value.isEmpty;
        current.scalar = value;
      } else {
        inDescription = false;
        if (key == 'dependency') current.dependency = value;
        if (key == 'source') current.source = value;
        if (key == 'version') current.version = value;
      }
    } else if (indent >= 6 && inDescription) {
      current.description[key] = value;
    }
  }

  if (!sawPackages) {
    fail('$lockPath is not a pubspec.lock (no top-level `packages:` key)');
  }
  return packages;
}

/// Names listed under `dependencies:` / `dev_dependencies:` of a pubspec.yaml.
///
/// `pubspec.lock` records no dependency edges, but `package_graph.json` (read
/// by newer flutter_tools) needs them. Every resolved package's directory is
/// present by construction — it is what `package_config.json` points at — so
/// the edges are read back from the pubspecs there.
Map<String, List<String>> readDependencyNames(String rootPath) {
  final result = {'dependencies': <String>[], 'dev_dependencies': <String>[]};
  final pubspec = File('$rootPath/pubspec.yaml');
  if (!pubspec.existsSync()) return result;

  String? section;
  for (final line in pubspec.readAsLinesSync()) {
    if (line.trim().isEmpty || line.trimLeft().startsWith('#')) continue;
    final indent = line.length - line.trimLeft().length;
    final stripped = line.trim();
    if (indent == 0) {
      final key = stripped.split(':').first;
      section = result.containsKey(key) ? key : null;
    } else if (section != null && indent <= 2) {
      final colon = stripped.indexOf(':');
      if (colon > 0) result[section]!.add(stripped.substring(0, colon));
    }
  }
  return result;
}

void packageConfig() {
  final lockPath = env('PUBSPEC_LOCK_PATH');
  final cacheRoot = env('PUB_CACHE_ABS');
  final workspaceRoot = env('WORKSPACE_ABS');
  final configPath = env('PACKAGE_CONFIG_PATH');
  final configDir = File(configPath).parent.path;

  final languageOverride = Platform.environment['ROOT_LANGUAGE_SPEC'];
  final defaultLanguage = parseLanguage(
      (languageOverride != null && languageOverride.isNotEmpty)
          ? languageOverride
          : readLanguageSpec(workspaceRoot));

  // A package without its own `environment: sdk:` inherits the root's.
  String packageLanguage(String rootPath) {
    final spec = readLanguageSpec(rootPath);
    return spec == null ? defaultLanguage : parseLanguage(spec);
  }

  final entries = readLock(lockPath);

  // Directory each package resolved to, in the order they were added — the
  // package_graph.json edges below are read back from the pubspecs there.
  final resolvedRoots = <String, String>{};

  final packages = <Map<String, dynamic>>[];
  void addPackage(String? name, String? rootPath) {
    if (name == null ||
        name.isEmpty ||
        rootPath == null ||
        rootPath.isEmpty ||
        !Directory(rootPath).existsSync()) {
      return;
    }
    resolvedRoots[name] = rootPath;
    var rel = relativeTo(rootPath, configDir);
    if (rel != '.' && !rel.endsWith('/')) rel = '$rel/';
    packages.add({
      'name': name,
      'rootUri': rel,
      'packageUri': 'lib/',
      'languageVersion': packageLanguage(rootPath),
    });
  }

  final pathDepLocations = pathDepsFromPubspec(workspaceRoot);

  // A lock describes the root's closure but has no entry for the root itself,
  // so its identity comes from the pubspec that is already an action input.
  // Only the name is needed: package_config entries carry no version.
  final rootName = Platform.environment['ROOT_PACKAGE_NAME']?.isNotEmpty == true
      ? Platform.environment['ROOT_PACKAGE_NAME'] as String
      : readPubspecName(workspaceRoot);
  if (rootName == null || rootName.isEmpty) {
    fail('Unable to determine the root package name from '
        '$workspaceRoot/pubspec.yaml or ROOT_PACKAGE_NAME');
  }
  addPackage(rootName, workspaceRoot);

  final missing = <String>[];
  for (final entry in entries.values) {
    final name = entry.name;
    final version = entry.version;

    if (entry.source == 'hosted' && version.isNotEmpty) {
      final dir = '$cacheRoot/hosted/pub.dev/$name-$version';
      addPackage(name, dir);

      // addPackage silently skips a directory that is not there, which would
      // otherwise surface much later as an opaque Dart "Target of URI doesn't
      // exist". For a library that assembles the full closure, that is the
      // hub's core invariant and worth failing on — see the guard below.
      if (!resolvedRoots.containsKey(name)) missing.add('$name ($dir)');
    } else if (entry.source == 'sdk') {
      final flutterRoot = env('FLUTTER_ROOT');
      if (name == 'sky_engine') {
        addPackage(name, '$flutterRoot/bin/cache/pkg/$name');
      } else if (name == '_macros') {
        addPackage(name, '$flutterRoot/bin/cache/dart-sdk/pkg/$name');
      } else {
        addPackage(name, '$flutterRoot/packages/$name');
      }
    } else if (entry.source == 'path') {
      // A path dependency lives outside the depending package's directory, so
      // it cannot be staged inside that package's prepared workspace tree. The
      // depended-on flutter_library republishes its workspace into the
      // assembled cache at path/<name>/ instead. Prefer that staged copy, and
      // fall back to the source tree for workspaces Bazel did not stage.
      final staged = '$cacheRoot/path/$name';
      if (Directory(staged).existsSync()) {
        addPackage(name, staged);
      } else {
        var pathValue = entry.path;
        if (pathValue.isEmpty) pathValue = pathDepLocations[name] ?? '';
        if (pathValue.isNotEmpty) {
          addPackage(name, File('$workspaceRoot/$pathValue').absolute.path);
        }
      }
    } else if (entry.source == 'git') {
      fail('$lockPath pins $name from a git source, which rules_flutter does '
          'not support. Use a hosted or path dependency.');
    }
  }

  if (missing.isNotEmpty &&
      Platform.environment['REQUIRE_COMPLETE_PUB_CACHE'] == '1') {
    fail('The assembled pub cache is missing ${missing.length} package(s) '
        'pinned by $lockPath:\n  ${missing.join('\n  ')}\n'
        'The library\'s deps must include the hub for this lock '
        '(@<hub>//:all).');
  }

  _writeJson(configPath, {
    'configVersion': 2,
    'generated': true,
    'generator': 'rules_flutter',
    'packages': packages,
  });

  // Newer flutter_tools also require .dart_tool/package_graph.json (normally
  // written by `pub get`). The lock records no edges, so they are read back
  // from each resolved package's own pubspec.yaml.
  final graphPackages = <Map<String, dynamic>>[];
  for (final name in resolvedRoots.keys) {
    final declared = readDependencyNames(resolvedRoots[name] as String);
    final node = <String, dynamic>{
      'name': name,
      'version': name == rootName ? '0.0.0' : entries[name]?.version ?? '0.0.0',
      'dependencies': declared['dependencies']!
          .where(resolvedRoots.containsKey)
          .toList(),
    };
    if (name == rootName) {
      node['devDependencies'] =
          declared['dev_dependencies']!.where(resolvedRoots.containsKey).toList();
    }
    graphPackages.add(node);
  }
  _writeJson('$configDir/package_graph.json', {
    'configVersion': 1,
    'roots': [rootName],
    'packages': graphPackages,
  });
}

void _writeJson(String path, Object value) {
  File(path)
      .writeAsStringSync('${const JsonEncoder.withIndent('  ').convert(value)}\n');
}

void resolveEntrypoint() {
  var command = env('CODEGEN_CMD');
  final configPath = env('PACKAGE_CONFIG_PATH');
  final configDir = File(configPath).parent.path;

  if (command.startsWith('package:')) {
    command = command.substring('package:'.length);
  }
  final colon = command.indexOf(':');
  final package = colon == -1 ? command : command.substring(0, colon);
  final executable = colon == -1 ? command : command.substring(colon + 1);
  if (package.isEmpty || executable.isEmpty) {
    fail('Invalid generator command: ${env('CODEGEN_CMD')}');
  }

  final config =
      json.decode(File(configPath).readAsStringSync()) as Map<String, dynamic>;
  String? rootUri;
  for (final raw in (config['packages'] as List?) ?? const []) {
    final entry = raw as Map<String, dynamic>;
    if (entry['name'] == package) {
      rootUri = entry['rootUri'] as String?;
      break;
    }
  }
  if (rootUri == null || rootUri.isEmpty) {
    fail("Package '$package' not found in $configPath");
  }

  final uri = rootUri as String;
  final parsed = Uri.parse(uri);
  String rootPath;
  if (parsed.scheme == 'file') {
    rootPath = parsed.toFilePath();
  } else if (parsed.scheme.isNotEmpty) {
    fail("Unsupported package root URI for '$package': $uri");
    return;
  } else {
    rootPath = File('$configDir/${Uri.decodeComponent(uri)}').absolute.path;
  }

  final entrypoint = '$rootPath/bin/$executable.dart';
  if (!File(entrypoint).existsSync()) {
    fail('Codegen entrypoint not found: $entrypoint');
  }
  stdout.writeln(entrypoint);
}

void pubspecInfo() {
  final path = env('PUBSPEC_PATH');
  var name = '';
  var version = '';
  final file = File(path);
  if (file.existsSync()) {
    for (final line in file.readAsLinesSync()) {
      final stripped = line.trim();
      if (stripped.startsWith('#')) continue;
      if (stripped.startsWith('name:') && name.isEmpty) {
        name = unquote(stripped.substring('name:'.length));
      } else if (stripped.startsWith('version:') && version.isEmpty) {
        version = unquote(stripped.substring('version:'.length));
      } else if (stripped.startsWith('environment:')) {
        break;
      }
    }
  }
  stdout.writeln('$name|$version|${readLanguageSpec(file.parent.path) ?? ''}');
}

void stripPubspec() {
  final path = env('PUBSPEC_PATH');
  final sections = (Platform.environment['PUBSPEC_SECTIONS'] ?? '')
      .split(RegExp(r'\s+'))
      .where((s) => s.isNotEmpty)
      .toSet();
  final file = File(path);
  if (sections.isEmpty || !file.existsSync()) return;

  final output = <String>[];
  var skip = false;
  var skipIndent = 0;
  for (final line in file.readAsLinesSync()) {
    final stripped = line.trimRight();
    final indent = line.length - line.replaceFirst(RegExp(r'^ *'), '').length;
    if (skip) {
      if (stripped.isNotEmpty &&
          !stripped.startsWith('#') &&
          indent <= skipIndent) {
        skip = false;
      } else {
        continue;
      }
    }
    final key = stripped.endsWith(':')
        ? stripped.substring(0, stripped.length - 1)
        : stripped;
    if (stripped.endsWith(':') && sections.contains(key)) {
      skip = true;
      skipIndent = indent;
      continue;
    }
    output.add(line);
  }
  file.writeAsStringSync(output.isEmpty ? '' : '${output.join('\n')}\n');
}

void rewritePathDeps() {
  final workspace = env('WORKSPACE_ABS');
  final cache = env('PUB_CACHE_ABS');
  final file = File('$workspace/pubspec.yaml');
  if (!file.existsSync()) return;

  final output = <String>[];
  var inDeps = false;
  String? current;
  for (final line in file.readAsLinesSync()) {
    final stripped = line.trim();
    final indent = line.length - line.trimLeft().length;
    if (indent == 0 && stripped.isNotEmpty && !stripped.startsWith('#')) {
      inDeps = stripped == 'dependencies:' || stripped == 'dev_dependencies:';
      current = null;
    } else if (inDeps && indent <= 2 && stripped.endsWith(':')) {
      current = stripped.substring(0, stripped.length - 1);
    }

    if (inDeps && current != null && indent > 2 && stripped.startsWith('path:')) {
      final staged = Directory('$cache/path/$current');
      if (staged.existsSync()) {
        output.add('${' ' * indent}path: "${staged.absolute.path}"');
        continue;
      }
    }
    output.add(line);
  }
  file.writeAsStringSync('${output.join('\n')}\n');
}

void hasPackage(List<String> args) {
  if (args.length != 2) {
    fail('has-package takes <pubspec.lock> <package name>');
  }
  exit(readLock(args[0]).containsKey(args[1]) ? 0 : 1);
}

void main(List<String> args) {
  if (args.isEmpty) fail('rules_flutter pub_tool: missing subcommand');
  final rest = args.sublist(1);
  switch (args.first) {
    case 'package-config':
      packageConfig();
    case 'resolve-entrypoint':
      resolveEntrypoint();
    case 'pubspec-info':
      pubspecInfo();
    case 'strip-pubspec':
      stripPubspec();
    case 'rewrite-path-deps':
      rewritePathDeps();
    case 'has-package':
      hasPackage(rest);
    default:
      fail('rules_flutter pub_tool: unknown subcommand ${args.first}');
  }
}
