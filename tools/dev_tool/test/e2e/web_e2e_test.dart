@Tags(['e2e'])
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

import 'dev_tool_e2e_harness.dart';

/// Overrides the `-c dbg` a `--hot` run asks for (bazel takes the last
/// occurrence of a flag), so the build succeeds and emits no
/// `_dev_config.json` — the artifact the whole DDC dev loop hangs off.
///
/// fastbuild rather than opt on purpose: it is the configuration
/// `bazel test //...` already populates in this workspace, so the negative
/// tests below cost a cache hit instead of a release web compile.
const _notDebug = ['--build-arg=--compilation_mode=fastbuild'];

void main() {
  final workspace = e2eWorkspace('web_example');

  group('Web/Chrome startup failures', () {
    // The regression this whole group exists for: the tool used to warn twice
    // on stderr, fall back to serving the stale bazel bundle, launch Chrome,
    // render the app and report `app.started` — with no DWDS, no VM service,
    // no hot reload, no DevTools and no app console. It looked like a healthy
    // run and could not be debugged or reloaded at all.
    test('a web target built without -c dbg ends the run, naming the cause',
        () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_wasm',
        device: 'chrome',
        extraArgs: _notDebug,
        useBazelBuiltBinary: true,
      );

      try {
        final failure = await dt.waitForStderr('_dev_config.json',
            timeout: const Duration(minutes: 4));
        // LOG_FORMAT=json is on (the harness sets it), so the line a machine
        // consumer reads must be a record with a level — not loose prose.
        final record = json.decode(failure) as Map<String, dynamic>;
        expect(record['level'], 'SEVERE');
        expect(record['error'], contains('-c dbg'));

        // And a --machine client is told why, rather than watching the
        // JSON-RPC stream stop mid-run with no final event.
        final logMessage = await dt.waitForEvent('daemon.logMessage',
            timeout: const Duration(seconds: 30));
        final params = logMessage['params'] as Map<String, dynamic>;
        expect(params['level'], 'error');
        expect(params['message'], contains('_dev_config.json'));

        expect(
          await dt.process.exitCode.timeout(const Duration(seconds: 30)),
          isNot(0),
        );
        // Nothing reached the point of claiming a running app.
        expect(dt.events.map((e) => e['event']), isNot(contains('app.started')));
      } finally {
        await dt.dispose();
      }
    });

    test('--allow-no-vm-service runs the same build anyway, degraded',
        () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_wasm',
        device: 'chrome',
        extraArgs: [..._notDebug, '--allow-no-vm-service'],
        useBazelBuiltBinary: true,
      );

      try {
        await dt.waitForEvent('app.started',
            timeout: const Duration(minutes: 4));
        // The one line that says which flag is keeping this run alive, and
        // what it gave up for it.
        final degraded = json.decode(await dt.waitForStderr(
            'web_dev_server_failed',
            timeout: const Duration(seconds: 30))) as Map<String, dynamic>;
        expect(degraded['level'], 'WARNING');
        expect(degraded['flag'], '--allow-no-vm-service');
        expect(degraded['error'], contains('_dev_config.json'));

        // And the reload surface reports the real reason rather than a
        // generic "no frontend server".
        final reload = await dt.sendCommand(1, 'app.hotReload');
        expect(reload['result']?['error'], contains('hot reload unavailable'));

        await dt.sendCommand(2, 'app.stop');
      } finally {
        await dt.dispose();
      }
    });
  });

  group('Web/Chrome e2e', () {
    test('WASM screenshot via HTTP control channel', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_wasm',
        device: 'chrome',
      );

      try {
        await dt.waitForEvent('app.started');
        final http = await dt.waitForHttpControl();
        expect(http, isNotNull);
        await Future<void>.delayed(const Duration(seconds: 5));

        final outputPath =
            '${Directory.systemTemp.path}/web_wasm_e2e.png';
        await dt.httpScreenshotToFile(dt.appId!, outputPath);

        final file = File(outputPath);
        expect(file.existsSync(), isTrue);
        final bytes = file.readAsBytesSync();
        expect(bytes.length, greaterThan(100));
        expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
        file.deleteSync();

        await dt.sendCommand(1, 'app.stop');
      } finally {
        await dt.dispose();
      }
    });

    test('JS screenshot via HTTP control channel', () async {
      final dt = await startDevTool(
        workspace: workspace,
        target: ':app_js',
        device: 'chrome',
      );

      try {
        await dt.waitForEvent('app.started');
        final http = await dt.waitForHttpControl();
        expect(http, isNotNull);
        await Future<void>.delayed(const Duration(seconds: 5));

        final outputPath =
            '${Directory.systemTemp.path}/web_js_e2e.png';
        await dt.httpScreenshotToFile(dt.appId!, outputPath);

        final file = File(outputPath);
        expect(file.existsSync(), isTrue);
        final bytes = file.readAsBytesSync();
        expect(bytes.length, greaterThan(100));
        expect(bytes.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
        file.deleteSync();

        await dt.sendCommand(1, 'app.stop');
      } finally {
        await dt.dispose();
      }
    });
  });
}
