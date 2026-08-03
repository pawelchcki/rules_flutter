import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

// Called in-process rather than spawned. Spawning meant `dart` from PATH and a
// hand-rolled search for the script — neither of which survives a Bazel test
// sandbox, where there is no PATH Dart and the source sits at its runfiles
// path. `main` only calls `exit` on a usage error, which no test here triggers,
// so it is safe to await directly; every other failure surfaces as a thrown
// exception the test can assert on.
import '../bundle_app.dart' as bundle_app;

void main() {
  group('bundle_app', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('bundle_app_test_');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    String configPath(Map<String, dynamic> config) {
      final f = File('${tempDir.path}/config.json');
      f.writeAsStringSync(json.encode(config));
      return f.path;
    }

    Future<void> run(Map<String, dynamic> config) =>
        bundle_app.main(['--config', configPath(config)]);

    test('copies files to correct destinations', () async {
      final srcFile = File('${tempDir.path}/source.txt')
        ..writeAsStringSync('hello');
      final outputDir = '${tempDir.path}/output';

      await run({
        'output_dir': outputDir,
        'copies': [
          {'src': srcFile.path, 'dst': 'data/source.txt'},
        ],
      });

      expect(File('$outputDir/data/source.txt').readAsStringSync(), 'hello');
    });

    test('creates nested output directories', () async {
      final srcFile = File('${tempDir.path}/src.txt')
        ..writeAsStringSync('nested');
      final outputDir = '${tempDir.path}/output';

      await run({
        'output_dir': outputDir,
        'copies': [
          {'src': srcFile.path, 'dst': 'a/b/c/deep.txt'},
        ],
      });

      expect(File('$outputDir/a/b/c/deep.txt').readAsStringSync(), 'nested');
    });

    test('copies directories recursively', () async {
      final srcDir = Directory('${tempDir.path}/srcdir')..createSync();
      File('${srcDir.path}/file1.txt').writeAsStringSync('one');
      final subDir = Directory('${srcDir.path}/sub')..createSync();
      File('${subDir.path}/file2.txt').writeAsStringSync('two');
      final outputDir = '${tempDir.path}/output';

      await run({
        'output_dir': outputDir,
        'copy_dirs': [
          {'src': srcDir.path, 'dst': 'copied'},
        ],
      });

      expect(File('$outputDir/copied/file1.txt').readAsStringSync(), 'one');
      expect(File('$outputDir/copied/sub/file2.txt').readAsStringSync(), 'two');
    });

    test('creates symlinks', () async {
      final outputDir = '${tempDir.path}/output';

      await run({
        'output_dir': outputDir,
        'write_files': [
          {'path': 'target.txt', 'content': 'target content'},
        ],
        'symlinks': [
          {'target': 'target.txt', 'link': 'link.txt'},
        ],
      });

      expect(Link('$outputDir/link.txt').existsSync(), isTrue);
    }, testOn: '!windows');

    test('writes files with content', () async {
      final outputDir = '${tempDir.path}/output';

      await run({
        'output_dir': outputDir,
        'write_files': [
          {'path': 'info.txt', 'content': 'generated content'},
        ],
      });

      expect(
          File('$outputDir/info.txt').readAsStringSync(), 'generated content');
    });

    test('fails on a missing config file', () async {
      await expectLater(
        bundle_app.main(['--config', '${tempDir.path}/nonexistent.json']),
        throwsA(isA<FileSystemException>()),
      );
    });
  });
}
