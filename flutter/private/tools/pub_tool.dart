// Build-action helper for rules_flutter, run with the toolchain SDK's own
// `dart` binary — which is already a declared input of every action that needs
// it. This replaces the embedded Python that the action scripts used to pipe
// into a host `python3`, removing an undeclared host tool from the build.
//
// Subcommands:
//   package-config     write .dart_tool/package_config.json (+ package_graph.json,
//                      optionally pubspec.lock) from pub_deps.json metadata
//   resolve-entrypoint print a `package:executable` command's bin/<exe>.dart path
//   pubspec-info       print "name|version|sdk constraint" for a pubspec.yaml
//   strip-pubspec      remove whole top-level sections from a pubspec.yaml
//   normalize-pub-deps strip leading junk from pub_deps.json and validate it
//   merge-pub-deps     rewrite a raw `pub deps --json` report into pub_deps.json,
//                      folding each hosted package's sha256 in from pubspec.lock
//   has-package        exit 0 iff pub_deps.json lists the named package

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

void packageConfig() {
  final depsPath = env('PUB_DEPS_PATH');
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

  final data =
      json.decode(File(depsPath).readAsStringSync()) as Map<String, dynamic>;
  final entries = (data['packages'] as List?) ?? const [];

  final packages = <Map<String, dynamic>>[];
  void addPackage(String? name, String? rootPath) {
    if (name == null ||
        name.isEmpty ||
        rootPath == null ||
        rootPath.isEmpty ||
        !Directory(rootPath).existsSync()) {
      return;
    }
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

  for (final raw in entries) {
    final entry = raw as Map<String, dynamic>;
    final name = entry['name'] as String?;
    final source = entry['source'];
    final version = entry['version'] as String?;
    final description = entry['description'];
    if (name == null || name.isEmpty) continue;

    if (source == 'hosted' && version != null && version.isNotEmpty) {
      addPackage(name, '$cacheRoot/hosted/pub.dev/$name-$version');
    } else if (source == 'root') {
      addPackage(name, workspaceRoot);
    } else if (source == 'sdk') {
      final flutterRoot = env('FLUTTER_ROOT');
      if (name == 'sky_engine') {
        addPackage(name, '$flutterRoot/bin/cache/pkg/$name');
      } else if (name == '_macros') {
        addPackage(name, '$flutterRoot/bin/cache/dart-sdk/pkg/$name');
      } else {
        addPackage(name, '$flutterRoot/packages/$name');
      }
    } else if (source == 'path') {
      // A path dependency lives outside the depending package's directory, so
      // it cannot be staged inside that package's prepared workspace tree. The
      // depended-on flutter_library republishes its workspace into the
      // assembled cache at path/<name>/ instead. Prefer that staged copy, and
      // fall back to the source tree for workspaces Bazel did not stage.
      final staged = '$cacheRoot/path/$name';
      if (Directory(staged).existsSync()) {
        addPackage(name, staged);
      } else {
        var pathValue = '';
        if (description is String) {
          pathValue = description;
        } else if (description is Map) {
          pathValue = (description['path'] as String?) ?? '';
        }
        if (pathValue.isEmpty) pathValue = pathDepLocations[name] ?? '';
        if (pathValue.isNotEmpty) {
          addPackage(
              name, File('$workspaceRoot/$pathValue').absolute.path);
        }
      }
    }
  }

  _writeJson(configPath, {
    'configVersion': 2,
    'generated': true,
    'generator': 'rules_flutter',
    'packages': packages,
  });

  // Synthesize a minimal pubspec.lock when the package does not ship one:
  // build_runner's package graph requires it to classify dependencies
  // (direct main / direct dev / transitive), which pub_deps.json records as
  // "kind". Opt-in, because read-only workspaces must not be written to.
  final lockPath = '$workspaceRoot/pubspec.lock';
  if (Platform.environment['SYNTHESIZE_PUBSPEC_LOCK'] == '1' &&
      !File(lockPath).existsSync()) {
    const kinds = {
      'direct': 'direct main',
      'dev': 'direct dev',
      'transitive': 'transitive',
    };
    final lines = <String>[
      '# Generated by rules_flutter from pub_deps.json.',
      'packages:',
    ];
    for (final raw in entries) {
      final entry = raw as Map<String, dynamic>;
      final name = entry['name'] as String?;
      final source = entry['source'];
      final version = (entry['version'] as String?) ?? '0.0.0';
      if (name == null || name.isEmpty || source == 'root') continue;
      lines.add('  $name:');
      lines.add(
          '    dependency: "${kinds[entry['kind'] ?? 'transitive'] ?? 'transitive'}"');
      if (source == 'sdk') {
        lines.add('    source: sdk');
        lines.add('    description: "flutter"');
      } else if (source == 'path') {
        final description = entry['description'];
        var pathValue = '';
        if (description is String) {
          pathValue = description;
        } else if (description is Map) {
          pathValue = (description['path'] as String?) ?? '';
        }
        if (pathValue.isEmpty) pathValue = pathDepLocations[name] ?? '';
        lines.add('    source: path');
        lines.add('    description:');
        lines.add('      path: "$pathValue"');
        lines.add('      relative: true');
      } else {
        lines.add('    source: hosted');
        lines.add('    description:');
        lines.add('      name: "$name"');
        lines.add('      url: "https://pub.dev"');
      }
      lines.add('    version: "$version"');
    }
    lines.add('sdks:');
    lines.add('  dart: ">=3.0.0 <4.0.0"');
    File(lockPath).writeAsStringSync('${lines.join('\n')}\n');
  }

  // Newer flutter_tools also require .dart_tool/package_graph.json (normally
  // written by `pub get`).
  String? rootName;
  final graphPackages = <Map<String, dynamic>>[];
  for (final raw in entries) {
    final entry = raw as Map<String, dynamic>;
    final name = entry['name'] as String?;
    if (name == null || name.isEmpty) continue;
    if (entry['source'] == 'root') rootName = name;
    final node = <String, dynamic>{
      'name': name,
      'version': (entry['version'] as String?) ?? '0.0.0',
      'dependencies': ((entry['dependencies'] as List?) ?? const [])
          .whereType<String>()
          .toList(),
    };
    if (entry['source'] == 'root') node['devDependencies'] = <String>[];
    graphPackages.add(node);
  }
  _writeJson('$configDir/package_graph.json', {
    'configVersion': 1,
    'roots': rootName == null ? <String>[] : [rootName],
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

void normalizePubDeps() {
  final path = env('PUB_DEPS_PATH');
  final file = File(path);
  if (!file.existsSync()) return;
  var payload = file.readAsStringSync();
  final start = payload.indexOf(RegExp(r'[\[{]'));
  if (start > 0) {
    payload = payload.substring(start);
    file.writeAsStringSync(payload);
  }
  final data = json.decode(payload);
  if (data is! Map || data['packages'] is! List) {
    fail('pub_deps.json must contain a packages list');
  }
}

/// Parse the `sha256` of every hosted package out of a `pubspec.lock`.
///
/// pub writes the lock with fixed two-space indentation and a stable key
/// order, and this tool runs with no package config (so no `package:yaml`).
/// A line-based scanner keyed on that indentation is therefore both
/// sufficient and the only option, in the style of [readLanguageSpec]:
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
Map<String, String> readLockHashes(String lockPath) {
  final file = File(lockPath);
  final hashes = <String, String>{};
  if (!file.existsSync()) return hashes;

  var inPackages = false;
  String? package;
  var inDescription = false;
  for (final line in file.readAsLinesSync()) {
    if (line.trimRight().isEmpty || line.trimLeft().startsWith('#')) continue;
    final indent = line.length - line.replaceFirst(RegExp(r'^ *'), '').length;
    final stripped = line.trim();

    if (indent == 0) {
      inPackages = stripped == 'packages:';
      package = null;
      inDescription = false;
      continue;
    }
    if (!inPackages) continue;

    if (indent == 2) {
      package = stripped.endsWith(':')
          ? stripped.substring(0, stripped.length - 1)
          : null;
      inDescription = false;
      continue;
    }
    if (indent == 4) {
      inDescription = stripped == 'description:';
      continue;
    }
    if (indent >= 6 && inDescription && package != null && stripped.startsWith('sha256:')) {
      final value = unquote(stripped.substring('sha256:'.length));
      if (value.isNotEmpty) hashes[package as String] = value;
    }
  }
  return hashes;
}

/// merge-pub-deps <raw pub deps json> <pubspec.lock> <output pub_deps.json>
///
/// The lock's `description.sha256` *is* the sha256 of the `.tar.gz` that
/// `pub_dev_repository` downloads, so recording it here pins every fetch by
/// construction. The caller must run `pub get` first: a stale lock would pin
/// hashes that do not match the versions in the report.
void mergePubDeps(List<String> args) {
  if (args.length != 3) {
    fail('merge-pub-deps takes <raw json> <pubspec.lock> <output>');
  }
  var payload = File(args[0]).readAsStringSync();
  final start = payload.indexOf(RegExp(r'[\[{]'));
  if (start < 0) fail('pub deps did not produce JSON');
  if (start > 0) payload = payload.substring(start);

  final data = json.decode(payload);
  if (data is! Map || data['packages'] is! List) {
    fail('pub deps JSON missing packages list');
  }

  final hashes = readLockHashes(args[1]);
  for (final raw in (data as Map)['packages'] as List) {
    if (raw is! Map) continue;
    if (raw['source'] != 'hosted') continue;
    final sha = hashes[raw['name']];
    if (sha != null) raw['sha256'] = sha;
  }
  _writeJson(args[2], data);
}

void hasPackage(List<String> args) {
  if (args.length != 2) {
    fail('has-package takes <pub_deps.json> <package name>');
  }
  final data =
      json.decode(File(args[0]).readAsStringSync()) as Map<String, dynamic>;
  for (final raw in (data['packages'] as List?) ?? const []) {
    if ((raw as Map)['name'] == args[1]) exit(0);
  }
  exit(1);
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
    case 'normalize-pub-deps':
      normalizePubDeps();
    case 'merge-pub-deps':
      mergePubDeps(rest);
    case 'has-package':
      hasPackage(rest);
    default:
      fail('rules_flutter pub_tool: unknown subcommand ${args.first}');
  }
}
