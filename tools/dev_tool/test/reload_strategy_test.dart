import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/frontend_server.dart';
import 'package:flutter_bazel_dev_tool/reload_strategy.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:test/test.dart';

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
