import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/compiler_config.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/frontend_server.dart';
import 'package:flutter_bazel_dev_tool/machine_protocol.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('parseDevToolsUrl', () {
    // The line `dart devtools` actually prints. The period ends the sentence;
    // capturing it yields a URL Uri.parse rejects, and that value is what gets
    // opened in a browser.
    test('leaves the sentence-ending period out of the URL', () {
      const line = 'Serving DevTools at http://127.0.0.1:9100.';
      expect(parseDevToolsUrl(line), 'http://127.0.0.1:9100');
      expect(() => Uri.parse(parseDevToolsUrl(line)!), returnsNormally);
    });

    test('accepts the announcement without a trailing period', () {
      expect(parseDevToolsUrl('Serving DevTools at http://127.0.0.1:9100'),
          'http://127.0.0.1:9100');
    });

    test('keeps a path intact', () {
      expect(parseDevToolsUrl('Serving DevTools at http://127.0.0.1:9100/abc/.'),
          'http://127.0.0.1:9100/abc/');
    });

    test('declines lines that are not the announcement', () {
      for (final line in const [
        '',
        'Hit ctrl-c to terminate the server.',
        'Serving the Dart Tooling Daemon at ws://127.0.0.1:1234/abc.',
      ]) {
        expect(parseDevToolsUrl(line), isNull, reason: 'should decline "$line"');
      }
    });
  });

  group('devToolsConnectUri', () {
    // Opening the bare server root lands on DevTools' "Connect to a Running
    // App" form — it has no idea which VM service to attach to. The target is
    // carried in the `uri` query parameter.
    final ws = Uri.parse('ws://127.0.0.1:51231/DoJ9hE44ZWc=/ws');

    test('carries the VM service ws URI in the uri query parameter', () {
      final connect = devToolsConnectUri('http://127.0.0.1:9100', ws);

      expect(connect.queryParameters['uri'], ws.toString());
      expect(connect.host, '127.0.0.1');
      expect(connect.port, 9100);
    });

    test('percent-encodes the nested URI so it survives as one parameter', () {
      final connect = devToolsConnectUri('http://127.0.0.1:9100', ws);

      // The `:` and `/` of the inner URI must not be readable as structure of
      // the outer one; round-tripping is what proves it.
      expect(connect.toString(), contains('uri=ws%3A%2F%2F'));
      expect(Uri.parse(connect.toString()).queryParameters['uri'],
          ws.toString());
    });

    test('preserves a served path prefix', () {
      final connect = devToolsConnectUri('http://127.0.0.1:9100/devtools/', ws);

      expect(connect.path, '/devtools/');
      expect(connect.queryParameters['uri'], ws.toString());
    });
  });

  group('DeviceSession', () {
    test('stores device, appInstance, vmClient, and appId', () {
      final device = MacOSDevice();
      final process = FakeProcess();
      final appInstance = AppInstance(process: process);
      final session = DeviceSession(
        device: device,
        appInstance: appInstance,
        vmClient: null,
        appId: 'test_app',
      );

      expect(session.device, device);
      expect(session.appInstance, appInstance);
      expect(session.vmClient, isNull);
      expect(session.appId, 'test_app');
      expect(session.devToolsUrl, isNull);
      expect(session.devToolsProcess, isNull);
    });

    test('a web session is debug-ready without a DDS of its own', () async {
      // What a browser connection leaves behind: DWDS owns the Dart
      // Development Service and hands over URLs, so `dds` stays null here even
      // once the session is fully wired. The DevTools launcher used to read it
      // as `session.dds!`, which on any web session that arrived without a
      // DevTools URL threw `Null check operator used on a null value` — and
      // that string, naming nothing, was printed as the reason DevTools would
      // not start.
      final session = DeviceSession(
        device: WebDevice(),
        appInstance: AppInstance(process: FakeProcess()),
        vmClient: null,
        appId: 'app_web',
      );
      session.markDebugReady();

      await expectLater(session.debugReady, completes);
      expect(session.dds, isNull);
      expect(session.devToolsUrl, isNull);
    });

    test('devToolsUrl is mutable', () {
      final session = DeviceSession(
        device: MacOSDevice(),
        appInstance: AppInstance(process: FakeProcess()),
        vmClient: null,
        appId: 'test',
      );

      session.devToolsUrl = 'http://localhost:9100';
      expect(session.devToolsUrl, 'http://localhost:9100');
    });

    test('devToolsProcess is mutable', () {
      final session = DeviceSession(
        device: MacOSDevice(),
        appInstance: AppInstance(process: FakeProcess()),
        vmClient: null,
        appId: 'test',
      );

      final fakeProcess = FakeProcess();
      session.devToolsProcess = fakeProcess;
      expect(session.devToolsProcess, fakeProcess);
    });

    test('terminated completes when the running app process exits', () async {
      final process = FakeProcess();
      final session = DeviceSession(
        device: MacOSDevice(),
        appInstance: AppInstance(process: process),
        vmClient: null,
        appId: 'test',
      );

      var terminated = false;
      unawaited(session.terminated.then((_) => terminated = true));
      await pumpEventQueue();
      expect(terminated, isFalse);

      process.complete(0);
      await session.terminated.timeout(const Duration(seconds: 5));
    });

    // The exact shape of the bug: a restart that finds changed native
    // libraries kills the running process on purpose and installs a
    // replacement. Reading that kill as "the app exited" ended the run's
    // session loop, which closed the HTTP control channel — so a driver got
    // `{"relaunched":true}` and then connection-refused, with the relaunched
    // app alive and no second banner to find it by.
    test('a relaunch is not the session ending', () async {
      final first = FakeProcess();
      final second = FakeProcess();
      final session = DeviceSession(
        device: MacOSDevice(),
        appInstance: AppInstance(process: first),
        vmClient: null,
        appId: 'test',
      );

      var terminated = false;
      unawaited(session.terminated.then((_) => terminated = true));

      await session.relaunch(() async {
        // What `device.stop()` does to the outgoing process.
        first.complete(0);
        return AppInstance(process: second);
      });
      await pumpEventQueue();

      expect(terminated, isFalse,
          reason: 'the replaced process exiting must not end the session');
      expect(session.appInstance.process, second);
      expect(session.launch, 2, reason: 'second launch of this app');

      // The replacement's exit does end it.
      second.complete(0);
      await session.terminated.timeout(const Duration(seconds: 5));
    });

    test('a relaunch that fails to launch ends the session', () async {
      final first = FakeProcess();
      final session = DeviceSession(
        device: MacOSDevice(),
        appInstance: AppInstance(process: first),
        vmClient: null,
        appId: 'test',
      );

      await expectLater(
        session.relaunch(() async {
          first.complete(0);
          throw StateError('launch failed');
        }),
        throwsStateError,
      );

      // Nothing replaced the process the relaunch killed, so the app really
      // is gone — the suppressed exit must not swallow that.
      await session.terminated.timeout(const Duration(seconds: 5));
      expect(session.launch, 1);
    });
  });

  group('runInteractiveSession', () {
    test('quit key stops all sessions and shuts down', timeout: Timeout(Duration(seconds: 10)), () async {
      final fakeProcess = FakeProcess();
      final fakeFrontendProcess = FakeProcess();
      final stopped = <String>[];

      final device = _TrackingDevice('test_device', onStop: () {
        stopped.add('test_device');
      });

      final session = DeviceSession(
        device: device,
        appInstance: AppInstance(process: fakeProcess),
        vmClient: null,
        appId: 'app_1',
      );

      final protocol = MachineProtocol(enabled: false);

      final frontendServer = FrontendServer(
        dartaotruntimePath: '/fake/dartaotruntime',
        frontendServerPath: '/fake/frontend_server.dart.snapshot',
        config: NativeCompilerConfig(patchedSdkRoot: '/fake/sdk'),
        packageConfig: '/fake/package_config.json',
        processFactory: (exe, args) async => fakeFrontendProcess,
      );
      await frontendServer.start();

      // Use a real temp directory so the watcher can start.
      final tmpDir = await Directory.systemTemp.createTemp('session_test_');

      // Create a keyboard stream that sends 'q' after a short delay.
      final keyboardController = StreamController<List<int>>();
      Future.delayed(const Duration(milliseconds: 100), () {
        keyboardController.add(utf8.encode('q'));
        // Allow shutdown to complete by making the frontend server process exit.
        Future.delayed(const Duration(milliseconds: 50), () {
          fakeFrontendProcess.complete(0);
        });
      });

      final logs = <String>[];

      try {
        await runInteractiveSession(
          sessions: [session],
          frontendServer: frontendServer,
          entrypoint: '/fake/main.dart',
          workspace: tmpDir.path,
          protocol: protocol,
          devToolsEnabled: false,
        dartExecutable: 'dart',
          log: (msg) => logs.add(msg),
          keyboardReader: () => keyboardController.stream,
          setEchoMode: (_) {},
          setLineMode: (_) {},
        );
      } finally {
        await tmpDir.delete(recursive: true);
      }

      expect(stopped, contains('test_device'));
      expect(logs.first, contains('Watching for file changes'));
    });

    test('machine mode suppresses the interactive key banner',
        timeout: Timeout(Duration(seconds: 10)), () async {
      // In --machine mode stdin is the JSON-RPC channel, so "Press r/R/q" hints
      // are both inactive and (since `log` writes to stdout) would corrupt the
      // protocol stream. The banner must not be emitted.
      final protocol = MachineProtocol(enabled: true);
      final logs = <String>[];

      // No sessions + machine mode → the protocol.enabled branch returns
      // immediately (no exit futures to await).
      await runInteractiveSession(
        sessions: [],
        frontendServer: null,
        entrypoint: '/fake/main.dart',
        workspace: Directory.systemTemp.path,
        protocol: protocol,
        devToolsEnabled: false,
        dartExecutable: 'dart',
        hotReloadEnabled: true,
        watchEnabled: false,
        log: (msg) => logs.add(msg),
      );

      expect(
        logs.where((m) => m.contains('Press') || m.contains('Watching')),
        isEmpty,
        reason: 'machine mode owns stdin via JSON-RPC; key hints mislead and '
            'pollute the protocol stdout stream',
      );
    });

    test('machine mode outlives a relaunch of the app process',
        timeout: Timeout(Duration(seconds: 10)), () async {
      // The loop's return is what closes the run's transports — the HTTP
      // control channel included. A restart that relaunches the process
      // (native libraries changed) must therefore not end it: the driver that
      // issued the restart is still holding the channel it issued it over.
      final first = FakeProcess();
      final second = FakeProcess();
      final session = DeviceSession(
        device: MacOSDevice(),
        appInstance: AppInstance(process: first),
        vmClient: null,
        appId: 'app_1',
      );

      var loopReturned = false;
      final loop = runInteractiveSession(
        sessions: [session],
        frontendServer: null,
        entrypoint: '/fake/main.dart',
        workspace: Directory.systemTemp.path,
        protocol: MachineProtocol(enabled: true),
        devToolsEnabled: false,
        dartExecutable: 'dart',
        watchEnabled: false,
      )..then((_) => loopReturned = true);

      await session.relaunch(() async {
        first.complete(0);
        return AppInstance(process: second);
      });
      await pumpEventQueue();

      expect(loopReturned, isFalse,
          reason: 'the relaunched app is running; the session has not ended');

      second.complete(0);
      await loop;
    });
  });
}

/// A device that tracks stop calls.
class _TrackingDevice extends Device {
  final String _name;
  final void Function() onStop;

  _TrackingDevice(this._name, {required this.onStop});

  @override
  String get name => _name;

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      throw UnsupportedError('Not used in this test');

  @override
  Future<void> stop(AppInstance instance) async {
    onStop();
  }
}
