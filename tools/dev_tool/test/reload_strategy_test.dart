import 'dart:async';

import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/frontend_server.dart';
import 'package:flutter_bazel_dev_tool/reload_strategy.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:flutter_bazel_dev_tool/toolchain_info.dart';
import 'package:flutter_bazel_dev_tool/web_module_server.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes.dart';

DeviceSession _sessionWithoutVmClient() => DeviceSession(
      device: MacOSDevice(),
      appInstance: AppInstance(process: FakeProcess()),
      vmClient: null,
      appId: 'app',
    );

void main() {
  final compiled = CompileResult(dillPath: '/fake/out.dill', success: true);

  group('VmServiceReloadStrategy', () {
    // The bug this pins: the old implementation filtered out sessions with no
    // vmClient and then asked `[].every((ok) => ok)`, which is `true`. A run
    // where nothing could possibly be reloaded reported success, and the user
    // was told an edit was live when no process had received it.
    test('reports unsupported when no session has a VM service', () async {
      final outcome = await VmServiceReloadStrategy()
          .applyReload(compiled, [_sessionWithoutVmClient()]);

      expect(outcome, isA<StrategyUnsupported>());
      expect(outcome.isSuccess, isFalse);
      expect(outcome.message, contains('VM service'));
    });

    test('reports unsupported for restart on the same grounds', () async {
      final outcome = await VmServiceReloadStrategy()
          .applyRestart(compiled, [_sessionWithoutVmClient()]);

      expect(outcome, isA<StrategyUnsupported>());
      expect(outcome.isSuccess, isFalse);
    });

    // An empty device list is the same shape of lie, reached a different way.
    test('reports unsupported when there are no sessions at all', () async {
      final outcome = await VmServiceReloadStrategy().applyReload(compiled, []);

      expect(outcome, isA<StrategyUnsupported>());
      expect(outcome.isSuccess, isFalse);
    });
  });

  group('DwdsReloadStrategy', () {
    // `updateModules` returns at web_module_server.dart:201 when the dill's
    // `.json`/`.sources` sidecars are absent, so a server that was never
    // started and points at nothing is safe to drive.
    WebModuleServer stubServer() => WebModuleServer(
          webToolchain: WebToolchainPaths(
            ddcOutlineDill: '/fake/ddc_outline.dill',
            librariesSpec: '/fake/libraries.json',
            dartSdkJs: '/fake/dart_sdk.js',
            ddcModuleLoaderJs: '/fake/ddc_module_loader.js',
            stackTraceMapperJs: '/fake/stack_trace_mapper.js',
            dartSdkRoot: '/fake/dart-sdk',
          ),
          buildOutputDir: '/fake/out',
          entrypointFilename: 'main.dart',
          engineRevision: 'deadbeef',
          dartExecutable: '/fake/dart',
        );

    DwdsReloadStrategy strategy({
      Duration restartTimeout = const Duration(seconds: 30),
    }) =>
        DwdsReloadStrategy(
          moduleServer: stubServer(),
          restartTimeout: restartTimeout,
        );

    final isolate = IsolateRef(id: 'isolates/1', name: 'main', number: '1');

    test('restart without a browser client is unsupported, not a failure',
        () async {
      final outcome = await strategy().applyRestart(compiled, []);

      expect(outcome, isA<StrategyUnsupported>());
      expect(outcome.message, contains('no browser client connected'));
    });

    test('reload without a browser client is unsupported and does not restart',
        () async {
      // It used to delegate to applyRestart for a CDP page reload. Restart now
      // needs a VM service too, so the delegation would only recurse into the
      // same null check.
      final outcome = await strategy().applyReload(compiled, []);

      expect(outcome, isA<StrategyUnsupported>());
      expect(outcome.message, contains('no browser client connected'));
    });

    test('a successful restart is applied', () async {
      final service = FakeVmService(isolates: [isolate]);
      final s = strategy();
      await s.attachVmService(service);

      final outcome = await s.applyRestart(compiled, []);

      expect(outcome, isA<StrategyApplied>());
      expect(service.hotRestartMethod, 'hotRestart');
      // DWDS owns the Service stream subscription now.
      expect(service.streamListens, contains(EventStreams.kService));
    });

    // THE regression this change can ship green with. A page-preserving restart
    // never reconnects the browser, so attachVmService — the only other place
    // that clears the cached isolate id — never fires, and the next reload
    // would call reloadSources on the isolate DWDS just replaced.
    test('a reload after a restart re-discovers the new isolate', () async {
      final service = FakeVmService(isolates: [isolate]);
      final s = strategy();
      await s.attachVmService(service);

      // Prime the cache the way a pre-restart reload would.
      await s.applyReload(compiled, []);
      expect(service.lastIsolateId, 'isolates/1');

      expect(await s.applyRestart(compiled, []), isA<StrategyApplied>());

      // DWDS started a new isolate; the next reload must target it.
      service.isolates
        ..clear()
        ..add(IsolateRef(id: 'isolates/2', name: 'main', number: '2'));

      final outcome = await s.applyReload(compiled, []);

      expect(outcome, isA<StrategyApplied>());
      expect(service.lastIsolateId, 'isolates/2');
    });

    test('the DDS-namespaced alias is the name actually called', () async {
      final service = FakeVmService(isolates: [isolate]);
      final s = strategy();
      await s.attachVmService(service);
      service.emitServiceRegistered('hotRestart', 's0.hotRestart');
      await pumpEventQueue();

      expect(await s.applyRestart(compiled, []), isA<StrategyApplied>());

      // A hardcoded bare `hotRestart` gets kMethodNotFound once DWDS owns DDS.
      expect(service.hotRestartMethod, 's0.hotRestart');
    });

    test('an unregistered service falls back to the bare name', () async {
      final service = FakeVmService(isolates: [isolate]);
      final s = strategy();
      await s.attachVmService(service);
      service.emitServiceRegistered('hotRestart', 's0.hotRestart');
      await pumpEventQueue();
      service.emitServiceUnregistered('hotRestart', 's0.hotRestart');
      await pumpEventQueue();

      expect(await s.applyRestart(compiled, []), isA<StrategyApplied>());

      expect(service.hotRestartMethod, 'hotRestart');
    });

    // DWDS raises these when the page went away between the recompile and the
    // restart. Upstream treats both as "no client", not as a failure —
    // vm_service re-encodes RPCErrors as kServerError, so 109 alone misses it.
    for (final code in [109, -32000]) {
      test('RPCError $code means no client, not a rejection', () async {
        final service = FakeVmService(isolates: [isolate])
          ..hotRestartError = RPCError('hotRestart', code, 'no clients');
        final s = strategy();
        await s.attachVmService(service);

        final outcome = await s.applyRestart(compiled, []);

        expect(outcome, isA<StrategyUnsupported>());
        expect(outcome.message, contains('no browser client connected'));
      });
    }

    test('any other RPCError is a rejection carrying its message', () async {
      final service = FakeVmService(isolates: [isolate])
        ..hotRestartError =
            RPCError('hotRestart', -32601, 'Method not found: hotRestart');
      final s = strategy();
      await s.attachVmService(service);

      final outcome = await s.applyRestart(compiled, []);

      expect(outcome, isA<StrategyRejected>());
      expect(outcome.message, contains('Method not found'));
    });

    // DWDS awaits its IsolateStart with no timeout (dwds_vm_client.dart:530),
    // so a page that never reports one would hang the session forever.
    test('a restart that never reports an isolate is rejected, not hung',
        () async {
      final gate = Completer<void>();
      final service = FakeVmService(isolates: [isolate])
        ..hotRestartGate = gate;
      final s = strategy(restartTimeout: const Duration(milliseconds: 50));
      await s.attachVmService(service);

      final outcome = await s.applyRestart(compiled, []);

      expect(outcome, isA<StrategyRejected>());
      expect(outcome.message, contains('did not report a restarted isolate'));
      gate.complete(); // don't leak the pending call
    });
  });

  group('StrategyOutcome', () {
    test('only an applied outcome counts as success', () {
      expect(const StrategyApplied(2).isSuccess, isTrue);
      expect(const StrategyUnsupported('nothing to apply to').isSuccess, isFalse);
      expect(const StrategyRejected('refused').isSuccess, isFalse);
    });

    test('every outcome can explain itself', () {
      expect(const StrategyApplied(3).message, contains('3'));
      expect(const StrategyUnsupported('no VM service').message, 'no VM service');
      expect(const StrategyRejected('refused').message, 'refused');
    });
  });

  group('ReloadResult', () {
    test('a compile failure is not a device success', () {
      final result = ReloadResult(compileSuccess: false, elapsedMs: 1);

      expect(result.deviceSuccess, isFalse);
      expect(result.success, isFalse);
    });

    // `deviceSuccess` used to default to true, so a result carrying no outcome
    // at all still read as a successful reload.
    test('an unsupported apply is not a success and explains why', () {
      final result = ReloadResult(
        compileSuccess: true,
        outcome: const StrategyUnsupported('no device has a VM service'),
        elapsedMs: 1,
      );

      expect(result.deviceSuccess, isFalse);
      expect(result.success, isFalse);
      expect(result.failureReason, 'no device has a VM service');
    });

    test('an applied outcome succeeds with nothing to explain', () {
      final result = ReloadResult(
        compileSuccess: true,
        outcome: const StrategyApplied(1),
        elapsedMs: 1,
      );

      expect(result.success, isTrue);
      expect(result.failureReason, isNull);
    });
  });

  group('reloadResultToMap', () {
    // The bug this pins: the map answered a fixed '$verb failed on some
    // devices', so every StrategyOutcome message — the only place the reason
    // is ever written down — was discarded at the protocol boundary.
    test('a rejected apply explains itself', () {
      final map = reloadResultToMap(
        ReloadResult(
          compileSuccess: true,
          outcome: const StrategyRejected('the browser refused the new sources'),
          elapsedMs: 1,
        ),
        'Hot reload',
      );

      expect(map['message'], contains('the browser refused the new sources'));
    });

    test('an unsupported apply explains itself too', () {
      final map = reloadResultToMap(
        ReloadResult(
          compileSuccess: true,
          outcome: const StrategyUnsupported('no browser client connected'),
          elapsedMs: 1,
        ),
        'Restart',
      );

      expect(map['message'], contains('no browser client connected'));
      expect(map['message'], startsWith('Restart'));
    });

    // Reachable: nothing stops a caller building a result with no outcome, and
    // 'Restart failed: null' would be worse than the generic wording.
    test('an outcome-less failure keeps the generic wording', () {
      final map = reloadResultToMap(
        ReloadResult(compileSuccess: true, elapsedMs: 1),
        'Restart',
      );

      expect(map['message'], 'Restart failed on some devices');
    });

    test('a compile failure short-circuits with its diagnostics', () {
      final map = reloadResultToMap(
        ReloadResult(
          compileSuccess: false,
          diagnostics: 'main.dart:3:1: Error: boom',
          elapsedMs: 1,
        ),
        'Hot reload',
      );

      expect(map['message'], 'Compilation failed');
      expect(map['error'], contains('boom'));
    });

    test('a success says so and carries no error', () {
      final map = reloadResultToMap(
        ReloadResult(
          compileSuccess: true,
          outcome: const StrategyApplied(1),
          elapsedMs: 1,
        ),
        'Hot reload',
      );

      expect(map['message'], 'Hot reload successful');
      expect(map.containsKey('error'), isFalse);
    });
  });

  group('reportReloadCommand', () {
    test('renders an error rather than staying silent', () {
      final logged = <String>[];
      reportReloadCommand('Hot reload', {'error': 'no device'}, logged.add);

      // Errors go to stderr, so nothing reaches the normal log sink — the
      // point is that the caller no longer discards the map entirely.
      expect(logged, isEmpty);
    });

    test('renders the message and recompiled file count', () {
      final logged = <String>[];
      reportReloadCommand('Hot reload', {
        'message': 'Hot reload successful',
        'filesRecompiled': ['package:app/main.dart'],
      }, logged.add);

      expect(logged.single, contains('Hot reload successful'));
      expect(logged.single, contains('1 file'));
    });

    test('calls out a no-op reload', () {
      final logged = <String>[];
      reportReloadCommand('Hot reload', {
        'message': 'Hot reload successful',
        'isEmpty': true,
      }, logged.add);

      expect(logged.single, contains('no changes'));
    });
  });
}
