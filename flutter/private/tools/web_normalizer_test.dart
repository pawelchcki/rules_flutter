import 'dart:convert';
import 'dart:io';

import 'web_normalizer.dart';

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}

void _write(File file, String content) {
  file.parent.createSync(recursive: true);
  file.writeAsStringSync(content);
}

String _worker(Map<String, String> resources) =>
    "'use strict';\nconst RESOURCES = ${jsonEncode(resources)};\nconst CORE = [];\n";

Map<String, dynamic> _workerResources(File worker) {
  final Match? match = RegExp(
    r'const\s+RESOURCES\s*=\s*(\{[\s\S]*?\});',
  ).firstMatch(worker.readAsStringSync());
  _expect(match != null, 'service worker has no RESOURCES map');
  return jsonDecode(match!.group(1)!) as Map<String, dynamic>;
}

String _fingerprintIn(String content) {
  final Match? match = RegExp(
    r'serviceWorkerVersion\s*[:=]\s*["\x27]([0-9a-f]{64})["\x27]',
  ).firstMatch(content);
  _expect(match != null, 'normalized serviceWorkerVersion fingerprint missing');
  return match!.group(1)!;
}

Directory _caseDirectory(Directory root, String name) {
  final Directory directory = Directory('${root.path}${Platform.pathSeparator}$name');
  directory.createSync(recursive: true);
  return directory;
}

void _testDefaultTemplate(Directory root) {
  final Directory fixture = _caseDirectory(root, 'default');
  final Directory output = Directory('${fixture.path}/output')..createSync();
  final Directory templates = Directory('${fixture.path}/web')..createSync();
  _write(File('${templates.path}/index.html'), '<script>{{flutter_bootstrap_js}}</script>');
  _write(
    File('${output.path}/flutter_bootstrap.js'),
    '_flutter.loader.load({serviceWorker: {serviceWorkerVersion: "101"}});',
  );
  _write(
    File('${output.path}/index.html'),
    '<script>serviceWorkerVersion: "101"</script>',
  );
  _write(File('${output.path}/main.dart.js'), 'main');
  final File worker = File('${output.path}/flutter_service_worker.js');
  _write(worker, _worker(<String, String>{
    'flutter_bootstrap.js': 'old',
    'index.html': 'old',
    '/': 'old',
  }));

  normalizeWebBuild(output.path, templates.path);

  final String bootstrapFingerprint =
      _fingerprintIn(File('${output.path}/flutter_bootstrap.js').readAsStringSync());
  final String indexFingerprint =
      _fingerprintIn(File('${output.path}/index.html').readAsStringSync());
  _expect(bootstrapFingerprint == indexFingerprint, 'default template fingerprints differ');
  final Map<String, dynamic> resources = _workerResources(worker);
  _expect(
    resources['flutter_bootstrap.js'] ==
        md5Hex(File('${output.path}/flutter_bootstrap.js').readAsBytesSync()),
    'bootstrap MD5 was not repaired',
  );
  final String indexMd5 = md5Hex(File('${output.path}/index.html').readAsBytesSync());
  _expect(resources['index.html'] == indexMd5, 'root index MD5 was not repaired');
  _expect(resources['/'] == indexMd5, 'root / MD5 was not repaired');
}

void _testTokenTemplate(Directory root, {required bool emptyWorker}) {
  final String name = emptyWorker ? 'token-empty-worker' : 'token-absent-worker';
  final Directory fixture = _caseDirectory(root, name);
  final Directory output = Directory('${fixture.path}/output')..createSync();
  final Directory templates = Directory('${fixture.path}/web')..createSync();
  _write(
    File('${templates.path}/index.html'),
    'serviceWorkerVersion: {{flutter_service_worker_version}}',
  );
  _write(File('${output.path}/index.html'), 'serviceWorkerVersion: "202"');
  if (emptyWorker) {
    _write(File('${output.path}/flutter_service_worker.js'), '');
  }

  normalizeWebBuild(output.path, templates.path);
  _fingerprintIn(File('${output.path}/index.html').readAsStringSync());
}

void _testLegacyNestedTemplate(Directory root) {
  final Directory fixture = _caseDirectory(root, 'legacy-nested');
  final Directory output = Directory('${fixture.path}/output')..createSync();
  final Directory templates = Directory('${fixture.path}/web')..createSync();
  _write(
    File('${templates.path}/nested/index.html'),
    "var serviceWorkerVersion = null;\n"
    "navigator.serviceWorker.register('flutter_service_worker.js');",
  );
  _write(
    File('${output.path}/nested/index.html'),
    "const serviceWorkerVersion = \"303\";\n"
    "navigator.serviceWorker.register('flutter_service_worker.js?v=303');",
  );
  final File worker = File('${output.path}/flutter_service_worker.js');
  _write(worker, _worker(<String, String>{'nested/index.html': 'old'}));

  normalizeWebBuild(output.path, templates.path);

  final String content = File('${output.path}/nested/index.html').readAsStringSync();
  final String fingerprint = _fingerprintIn(content);
  _expect(content.contains('?v=$fingerprint'), 'legacy query version was not normalized');
  _expect(
    _workerResources(worker)['nested/index.html'] ==
        md5Hex(File('${output.path}/nested/index.html').readAsBytesSync()),
    'nested index MD5 was not repaired',
  );
}

