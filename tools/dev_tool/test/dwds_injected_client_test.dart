import 'dart:io';

import 'package:flutter_bazel_dev_tool/dwds_injected_client.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:test/test.dart';

shelf.Request _get(String path) =>
    shelf.Request('GET', Uri.parse('http://localhost:1234/$path'));

void main() {
  group('DwdsInjectedClient.handler', () {
    late Directory tmp;
    late DwdsInjectedClient client;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('dwds_client_');
      final f = File('${tmp.path}/client.js')
        ..writeAsStringSync('// injected client');
      client = DwdsInjectedClient(f.path);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    // The whole point: the browser refuses a script that is not served as
    // JavaScript, which is what the 500/text-plain failure looked like.
    test('serves the client as executable JavaScript', () async {
      final response = await client.handler(_get(dwdsInjectedClientPath));

      expect(response.statusCode, 200);
      expect(response.headers['content-type'], 'application/javascript');
      expect(await response.readAsString(), '// injected client');
    });

    // The script tag is emitted relative to whatever path the app is served
    // under, so the request does not always arrive at the root.
    test('matches the client requested under a nested path', () async {
      final response =
          await client.handler(_get('some/app/prefix/$dwdsInjectedClientPath'));

      expect(response.statusCode, 200);
    });

    // A 404 is how shelf.Cascade is told to fall through; anything else here
    // would swallow every other request the server owns.
    test('declines any other path so the cascade falls through', () async {
      for (final path in const [
        'main.dart.js',
        'index.html',
        'dwds/src/injected/client.js.map',
        '',
      ]) {
        final response = await client.handler(_get(path));
        expect(response.statusCode, 404, reason: 'should decline "$path"');
      }
    });
  });

  group('DwdsInjectedClient.fromRunfiles', () {
    // Outside Bazel there are no runfiles, so this exercises the failure path.
    // It must name the missing file and say how to fix it: the alternative is a
    // silently undebuggable page whose only symptom is a browser console error.
    test('fails with an actionable message when the runfile is absent', () {
      expect(
        DwdsInjectedClient.fromRunfiles,
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            allOf(contains(dwdsInjectedClientRunfile), contains('bazel')))),
      );
    }, skip: Platform.environment.containsKey('RUNFILES_DIR') ||
            Platform.environment.containsKey('RUNFILES_MANIFEST_FILE')
        ? 'runfiles are present; the absent-runfile path cannot be exercised'
        : null);
  });

  test('the runfiles key and the request path name the same asset', () {
    // They are not equal — the runfile is package-rooted
    // (`dev_tool_deps__dwds/lib/...`) while DWDS requests it without the `lib/`
    // segment. What has to hold is that both end at the same file, or we would
    // serve the client at a path nobody requests and DWDS's own failing handler
    // would still be reached.
    const asset = 'src/injected/client.js';
    expect(dwdsInjectedClientRunfile, endsWith(asset));
    expect(dwdsInjectedClientPath, endsWith(asset));
  });
}