void _testHardcodedVersion(Directory root) {
  final Directory fixture = _caseDirectory(root, 'hardcoded');
  final Directory output = Directory('${fixture.path}/output')..createSync();
  final Directory templates = Directory('${fixture.path}/web')..createSync();
  const String hardcoded = '_flutter.loader.load({serviceWorker: {serviceWorkerVersion: "404"}});';
  _write(File('${templates.path}/flutter_bootstrap.js'), hardcoded);
  _write(File('${templates.path}/index.html'), '<script>{{flutter_bootstrap_js}}</script>');
  _write(File('${output.path}/flutter_bootstrap.js'), hardcoded);
  _write(File('${output.path}/index.html'), '<script>$hardcoded</script>');

  normalizeWebBuild(output.path, templates.path);
  _expect(
    File('${output.path}/flutter_bootstrap.js').readAsStringSync() == hardcoded,
    'deliberately hardcoded numeric version changed',
  );
  _expect(
    File('${output.path}/index.html').readAsStringSync() == '<script>$hardcoded</script>',
    'inlined deliberately hardcoded numeric version changed',
  );
}

void _testUnsafeManifestFails(Directory root) {
  final Directory fixture = _caseDirectory(root, 'unsafe-manifest');
  final Directory output = Directory('${fixture.path}/output')..createSync();
  final Directory templates = Directory('${fixture.path}/web')..createSync();
  _write(
    File('${templates.path}/index.html'),
    'serviceWorkerVersion: {{flutter_service_worker_version}}',
  );
  _write(File('${output.path}/index.html'), 'serviceWorkerVersion: "505"');
  _write(File('${output.path}/flutter_service_worker.js'), 'self.addEventListener("fetch", () => {});');

  bool failed = false;
  try {
    normalizeWebBuild(output.path, templates.path);
  } on StateError {
    failed = true;
  }
  _expect(failed, 'normalization succeeded without a repairable RESOURCES map');
}

void _testHashContracts(Directory root) {
  _expect(
    sha256Hex(utf8.encode('abc')) ==
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
    'SHA-256 implementation failed the abc vector',
  );
  _expect(
    md5Hex(utf8.encode('abc')) == '900150983cd24fb0d6963f7d28e17f72',
    'MD5 implementation failed the abc vector',
  );

  final Directory output = _caseDirectory(root, 'hidden-files');
  _write(File('${output.path}/visible.txt'), 'visible');
  _write(File('${output.path}/.hidden'), 'first');
  _write(File('${output.path}/.hidden-dir/value'), 'first');
  final String before = fingerprintWebFiles(output);
  _write(File('${output.path}/.hidden'), 'second');
  _write(File('${output.path}/.hidden-dir/value'), 'second');
  _expect(before == fingerprintWebFiles(output), 'hidden files affected the fingerprint');
}

void _verifyRealOutput(String outputPath, String logPath) {
  final Directory output = Directory(outputPath);
  final File bootstrap = File('${output.path}/flutter_bootstrap.js');
  final File index = File('${output.path}/index.html');
  final File worker = File('${output.path}/flutter_service_worker.js');
  final String bootstrapFingerprint = _fingerprintIn(bootstrap.readAsStringSync());
  final String indexFingerprint = _fingerprintIn(index.readAsStringSync());
  _expect(bootstrapFingerprint == indexFingerprint, 'real web fingerprints differ');

  final Map<String, dynamic> resources = _workerResources(worker);
  _expect(
    resources['flutter_bootstrap.js'] == md5Hex(bootstrap.readAsBytesSync()),
    'real bootstrap MD5 does not match',
  );
  final String indexMd5 = md5Hex(index.readAsBytesSync());
  _expect(resources['index.html'] == indexMd5, 'real index MD5 does not match');
  _expect(resources['/'] == indexMd5, 'real root / MD5 does not match');

  const String expectedLog = "Target: web\n"
      "Mode: release\n"
      "Command: flutter 'build' 'web' '--no-pub' '--release' "
      "'--dart-define=SMOKE_DEFINE=smoke-define-e2e-value' '--source-maps'\n"
      "Status: Success\n";
  _expect(File(logPath).readAsStringSync() == expectedLog, 'build log contract changed');
}

void main(List<String> arguments) {
  if (arguments.length == 3 && arguments.first == '--verify-output') {
    _verifyRealOutput(arguments[1], arguments[2]);
    stdout.writeln('Verified normalized web output and deterministic build log');
    return;
  }
  if (arguments.isNotEmpty) {
    throw ArgumentError('usage: web_normalizer_test.dart [--verify-output OUTPUT LOG]');
  }

  final Directory root = Directory.systemTemp.createTempSync('web_normalizer_test.');
  try {
    _testHashContracts(root);
    _testDefaultTemplate(root);
    _testTokenTemplate(root, emptyWorker: false);
    _testTokenTemplate(root, emptyWorker: true);
    _testLegacyNestedTemplate(root);
    _testHardcodedVersion(root);
    _testUnsafeManifestFails(root);
  } finally {
    root.deleteSync(recursive: true);
  }
  stdout.writeln('Web normalizer fixture cases passed');
}
