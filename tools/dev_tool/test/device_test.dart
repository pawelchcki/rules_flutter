import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/mdns_vm_service_discovery.dart';
import 'package:flutter_bazel_dev_tool/runfiles_helper.dart';
import 'package:test/test.dart';

import 'fakes.dart';

/// The announcement every desktop launch waits for.
const _vmServiceLine =
    'The Dart VM service is listening on http://127.0.0.1:12345/test=/';

void main() {
  group('vmServiceUriPattern', () {
    test('matches "Dart VM service is listening on http://..."', () {
      final line =
          'The Dart VM service is listening on http://127.0.0.1:9999/xyz/';
      final match = vmServiceUriPattern.firstMatch(line);
      expect(match, isNotNull);
      expect(match!.group(1), 'http://127.0.0.1:9999/xyz/');
    });

    test('does not match unrelated stdout', () {
      final line = 'Starting Flutter application...';
      final match = vmServiceUriPattern.firstMatch(line);
      expect(match, isNull);
    });

    test('does not match partial prefix', () {
      final line = 'Something listening on http://localhost:1234/';
      final match = vmServiceUriPattern.firstMatch(line);
      expect(match, isNull);
    });
  });

  group('detectDevice', () {
    test('returns a device for current platform', () {
      if (Platform.isMacOS || Platform.isLinux) {
        final device = detectDevice();
        expect(device, isNotNull);
      }
    });

    test('MacOSDevice has correct name', () {
      final device = MacOSDevice();
      expect(device.name, 'macOS');
    });

    test('LinuxDevice has correct name', () {
      final device = LinuxDevice();
      expect(device.name, 'Linux');
    });

    test('AndroidDevice name includes deviceId when provided', () {
      final device = AndroidDevice(deviceId: 'emulator-5554');
      expect(device.name, 'Android (emulator-5554)');
    });

    test('AndroidDevice name is "Android" when no deviceId', () {
      final device = AndroidDevice();
      expect(device.name, 'Android');
    });
  });

  group('resolveDevices', () {
    test('returns auto-detected device when no IDs given', () {
      final devices = resolveDevices([]);
      expect(devices, hasLength(1));
    });

    test('resolves macos to MacOSDevice', () {
      final devices = resolveDevices(['macos']);
      expect(devices.single, isA<MacOSDevice>());
    });

    test('resolves linux to LinuxDevice', () {
      final devices = resolveDevices(['linux']);
      expect(devices.single, isA<LinuxDevice>());
    });

    test('resolves windows to WindowsDevice', () {
      final devices = resolveDevices(['windows']);
      expect(devices.single, isA<WindowsDevice>());
    });

    test('resolves chrome to WebDevice', () {
      final devices = resolveDevices(['chrome']);
      expect(devices.single, isA<WebDevice>());
    });

    test('resolves ios-simulator to IOSSimulatorDevice', () {
      final devices = resolveDevices(['ios-simulator']);
      expect(devices.single, isA<IOSSimulatorDevice>());
    });

    test('resolves ios-simulator:UDID to IOSSimulatorDevice with udid', () {
      final devices = resolveDevices(['ios-simulator:ABC-123']);
      final device = devices.single as IOSSimulatorDevice;
      expect(device.udid, 'ABC-123');
    });

    test('resolves unknown ID as Android serial', () {
      final devices = resolveDevices(['emulator-5554']);
      expect(devices.single, isA<AndroidDevice>());
    });

    test('resolves multiple device IDs', () {
      final devices = resolveDevices(['macos', 'chrome']);
      expect(devices, hasLength(2));
      expect(devices[0], isA<MacOSDevice>());
      expect(devices[1], isA<WebDevice>());
    });
  });

  group('buildArgs', () {
    test('MacOSDevice returns empty buildArgs', () {
      expect(MacOSDevice().buildArgs, isEmpty);
    });

    test('LinuxDevice returns platform flag when not on Linux', () {
      final device = LinuxDevice();
      if (!Platform.isLinux) {
        expect(device.buildArgs, [
          '--platforms=@rules_flutter//flutter/platforms:linux_x64',
        ]);
      } else {
        expect(device.buildArgs, isEmpty);
      }
    });

    test('WindowsDevice returns platform flag when not on Windows', () {
      final device = WindowsDevice();
      if (!Platform.isWindows) {
        expect(device.buildArgs, [
          '--platforms=@rules_flutter//flutter/platforms:windows_x64',
        ]);
      } else {
        expect(device.buildArgs, isEmpty);
      }
    });

    test('IOSSimulatorDevice returns ios_multi_cpus=sim_arm64', () {
      final device = IOSSimulatorDevice(udid: 'TEST');
      expect(device.buildArgs, ['--ios_multi_cpus=sim_arm64']);
    });

    test('AndroidDevice defaults to arm64 platform', () {
      final device = AndroidDevice();
      expect(device.buildArgs, [
        '--platforms=@rules_flutter//flutter/platforms:android_arm64',
      ]);
    });

    test('AndroidDevice respects custom abi', () {
      final device = AndroidDevice(abi: 'x64');
      expect(device.buildArgs, [
        '--platforms=@rules_flutter//flutter/platforms:android_x64',
      ]);
    });

    test('WebDevice returns empty buildArgs', () {
      expect(WebDevice().buildArgs, isEmpty);
    });
  });

  group('IOSSimulatorDevice', () {
    test('has correct name with udid', () {
      final device = IOSSimulatorDevice(udid: 'ABC-123');
      expect(device.name, 'iOS Simulator (ABC-123)');
    });

    test('calls simctl install and launch', () async {
      final calls = <(String, List<String>)>[];
      final fakeLog = FakeProcess();

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeLog;
        },
      );

      Future.delayed(Duration(milliseconds: 10), () {
        fakeLog.complete(0);
      });

      await device.launch('/path/to/MyApp.app');

      // Should have: boot, install, log stream spawn, launch.
      final xcrunCalls = calls.where((c) => c.$1 == 'xcrun').toList();
      expect(xcrunCalls.length, greaterThanOrEqualTo(4));

      final bootCall = xcrunCalls.firstWhere(
          (c) => c.$2.contains('boot'));
      expect(bootCall.$2, contains('TEST-UDID'));

      final installCall = xcrunCalls.firstWhere(
          (c) => c.$2.contains('install'));
      expect(installCall.$2, contains('TEST-UDID'));
      expect(installCall.$2, contains('/path/to/MyApp.app'));

      final launchCall = xcrunCalls.firstWhere(
          (c) => c.$2.contains('launch'));
      expect(launchCall.$2, contains('com.example.test'));
    });

    test('throws on simctl install failure', () async {
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          if ((args as List).contains('install')) {
            return ProcessResult(0, 1, '', 'INSTALL_FAILED');
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      expect(() => device.launch('/path/to/MyApp.app'), throwsStateError);
    });

    test('stop calls simctl terminate when bundleId is set', () async {
      final calls = <(String, List<String>)>[];
      final fakeLog = FakeProcess();

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLog,
      );

      final instance = AppInstance(process: fakeLog);
      await device.stop(instance);

      final terminateCall = calls.firstWhere(
          (c) => c.$2.contains('terminate'));
      expect(terminateCall.$2, contains('com.example.test'));
    });

    test('extracts .app from .ipa before install', () async {
      final calls = <(String, List<String>)>[];
      final fakeLog = FakeProcess();

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          if (exe == 'unzip') {
            // Simulate unzip by creating Payload/app.app directory.
            final dest = args.last;
            Directory('$dest/Payload/app.app').createSync(recursive: true);
            File('$dest/Payload/app.app/Info.plist').writeAsStringSync('');
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeLog;
        },
      );

      Future.delayed(Duration(milliseconds: 10), () {
        fakeLog.complete(0);
      });

      await device.launch('/path/to/app.ipa');

      // Should have called unzip.
      final unzipCall = calls.firstWhere((c) => c.$1 == 'unzip');
      expect(unzipCall.$2, contains('/path/to/app.ipa'));

      // simctl install should receive the extracted .app, not the .ipa.
      final installCall = calls.firstWhere(
          (c) => c.$1 == 'xcrun' && c.$2.contains('install'));
      expect(installCall.$2.last, endsWith('.app'));
      expect(installCall.$2.last, isNot(endsWith('.ipa')));
    });

    test('discovers VM service URI from log stream', () async {
      final fakeLog = FakeProcess();

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async => fakeLog,
      );

      Future.delayed(Duration(milliseconds: 20), () {
        fakeLog.emitStdout(
            'The Dart VM service is listening on http://127.0.0.1:54321/abc=/');
      });

      final instance = await device.launch('/path/to/MyApp.app');
      expect(instance.vmServiceUri, isNotNull);
      expect(instance.vmServiceUri.toString(),
          'http://127.0.0.1:54321/abc=/');
    });
  });

  group('WebDevice', () {
    test('has correct name', () {
      final device = WebDevice();
      expect(device.name, 'Chrome');
    });
  });

  group('findChrome', () {
    test('returns a string or null', () {
      // Just verifies it doesn't throw.
      final result = findChrome();
      expect(result, anyOf(isNull, isA<String>()));
    });
  });

  group('AndroidDevice.launch', () {
    test('calls adb install with -r and device flag', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        deviceId: 'emulator-5554',
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeLogcat;
        },
      );

      Future.delayed(Duration(milliseconds: 10), () {
        fakeLogcat.complete(0);
      });

      await device.launch('/path/to/app.apk');

      final runCalls = calls
          .where((c) => c.$1 == 'adb')
          .toList();
      expect(runCalls.length, greaterThanOrEqualTo(3));

      final installCall = runCalls.firstWhere(
          (c) => c.$2.contains('install'));
      expect(installCall.$2, contains('-s'));
      expect(installCall.$2, contains('emulator-5554'));
      expect(installCall.$2, contains('-r'));
      expect(installCall.$2, contains('/path/to/app.apk'));
    });

    test('calls adb shell am start with package/activity', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        packageName: 'com.example.app',
        activityName: '.FlutterActivity',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );

      Future.delayed(Duration(milliseconds: 10), () {
        fakeLogcat.complete(0);
      });

      await device.launch('/path/to/app.apk');

      final startCall = calls.firstWhere(
          (c) => c.$2.contains('am'));
      expect(startCall.$2, contains('shell'));
      expect(startCall.$2, contains('am'));
      expect(startCall.$2, contains('start'));
      expect(startCall.$2, contains('-n'));
      expect(startCall.$2, contains('com.example.app/.FlutterActivity'));
    });

    test('defaults activityName to .MainActivity', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );

      Future.delayed(Duration(milliseconds: 10), () {
        fakeLogcat.complete(0);
      });

      await device.launch('/path/to/app.apk');

      final startCall = calls.firstWhere(
          (c) => c.$2.contains('am'));
      expect(startCall.$2, contains('com.example.app/.MainActivity'));
    });

    test('throws on adb install failure', () async {
      final device = AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          return ProcessResult(0, 1, '', 'INSTALL_FAILED');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      expect(
        () => device.launch('/path/to/app.apk'),
        throwsStateError,
      );
    });

    test('discovers VM service URI from logcat', () async {
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async => fakeLogcat,
      );

      Future.delayed(Duration(milliseconds: 20), () {
        fakeLogcat.emitStdout(
            '01-02 03:04:05.678 I/flutter ( 1234): The Dart VM service is '
            'listening on http://127.0.0.1:12345/abc=/');
      });

      final instance = await device.launch('/path/to/app.apk');
      expect(instance.vmServiceUri, isNotNull);
      expect(instance.vmServiceUri.toString(),
          'http://127.0.0.1:12345/abc=/');
    });

    test('stop calls force-stop when packageName is set', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();

      final device = AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );

      final instance = AppInstance(process: fakeLogcat);
      await device.stop(instance);

      final stopCall = calls.firstWhere(
          (c) => c.$2.contains('force-stop'));
      expect(stopCall.$2, contains('com.example.app'));
    });

  });

  group('AndroidDevice INTERNET preflight', () {
    // Realistic `dumpsys package <pkg>` excerpt. The requested-permissions
    // section is omitted entirely when the APK requests no permissions.
    String dumpsysOutput({
      required String package,
      required List<String> requestedPermissions,
    }) {
      final buf = StringBuffer()
        ..writeln('Packages:')
        ..writeln('  Package [$package] (5b7a1c2):')
        ..writeln('    userId=10190')
        ..writeln('    codePath=/data/app/~~q3zA==/$package-r7Yw==');
      if (requestedPermissions.isNotEmpty) {
        buf.writeln('    requested permissions:');
        for (final perm in requestedPermissions) {
          buf.writeln('      $perm');
        }
      }
      buf
        ..writeln('    install permissions:')
        ..writeln('      android.permission.VIBRATE: granted=true')
        ..writeln('    User 0: ceDataInode=73543 installed=true');
      return buf.toString();
    }

    AndroidDevice makeDevice({
      required List<(String, List<String>)> calls,
      required Future<ProcessResult> Function(List<String> args) onDumpsys,
      required FakeProcess logcat,
    }) {
      return AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          if (args.contains('dumpsys')) return onDumpsys(args);
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return logcat;
        },
      )..expectsVmService = true;
    }

    test('proceeds when the installed package requests INTERNET', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();
      final device = makeDevice(
        calls: calls,
        logcat: fakeLogcat,
        onDumpsys: (args) async => ProcessResult(
          0,
          0,
          dumpsysOutput(package: 'com.example.app', requestedPermissions: [
            'android.permission.INTERNET',
          ]),
          '',
        ),
      );

      Future.delayed(Duration(milliseconds: 20), () {
        fakeLogcat.emitStdout(
            '01-02 03:04:05.678 I/flutter ( 1234): The Dart VM service is '
            'listening on http://127.0.0.1:12345/abc=/');
      });

      final instance = await device.launch('/path/to/app.apk');
      expect(instance.vmServiceUri, isNotNull);

      final dumpsysCall =
          calls.firstWhere((c) => c.$2.contains('dumpsys'));
      expect(dumpsysCall.$2, containsAllInOrder(
          ['shell', 'dumpsys', 'package', 'com.example.app']));
      // The activity was started (check passed, launch proceeded).
      expect(calls.any((c) => c.$2.contains('am')), isTrue);
    });

    test('fails fast with diagnostic when INTERNET is missing', () async {
      final calls = <(String, List<String>)>[];
      final device = makeDevice(
        calls: calls,
        logcat: FakeProcess(),
        onDumpsys: (args) async => ProcessResult(
          0,
          0,
          dumpsysOutput(package: 'com.example.app', requestedPermissions: [
            'android.permission.VIBRATE',
          ]),
          '',
        ),
      );

      Object? caught;
      try {
        await device.launch('/path/to/app.apk');
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>());
      final message = caught.toString();
      expect(message, contains('com.example.app'));
      expect(message, contains('/path/to/app.apk'));
      expect(message, contains('android.permission.INTERNET'));
      expect(message, contains('Dart VM service'));
      expect(message, contains('android/app/src/debug/AndroidManifest.xml'));
      expect(message, contains('debug_manifest'));

      // Failed before starting the activity or tailing logcat.
      expect(calls.any((c) => c.$2.contains('am')), isFalse);
      expect(calls.any((c) => c.$2.contains('logcat')), isFalse);
    });

    test('fails when the package requests no permissions at all', () async {
      final device = makeDevice(
        calls: [],
        logcat: FakeProcess(),
        onDumpsys: (args) async => ProcessResult(
          0,
          0,
          dumpsysOutput(
              package: 'com.example.app', requestedPermissions: const []),
          '',
        ),
      );

      expect(
        () => device.launch('/path/to/app.apk'),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('android.permission.INTERNET'))),
      );
    });

    test('surfaces dumpsys query failure instead of skipping', () async {
      final device = makeDevice(
        calls: [],
        logcat: FakeProcess(),
        onDumpsys: (args) async =>
            ProcessResult(0, 1, '', 'error: device offline'),
      );

      expect(
        () => device.launch('/path/to/app.apk'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('dumpsys'), contains('error: device offline')),
        )),
      );
    });

    test('surfaces missing package record as an error', () async {
      final device = makeDevice(
        calls: [],
        logcat: FakeProcess(),
        onDumpsys: (args) async =>
            ProcessResult(0, 0, 'Unable to find package: com.example.app', ''),
      );

      expect(
        () => device.launch('/path/to/app.apk'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          allOf(contains('dumpsys'), contains('com.example.app')),
        )),
      );
    });

    test('does not run when the launch expects no VM service', () async {
      final calls = <(String, List<String>)>[];
      final fakeLogcat = FakeProcess();
      final device = AndroidDevice(
        packageName: 'com.example.app',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => fakeLogcat,
      );
      expect(device.expectsVmService, isFalse);

      Future.delayed(Duration(milliseconds: 10), () {
        fakeLogcat.complete(0);
      });

      await device.launch('/path/to/app.apk');

      expect(calls.any((c) => c.$2.contains('dumpsys')), isFalse);
      expect(calls.any((c) => c.$2.contains('am')), isTrue);
    });
  });

  group('MacOSDevice.launch', () {
    test('extracts .app from .zip before launching', () async {
      final calls = <(String, List<String>)>[];
      final fakeAppProcess = FakeProcess();

      final device = MacOSDevice(
        runProcess: (exe, args) async {
          calls.add((exe, args));
          if (exe == 'unzip') {
            // Simulate unzip by creating an .app directory.
            final dest = args.last;
            Directory('$dest/MyApp.app/Contents/MacOS')
                .createSync(recursive: true);
            File('$dest/MyApp.app/Contents/MacOS/MyApp').writeAsStringSync('');
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeAppProcess;
        },
      );

      // Emit VM service URI then complete the process so launch doesn't hang.
      Future.delayed(Duration(milliseconds: 20), () {
        fakeAppProcess.emitStdout(
            'The Dart VM service is listening on http://127.0.0.1:12345/test=/');
      });

      await device.launch('/path/to/app.zip');

      // Should have called unzip.
      final unzipCall = calls.firstWhere((c) => c.$1 == 'unzip');
      expect(unzipCall.$2, contains('/path/to/app.zip'));

      // Should have started the extracted executable.
      final startCalls =
          calls.where((c) => c.$1 != 'unzip' && c.$1 != 'xcrun').toList();
      expect(startCalls, isNotEmpty);
      expect(startCalls.last.$1, contains('MyApp'));
    });

    test('launches .app bundle directly', () async {
      final calls = <(String, List<String>)>[];
      final fakeAppProcess = FakeProcess();

      final device = MacOSDevice(
        startProcess: (exe, args) async {
          calls.add((exe, args));
          return fakeAppProcess;
        },
      );

      // Emit VM service URI so launch doesn't hang waiting for it.
      Future.delayed(Duration(milliseconds: 20), () {
        fakeAppProcess.emitStdout(
            'The Dart VM service is listening on http://127.0.0.1:12345/test=/');
      });

      await device.launch('/path/to/MyApp.app');

      expect(calls, hasLength(1));
      expect(calls[0].$1, '/path/to/MyApp.app/Contents/MacOS/MyApp');
    });
  });

  // Regression coverage for the defect where `_discoverVmServiceUri` cancelled
  // the app's stdout/stderr subscriptions the moment it matched the VM-service
  // announcement. Every line the app printed afterwards — `flutter:` output,
  // NSLog, stack traces — was silently dropped, and the OS pipes went unread.
  // Parameterised over the three desktop devices because they share the launch
  // path and each one regressed identically.
  group('desktop app output forwarding', () {
    /// Builds [device] with an injected [FakeProcess], drives it through a
    /// launch, and hands the test the live instance.
    Future<(AppInstance, FakeProcess)> launchWith(
      Device Function(ProcessStarter) build, {
      List<AppLogLine>? sink,
    }) async {
      final proc = FakeProcess();
      final device = build((exe, args) async => proc);
      final pending = device.launch(
        '/path/to/MyApp.app',
        onLog: sink == null ? null : sink.add,
      );
      // The launch must be listening before the announcement is emitted;
      // FakeProcess streams are live, not replayed.
      await proc.outputAttached;
      proc.emitStdout(_vmServiceLine);
      final instance = await pending;
      return (instance, proc);
    }

    final devices = <String, Device Function(ProcessStarter)>{
      'MacOSDevice': (start) => MacOSDevice(
            runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
            startProcess: start,
          ),
      'LinuxDevice': (start) => LinuxDevice(
            runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
            startProcess: start,
          ),
      'WindowsDevice': (start) => WindowsDevice(startProcess: start),
    };

    devices.forEach((name, build) {
      group(name, () {
        test('keeps forwarding stdout after the VM service is discovered',
            () async {
          final (instance, proc) = await launchWith(build);
          expect(instance.vmServiceUri, isNotNull,
              reason: 'discovery itself must still work');

          proc.emitStdout('flutter: after discovery');
          proc.emitStdout('flutter: still going');
          await pumpEventQueue();

          final texts = instance.logs.read(0).lines.map((l) => l.text);
          expect(texts, contains('flutter: after discovery'));
          expect(texts, contains('flutter: still going'));
        });

        test('keeps forwarding stderr after the VM service is discovered',
            () async {
          final (instance, proc) = await launchWith(build);

          proc.emitStderr('NSLog-style native message\n');
          await pumpEventQueue();

          final line = instance.logs
              .read(0)
              .lines
              .firstWhere((l) => l.text.contains('NSLog-style'));
          expect(line.isError, isTrue,
              reason: 'stderr output must be flagged as an error channel');
        });

        test('delivers output emitted before discovery completes', () async {
          final sink = <AppLogLine>[];
          final proc = FakeProcess();
          final device = build((exe, args) async => proc);
          final pending = device.launch('/path/to/MyApp.app', onLog: sink.add);
          await proc.outputAttached;

          // A startup print that lands before the announcement — the case that
          // matters most when an app dies before ever binding a VM service.
          proc.emitStdout('flutter: early startup line');
          await pumpEventQueue();
          expect(sink.map((l) => l.text), contains('flutter: early startup line'),
              reason: 'output must reach the sink during launch, not be held '
                  'until launch() returns');

          proc.emitStdout(_vmServiceLine);
          await pending;
        });

        test('onLog receives post-discovery lines exactly once', () async {
          final sink = <AppLogLine>[];
          final (_, proc) = await launchWith(build, sink: sink);

          proc.emitStdout('flutter: only once');
          await pumpEventQueue();

          expect(
            sink.where((l) => l.text == 'flutter: only once'),
            hasLength(1),
          );
        });

        test('buffers output so a late reader still sees startup lines',
            () async {
          final (instance, proc) = await launchWith(build);
          proc.emitStdout('flutter: printed before anyone read');
          await pumpEventQueue();

          // A consumer attaching now (the HTTP /logs endpoint, say) still sees
          // everything from the beginning of the run.
          final texts = instance.logs.read(0).lines.map((l) => l.text);
          expect(texts, contains(_vmServiceLine));
          expect(texts, contains('flutter: printed before anyone read'));
        });

        test('stop() closes the log stream', () async {
          final (instance, _) = await launchWith(build);
          final device = build((exe, args) async => FakeProcess());

          await device.stop(instance);
          expect(instance.logs.isClosed, isTrue);
        });
      });
    });
  });

  // `adb logcat` carries the whole device's logging, so the dev tool filters
  // host-side (as flutter_tools does). The previous `flutter:I *:S` adb-level
  // filter hid Java crashes and VM messages entirely.
  group('androidLogFilter', () {
    String? filter(String line) => androidLogFilter(line);

    test('keeps Dart print output', () {
      expect(filter('01-02 03:04:05.678 I/flutter ( 1234): hello'),
          'I/flutter ( 1234): hello');
    });

    test('strips the -v time timestamp prefix', () {
      expect(filter('01-02 03:04:05.678 I/flutter ( 1234): hello'),
          isNot(startsWith('01-02')));
    });

    test('keeps the VM-service announcement, so discovery still works', () {
      const announcement =
          'The Dart VM service is listening on http://127.0.0.1:1234/abc=/';
      final kept =
          filter('01-02 03:04:05.678 I/flutter ( 1234): $announcement');
      expect(kept, isNotNull);
      expect(vmServiceUriPattern.hasMatch(kept!), isTrue);
    });

    test('keeps uncaught Java exceptions', () {
      expect(
        filter('01-02 03:04:05.678 E/AndroidRuntime( 1234): FATAL EXCEPTION'),
        'E/AndroidRuntime( 1234): FATAL EXCEPTION',
        reason: 'the old adb-level filter silenced these entirely',
      );
    });

    test('keeps DartVM messages', () {
      expect(filter('01-02 03:04:05.678 I/DartVM  ( 1234): vm message'),
          isNotNull);
    });

    test('keeps Java stderr', () {
      expect(filter('01-02 03:04:05.678 W/System.err( 1234): trace line'),
          isNotNull);
    });

    test('keeps any fatal log regardless of tag', () {
      expect(filter('01-02 03:04:05.678 F/libc    ( 1234): Fatal signal 11'),
          isNotNull);
    });

    test('drops unrelated system logging', () {
      expect(filter('01-02 03:04:05.678 I/WifiService( 999): scan results'),
          isNull);
      expect(filter('01-02 03:04:05.678 D/SensorManager( 42): reading'), isNull);
    });

    test('drops logcat boundary banners', () {
      expect(filter('--------- beginning of main'), isNull);
    });

    test('drops known-inactionable noise that would otherwise match', () {
      expect(
        filter('01-02 03:04:05.678 F/SurfaceSyncer( 22636): '
            'Failed to find sync for id=9'),
        isNull,
      );
    });

    test('is case-insensitive on the flutter tag', () {
      expect(filter('01-02 03:04:05.678 I/Flutter ( 1234): hi'), isNotNull);
    });

    test('keeps ActivityManager lines only when they mention the app', () {
      expect(
          filter('01-02 03:04:05.678 W/ActivityManager( 42): '
              'Force stopping com.example.flutter app'),
          isNotNull);
      expect(
          filter('01-02 03:04:05.678 W/ActivityManager( 42): '
              'Unrelated service churn'),
          isNull);
    });

    test('drops informational lines from allowlisted crash tags', () {
      // AndroidRuntime is only interesting at W/E/F.
      expect(filter('01-02 03:04:05.678 I/AndroidRuntime( 1): starting'),
          isNull);
    });
  });

  group('parseLogcatLine', () {
    test('splits level, tag and message from a -v time record', () {
      final line =
          parseLogcatLine('01-02 03:04:05.678 E/AndroidRuntime( 1234): boom')!;
      expect(line.level, 'E');
      expect(line.tag, 'AndroidRuntime');
      expect(line.message, 'boom');
    });

    test('handles a space-padded pid', () {
      final line =
          parseLogcatLine('01-02 03:04:05.678 I/flutter (  987): hi')!;
      expect(line.tag, 'flutter');
      expect(line.message, 'hi');
    });

    test('handles a dotted tag', () {
      expect(
          parseLogcatLine('01-02 03:04:05.678 W/System.err( 1): x')!.tag,
          'System.err');
    });

    test('display drops the timestamp but keeps level, tag and pid', () {
      expect(
        parseLogcatLine('01-02 03:04:05.678 I/flutter ( 1234): hello')!.display,
        'I/flutter ( 1234): hello',
      );
    });

    test('returns null for a banner', () {
      expect(parseLogcatLine('--------- beginning of main'), isNull);
    });

    test('returns null for an unparseable line', () {
      expect(parseLogcatLine('garbage'), isNull);
    });
  });

  group('iOS Simulator log capture', () {
    test('the output predicate scopes to the app process', () {
      final predicate = iosSimulatorLogPredicate('MyApp');
      expect(predicate, contains('processImagePath ENDSWITH "MyApp"'));
      expect(predicate, contains('eventType = logEvent'));
    });

    test('the output predicate filters known noise', () {
      final predicate = iosSimulatorLogPredicate('MyApp');
      expect(predicate, contains('NOT(eventMessage BEGINSWITH "assertion failed: ")'));
      expect(predicate, contains('libxpc.dylib'));
    });

    test('the output predicate admits Flutter engine messages', () {
      expect(iosSimulatorLogPredicate('MyApp'),
          contains('senderImagePath ENDSWITH "/Flutter"'));
    });

    test('parseUnifiedLoggingLine extracts the message', () {
      expect(parseUnifiedLoggingLine('  "eventMessage" : "flutter: 21",'),
          'flutter: 21');
    });

    test('parseUnifiedLoggingLine unescapes JSON string content', () {
      expect(parseUnifiedLoggingLine(r'  "eventMessage" : "a \"quoted\" word",'),
          'a "quoted" word');
    });

    test('parseUnifiedLoggingLine ignores other JSON fields', () {
      expect(parseUnifiedLoggingLine('  "processImagePath" : "/x/MyApp",'),
          isNull);
      expect(parseUnifiedLoggingLine('{'), isNull);
    });

    test('parseUnifiedLoggingLine survives malformed JSON', () {
      expect(parseUnifiedLoggingLine('  "eventMessage" : "unterminated'),
          isNull);
    });

    test('launch spawns a second log stream for app output', () async {
      final started = <(String, List<String>)>[];
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async {
          started.add((exe, args));
          return FakeProcess()..complete(0);
        },
      );

      await device.launch('/path/to/MyApp.app');

      final logStreams =
          started.where((c) => c.$2.contains('stream')).toList();
      expect(logStreams, hasLength(2),
          reason: 'one narrow stream for discovery, one for app output');

      // Discovery keeps its content match; output gets the process-scoped
      // predicate. Merging them would make discovery depend on the output
      // predicate's NOT(...) clauses.
      expect(
        logStreams.any((c) => c.$2.any((a) => a.contains('Dart VM service'))),
        isTrue,
      );
      expect(
        logStreams.any((c) => c.$2.any((a) => a.contains('processImagePath'))),
        isTrue,
      );
    });

    test('the app-output stream is killed on stop', () async {
      final spawned = <FakeProcess>[];
      // The launch spawns the discovery stream first and the app-output
      // stream second, and only subscribes to discovery after the simctl
      // launch call — so the test has to wait for both to exist *and* both to
      // be listening before it emits anything into these broadcast streams.
      final bothSpawned = Completer<void>();
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async {
          final p = FakeProcess();
          spawned.add(p);
          if (spawned.length == 2 && !bothSpawned.isCompleted) {
            bothSpawned.complete();
          }
          return p;
        },
      );

      final pending = device.launch('/path/to/MyApp.app');
      await bothSpawned.future;
      await Future.wait([for (final p in spawned) p.outputAttached]);
      // Complete the discovery stream so launch returns.
      for (final p in spawned) {
        p.emitStdout('  "eventMessage" : "$_vmServiceLine",');
      }
      final instance = await pending;

      expect(instance.auxiliaryProcesses, isNotEmpty,
          reason: 'the second stream must be tracked so stop() can kill it');

      await device.stop(instance);
      for (final aux in instance.auxiliaryProcesses) {
        await expectLater(aux.exitCode, completes);
      }
    });
  });

  group('MacOSDevice.screenshot', () {
    test('throws structured error when bundled helper binary is missing',
        () async {
      // The macOS native screenshot path invokes a bundled Swift binary via
      // runfiles (analogous to WindowsDevice). Under unit-test runfiles the
      // binary isn't reachable, so the observable contract is the error that
      // points at the build target.
      final device = MacOSDevice();
      Object? caught;
      try {
        await device.screenshot(
          AppInstance(process: FakeProcess()),
          '/tmp/macos.png',
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>());
      expect(
        caught.toString(),
        contains('bazel build //tools/dev_tool:flutter_bazel'),
      );
    });
  });

  group('LinuxDevice.screenshot', () {
    test('uses scrot when no vmClient', () async {
      final calls = <(String, List<String>)>[];

      final device = LinuxDevice(
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
      );

      final instance = AppInstance(process: FakeProcess());
      await device.screenshot(instance, '/tmp/linux.png');

      expect(calls, hasLength(1));
      expect(calls[0].$1, 'scrot');
      expect(calls[0].$2, ['/tmp/linux.png']);
    });
  });

  group('WindowsDevice.screenshot', () {
    test('throws structured error when bundled dxcam binary is missing',
        () async {
      // The implementation uses `resolveRunfileWithManifest` to locate
      // the bundled dxcam `py_binary` and shells to it directly via
      // `Process.run`; it doesn't go through the injected `runProcess`
      // hook. Under unit-test runfiles the tool isn't reachable, so the
      // observable contract is the actionable error that points at the
      // build target. (This test was previously asserting a powershell
      // codepath that no longer exists.)
      final device = WindowsDevice();
      Object? caught;
      try {
        await device.screenshot(
          AppInstance(process: FakeProcess()),
          r'C:\tmp\win.png',
        );
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<StateError>());
      expect(
        caught.toString(),
        contains('bazel build //tools/dev_tool:flutter_bazel'),
      );
    });
  });

  group('AndroidDevice.screenshot', () {
    test('uses adb screencap when no vmClient', () async {
      final calls = <(String, List<String>)>[];

      final device = AndroidDevice(
        deviceId: 'emulator-5554',
        adbPath: 'adb',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
      );

      final instance = AppInstance(process: FakeProcess());
      await device.screenshot(instance, '/tmp/android.png');

      final adbCalls = calls.where((c) => c.$1 == 'adb').toList();
      expect(adbCalls.length, 3); // screencap, pull, rm
    });
  });

  group('IOSSimulatorDevice.screenshot', () {
    test('calls simctl io screenshot', () async {
      final calls = <(String, List<String>)>[];

      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        runProcess: (exe, args) async {
          calls.add((exe, args));
          return ProcessResult(0, 0, '', '');
        },
      );

      final instance = AppInstance(process: FakeProcess());
      await device.screenshot(instance, '/tmp/ios.png');

      expect(calls, hasLength(1));
      expect(calls[0].$1, 'xcrun');
      expect(
          calls[0].$2, ['simctl', 'io', 'TEST-UDID', 'screenshot', '/tmp/ios.png']);
    });

    test('throws on simctl screenshot failure', () async {
      final device = IOSSimulatorDevice(
        udid: 'TEST-UDID',
        runProcess: (exe, args) async {
          if ((args as List).contains('screenshot')) {
            return ProcessResult(0, 1, '', 'SCREENSHOT_FAILED');
          }
          return ProcessResult(0, 0, '', '');
        },
      );

      final instance = AppInstance(process: FakeProcess());
      expect(
        () => device.screenshot(instance, '/tmp/shot.png'),
        throwsStateError,
      );
    });
  });

  group('Device.screenshot', () {
    test('throws UnsupportedError when no vmClient provided', () {
      final device = _MinimalDevice();
      final instance = AppInstance(process: FakeProcess());
      expect(
        () => device.screenshot(instance, '/tmp/shot.png'),
        throwsUnsupportedError,
      );
    });
  });

  // The physical-device launch is a six-step dance (devicectl --console →
  // pid lookup → lldb attach → resume → mDNS discovery), and the app's console
  // output rides the same devicectl process throughout. Faking the whole
  // sequence is the only way to prove output survives it.
  group('IOSDevice.launch', () {
    final sockets = <ServerSocket>[];
    tearDown(() async {
      for (final s in sockets) {
        await s.close();
      }
      sockets.clear();
    });

    /// What `devicectl list devices` reports for one paired device.
    String devicesJson(String transportType) => json.encode({
          'result': {
            'devices': [
              {
                'identifier': 'TEST-COREDEVICE-ID',
                'hardwareProperties': {'udid': 'TEST-UDID'},
                'deviceProperties': {'name': "Test iPhone"},
                'connectionProperties': {
                  'transportType': transportType,
                  'pairingState': 'paired',
                  'localHostnames': ['Test-iPhone.coredevice.local'],
                },
              },
            ],
          },
        });

    /// Everything one faked launch hands back to the test.
    ///
    /// [args] records every argument list passed to [Process.start], so a test
    /// can assert on what the launch actually asked devicectl to do.
    Future<
        ({
          AppInstance instance,
          FakeProcess devicectl,
          FakeProcess lldb,
          List<List<String>> starts,
        })> launchFaked({
      String transportType = 'wired',
      List<String> deviceAddresses = const [],
      bool consoleExitsAtLaunch = false,
    }) async {
      final devicectl = FakeProcess();
      final lldb = FakeProcess();
      final starts = <List<String>>[];

      // A wired launch port-forwards the advertised VM-service port through
      // iproxy and waits for that forward to accept connections before
      // returning. Stand a real listener up on the port the advertisement
      // names, so the test exercises the whole launch rather than stopping at
      // a missing iproxy.
      final forward = await ServerSocket.bind('127.0.0.1', 0);
      sockets.add(forward);
      // The probe connects to confirm the forward is live; drop each
      // connection rather than leaving it queued in the accept backlog, which
      // would stall `close()` in tearDown.
      forward.listen((socket) => socket.destroy());

      final mdns = MdnsVmServiceDiscovery(
        clientFactory: FakeMDnsClientFactory(
          records: dartVmServiceRecords(
            instance: 'com.example.test',
            host: 'Test-iPhone.local',
            port: forward.port,
            authCode: 'test=',
            addresses: deviceAddresses,
          ),
        ).call,
      );

      final device = IOSDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        mdns: mdns,
        runProcess: (exe, args) async {
          final out = args.contains('--json-output')
              ? args[args.indexOf('--json-output') + 1]
              : null;
          // Both `list devices` and `info processes` write their answer to the
          // file named by --json-output.
          if (args.contains('devices') && out != null) {
            File(out).writeAsStringSync(devicesJson(transportType));
          } else if (args.contains('processes') && out != null) {
            File(out).writeAsStringSync(json.encode({
              'result': {
                'runningProcesses': [
                  {
                    'processIdentifier': 4242,
                    'executable': 'file:///private/var/.../com.example.test',
                  },
                ],
              },
            }));
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async {
          starts.add([exe, ...args.cast<String>()]);
          return exe == 'lldb' ? lldb : devicectl;
        },
      );

      // Script the lldb side: each command the launch issues gets the reply
      // its `waitFor` pattern is looking for.
      lldb.stdinLines.listen((line) {
        if (line.startsWith('breakpoint set')) {
          lldb.emitStdout('Breakpoint 1: where = Foo`NOTIFY...');
        } else if (line.startsWith('device process attach')) {
          lldb.emitStdout('Process 4242 stopped');
        } else if (line.startsWith('process continue')) {
          lldb.emitStdout('Process 4242 resuming');
        }
      });

      final pending = device.launch('/path/to/MyApp.app', onLog: null);
      await devicectl.outputAttached;

      if (consoleExitsAtLaunch) {
        // The console channel ends without ever printing a banner. The launch
        // gate is released by `onDone` instead.
        devicectl.complete(0);
      } else {
        // devicectl's banner releases the launch gate.
        devicectl.emitStdout('Launched application with com.example.test');
      }

      return (
        instance: await pending,
        devicectl: devicectl,
        lldb: lldb,
        starts: starts,
      );
    }

    // The engine's announcement never reaches this host on a physical device,
    // so the URI has to come from the app's mDNS advertisement — including the
    // auth code, without which the VM service refuses the connection.
    test('takes the VM service from the mDNS advertisement', () async {
      final r = await launchFaked();
      expect(r.instance.vmServiceUri, isNotNull);
      expect(r.instance.vmServiceUri!.host, '127.0.0.1');
      expect(r.instance.vmServiceUri!.path, '/test=/');
    });

    // Wired: the VM service binds to the device's loopback, so it is only
    // reachable through a forward.
    test('port-forwards the advertised port when wired', () async {
      final r = await launchFaked(transportType: 'wired');
      final iproxy = r.starts.where((a) => a.first == 'iproxy');
      expect(iproxy, hasLength(1));
      expect(iproxy.single, contains('TEST-UDID'));
      expect(r.instance.vmServiceUri!.host, '127.0.0.1');
    });

    // devicectl lists a CoreDevice UUID as `identifier` and the hardware UDID
    // separately. usbmuxd — which iproxy and lldb both go through — only knows
    // the hardware one; addressing it with the CoreDevice UUID yields a
    // forward that binds locally and then resets every connection, so the run
    // looks like it worked right up until DDS fails.
    test('addresses iproxy and lldb with the hardware UDID', () async {
      final r = await launchFaked(transportType: 'wired');
      expect(r.starts.firstWhere((a) => a.first == 'iproxy'),
          contains('TEST-UDID'));
      expect(r.starts.firstWhere((a) => a.first == 'iproxy'),
          isNot(contains('TEST-COREDEVICE-ID')));
    });

    test('does not bind the VM service to all interfaces when wired',
        () async {
      final r = await launchFaked(transportType: 'wired');
      final launch = r.starts.firstWhere((a) => a.contains('launch'));
      expect(launch, isNot(contains('--vm-service-host=0.0.0.0')));
    });

    // Wireless: there is no cable to forward through, so the VM service has to
    // listen on all interfaces and gets dialed at the device's own address.
    // The two halves must agree or the session silently has no VM service.
    test('binds the VM service to all interfaces when wireless', () async {
      final r = await launchFaked(
          transportType: 'localNetwork', deviceAddresses: ['192.168.1.244']);
      final launch = r.starts.firstWhere((a) => a.contains('launch'));
      expect(launch, contains('--vm-service-host=0.0.0.0'));
    });

    test('dials the device address directly when wireless', () async {
      final r = await launchFaked(
          transportType: 'localNetwork', deviceAddresses: ['192.168.1.244']);
      expect(r.instance.vmServiceUri!.host, '192.168.1.244');
      expect(r.starts.where((a) => a.first == 'iproxy'), isEmpty,
          reason: 'there is no cable to forward through');
    });

    test('keeps forwarding console output after VM-service discovery',
        () async {
      final r = await launchFaked();
      expect(r.instance.vmServiceUri, isNotNull,
          reason: 'discovery must still work');

      r.devicectl.emitStderr('flutter: printed well after launch\n');
      await pumpEventQueue();

      expect(r.instance.logs.read(0).lines.map((l) => l.text),
          contains('flutter: printed well after launch'));
    });

    test('does not flag devicectl stderr as error output', () async {
      final r = await launchFaked();

      // devicectl routes the app's ordinary console output to stderr, so
      // flagging that channel would mark every print() as an error.
      r.devicectl.emitStderr('flutter: an ordinary print\n');
      await pumpEventQueue();

      final line = r.instance.logs
          .read(0)
          .lines
          .firstWhere((l) => l.text.contains('an ordinary print'));
      expect(line.isError, isFalse);
    });

    test('keeps draining lldb after launch returns', () async {
      // lldb outlives launch() and holds the debugserver that keeps the app's
      // JIT alive. Stop reading its pipes and it blocks on write once its
      // stdout buffer fills; a blocked lldb never services the process it
      // controls, so the app hangs on device until the dev tool is killed.
      final r = await launchFaked();

      // Far more than a pipe buffer would hold. If nothing is draining, a
      // real lldb would be blocked by now.
      for (var i = 0; i < 2000; i++) {
        r.lldb.emitStdout('lldb chatter line $i with padding ${'x' * 200}');
      }
      await pumpEventQueue();

      // The fake cannot block, so assert the property that matters: a live
      // reader is still attached to both channels.
      expect(r.lldb.stdoutHasListener, isTrue,
          reason: 'lldb stdout must stay drained for the process lifetime');
      expect(r.lldb.stderrHasListener, isTrue,
          reason: 'lldb stderr carries the reason for real lldb failures');
    });

    test('lldb output reaches the app log stream', () async {
      // Upstream treats devicectl and lldb as one combined log source on a
      // CoreDevice under Xcode 26+, because the debugger carries output the
      // console stream may not.
      final r = await launchFaked();

      r.lldb.emitStdout('flutter: hello from the app');
      await pumpEventQueue();

      expect(r.instance.logs.read(0).lines.map((l) => l.text),
          contains('flutter: hello from the app'));
    });

    test('lldb output survives devicectl exiting', () async {
      // devicectl --console exits when the app terminates, which is precisely
      // when lldb produces the output that explains why. Closing the shared
      // stream on the first source to finish threw that away.
      final r = await launchFaked();

      r.devicectl.complete(0);
      await pumpEventQueue();

      r.lldb.emitStdout('flutter: Fatal error: index out of range');
      await pumpEventQueue();

      expect(r.instance.logs.read(0).lines.map((l) => l.text),
          contains('flutter: Fatal error: index out of range'),
          reason: 'the crash report arrives after the console channel is gone');
    });

    test('lldb output survives a console channel that ends before the attach',
        () async {
      // `devicectl --console` normally runs for the app's lifetime, but it can
      // end during the launch — the app was already running, or devicectl
      // detached — while the app itself stays up and `_findAppProcessId` still
      // answers. lldb attaches after that point, so if the console channel
      // being the only registered producer is enough to close the shared log
      // stream, every line for the rest of the run goes nowhere: mDNS
      // discovery does not read this stream, so nothing else fails and the run
      // proceeds in silence.
      final r = await launchFaked(consoleExitsAtLaunch: true);

      expect(r.instance.logs.isClosed, isFalse,
          reason: 'lldb is attached and is still a live source of output');

      r.lldb.emitStdout('flutter: hello from the app');
      await pumpEventQueue();

      expect(r.instance.logs.read(0).lines.map((l) => l.text),
          contains('flutter: hello from the app'));
    });

    test('the log stream closes once devicectl and lldb have both ended',
        () async {
      final r = await launchFaked();
      expect(r.instance.logs.isClosed, isFalse);

      r.devicectl.complete(0);
      await pumpEventQueue();
      expect(r.instance.logs.isClosed, isFalse,
          reason: 'lldb is still attached and still reporting');

      r.lldb.complete(0);
      await pumpEventQueue();
      expect(r.instance.logs.isClosed, isTrue,
          reason: 'a reader must learn the run is over rather than hang');
    });
  });

  // `devicectl list devices` lists every device that has ever been paired,
  // including ones that are not attached now.
  group('parseDevicectlDevices', () {
    String devicesJson(List<Map<String, Object?>> devices) =>
        json.encode({'result': {'devices': devices}});

    test('reads udid, name, transport and hostnames', () {
      final devices = parseDevicectlDevices(devicesJson([
        {
          'identifier': 'CORE-1',
          'hardwareProperties': {'udid': 'UDID-1'},
          'deviceProperties': {'name': "Aran's iPhone 12 Pro"},
          'connectionProperties': {
            'transportType': 'wired',
            'localHostnames': [
              'Arans-iPhone-12-Pro.coredevice.local',
              'UDID-1.coredevice.local',
            ],
          },
        },
      ]));

      expect(devices, hasLength(1));
      expect(devices.single.udid, 'UDID-1');
      expect(devices.single.coreDeviceId, 'CORE-1');
      expect(devices.single.name, "Aran's iPhone 12 Pro");
      expect(devices.single.transport, IOSDeviceTransport.wired);
      expect(devices.single.hostnames,
          contains('Arans-iPhone-12-Pro.coredevice.local'));
    });

    test('maps localNetwork to wireless', () {
      final devices = parseDevicectlDevices(devicesJson([
        {
          'identifier': 'CORE-1',
          'hardwareProperties': {'udid': 'UDID-1'},
          'connectionProperties': {'transportType': 'localNetwork'},
        },
      ]));
      expect(devices.single.transport, IOSDeviceTransport.wireless);
    });

    // A device paired once and now sitting in a drawer still appears, with no
    // transport and `tunnelState: unavailable`. Choosing it produces a launch
    // that installs nothing and then waits out every timeout.
    test('drops a paired but unattached device', () {
      final devices = parseDevicectlDevices(devicesJson([
        {
          'identifier': 'CORE-GONE',
          'hardwareProperties': {'udid': 'GONE'},
          'connectionProperties': {
            'pairingState': 'paired',
            'tunnelState': 'unavailable',
          },
        },
        {
          'identifier': 'CORE-HERE',
          'hardwareProperties': {'udid': 'HERE'},
          'connectionProperties': {'transportType': 'wired'},
        },
      ]));
      expect(devices.map((d) => d.udid), ['HERE']);
    });

    test('falls back to potentialHostnames when there are no local ones', () {
      final devices = parseDevicectlDevices(devicesJson([
        {
          'identifier': 'CORE-1',
          'hardwareProperties': {'udid': 'UDID-1'},
          'connectionProperties': {
            'transportType': 'wired',
            'potentialHostnames': ['Some-iPhone.coredevice.local'],
          },
        },
      ]));
      expect(devices.single.hostnames, ['Some-iPhone.coredevice.local']);
    });
  });

  group('IOSDevice device selection', () {
    IOSDevice deviceListing(List<Map<String, Object?>> devices,
            {String? udid}) =>
        IOSDevice(
          udid: udid,
          bundleId: 'com.example.test',
          runProcess: (exe, args) async {
            if (args.contains('devices') && args.contains('--json-output')) {
              File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(
                  json.encode({'result': {'devices': devices}}));
              return ProcessResult(0, 0, '', '');
            }
            // Selection is what these tests are about, so stop the launch at
            // the next step rather than driving the whole device dance.
            return ProcessResult(0, 1, '', 'INSTALL_FAILED');
          },
          startProcess: (exe, args) async => FakeProcess(),
        );

    test('ignores a paired but unattached device when auto-detecting',
        () async {
      final device = deviceListing([
        {
          'identifier': 'CORE-GONE',
          'hardwareProperties': {'udid': 'GONE'},
          'connectionProperties': {'tunnelState': 'unavailable'},
        },
      ]);

      await expectLater(
        device.launch('/path/to/MyApp.app'),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            contains('No iOS device is attached'))),
      );
    });

    // Picking one silently would look like a working run against the wrong
    // phone.
    test('refuses to guess between two attached devices', () async {
      final device = deviceListing([
        {
          'identifier': 'CORE-ONE',
          'hardwareProperties': {'udid': 'ONE'},
          'connectionProperties': {'transportType': 'wired'},
        },
        {
          'identifier': 'CORE-TWO',
          'hardwareProperties': {'udid': 'TWO'},
          'connectionProperties': {'transportType': 'localNetwork'},
        },
      ]);

      await expectLater(
        device.launch('/path/to/MyApp.app'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('-d ios:<udid>'))
            .having((e) => e.message, 'message', contains('ONE'))),
      );
    });

    // `devicectl list devices` prints the CoreDevice UUID, so that is what a
    // user copying from it will pass; Xcode shows the hardware UDID. Both name
    // the same device.
    test('accepts either the hardware UDID or the CoreDevice identifier',
        () async {
      for (final requested in ['UDID-1', 'CORE-1']) {
        final device = deviceListing([
          {
            'identifier': 'CORE-1',
            'hardwareProperties': {'udid': 'UDID-1'},
            'connectionProperties': {'transportType': 'wired'},
          },
        ], udid: requested);

        // Gets past selection and stops at the faked install.
        await expectLater(
          device.launch('/path/to/MyApp.app'),
          throwsA(isA<StateError>().having(
              (e) => e.message, 'message', contains('INSTALL_FAILED'))),
        );
      }
    });

    test('says which devices are attached when the requested one is not',
        () async {
      final device = deviceListing([
        {
          'identifier': 'CORE-OTHER',
          'hardwareProperties': {'udid': 'OTHER'},
          'connectionProperties': {'transportType': 'wired'},
        },
      ], udid: 'MISSING');

      await expectLater(
        device.launch('/path/to/MyApp.app'),
        throwsA(isA<StateError>()
            .having((e) => e.message, 'message', contains('MISSING'))
            .having((e) => e.message, 'message', contains('OTHER'))),
      );
    });
  });

  group('IOSDevice', () {
    test('has correct name with udid', () {
      final device = IOSDevice(udid: '00008101-001C512E14D2001E');
      expect(device.name, 'iOS (00008101-001C512E14D2001E)');
    });

    test('buildArgs is arm64 for physical device', () {
      final device = IOSDevice(udid: 'TEST-UDID');
      expect(device.buildArgs, ['--ios_multi_cpus=arm64']);
    });

    test('throws on devicectl install failure', () async {
      final device = IOSDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          if ((args as List).contains('install')) {
            return ProcessResult(0, 1, '', 'INSTALL_FAILED');
          }
          if (args.contains('devices') && args.contains('--json-output')) {
            File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(
                json.encode({
              'result': {
                'devices': [
                  {
                    'identifier': 'TEST-COREDEVICE-ID',
                    'hardwareProperties': {'udid': 'TEST-UDID'},
                    'connectionProperties': {'transportType': 'wired'},
                  },
                ],
              },
            }));
          }
          return ProcessResult(0, 0, '', '');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      expect(() => device.launch('/path/to/MyApp.app'), throwsStateError);
    });

    test('stop kills iproxy and devicectl', () async {
      final fakeDevicectl = FakeProcess();

      final device = IOSDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
        startProcess: (exe, args) async => fakeDevicectl,
      );

      final instance = AppInstance(process: fakeDevicectl);
      await device.stop(instance);

      // Process should have been killed.
      expect(await fakeDevicectl.exitCode, -1);
    });

  });

  group('Device.applyTimeout', () {
    /// An [IOSDevice] that has resolved a device of the given transport.
    Future<IOSDevice> launchedDevice(String transportType) async {
      final device = IOSDevice(
        udid: 'TEST-UDID',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          if (args.contains('devices') && args.contains('--json-output')) {
            File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(
                json.encode({
              'result': {
                'devices': [
                  {
                    'identifier': 'TEST-COREDEVICE-ID',
                    'hardwareProperties': {'udid': 'TEST-UDID'},
                    'connectionProperties': {'transportType': transportType},
                  },
                ],
              },
            }));
            return ProcessResult(0, 0, '', '');
          }
          return ProcessResult(0, 1, '', 'INSTALL_FAILED');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );
      // Resolution happens on the way to the faked install failure.
      await expectLater(device.launch('/path/to/MyApp.app'), throwsStateError);
      return device;
    }

    // A hot restart on hardware re-JITs the app through the lldb breakpoint,
    // which is minutes-scale work. The host default would abandon the RPC and
    // force-close the VM-service connection mid-restart, reporting "timed out"
    // for a restart that was going to succeed.
    test('is far longer on a physical iOS device than on a host', () {
      expect(IOSDevice(udid: 'X').applyTimeout,
          greaterThan(MacOSDevice().applyTimeout));
      expect(IOSDevice(udid: 'X').applyTimeout,
          greaterThanOrEqualTo(const Duration(minutes: 1)));
    });

    // Re-JITing the app over Wi-Fi took ~400s against ~43s over a cable, so a
    // budget that fits a wired restart abandons a wireless one mid-flight.
    test('is longer again when the device is on the network', () async {
      final wired = await launchedDevice('wired');
      final wireless = await launchedDevice('localNetwork');
      expect(wireless.applyTimeout, greaterThan(wired.applyTimeout));
    });

    test('reports the hardware UDID once resolved, whatever was asked for',
        () async {
      final device = IOSDevice(
        udid: 'CORE-1',
        bundleId: 'com.example.test',
        runProcess: (exe, args) async {
          if (args.contains('devices') && args.contains('--json-output')) {
            File(args[args.indexOf('--json-output') + 1]).writeAsStringSync(
                json.encode({
              'result': {
                'devices': [
                  {
                    'identifier': 'CORE-1',
                    'hardwareProperties': {'udid': 'UDID-1'},
                    'connectionProperties': {'transportType': 'wired'},
                  },
                ],
              },
            }));
            return ProcessResult(0, 0, '', '');
          }
          return ProcessResult(0, 1, '', 'INSTALL_FAILED');
        },
        startProcess: (exe, args) async => FakeProcess(),
      );

      expect(device.udid, 'CORE-1', reason: 'nothing resolved yet');
      await expectLater(device.launch('/path/to/MyApp.app'), throwsStateError);
      expect(device.udid, 'UDID-1',
          reason: 'usbmuxd-backed tools cannot use the CoreDevice UUID');
    });

    test('a simulator keeps the host budget', () {
      expect(IOSSimulatorDevice(udid: 'X').applyTimeout,
          MacOSDevice().applyTimeout);
    });
  });

  group('IOSDevice.screenshot', () {
    test('throws when not running in Bazel runfiles', () async {
      final device = IOSDevice(
        udid: 'TEST-UDID',
        runProcess: (exe, args) async => ProcessResult(0, 0, '', ''),
      );

      final instance = AppInstance(process: FakeProcess());
      // Without runfiles, should throw telling user to build with bazel.
      expect(
        () => device.screenshot(instance, '/tmp/ios.png'),
        throwsA(isA<StateError>().having(
          (e) => e.message,
          'message',
          contains('bazel build'),
        )),
      );
    });
  });

  group('resolveRunfile', () {
    test('returns null when not in Bazel runfiles', () {
      final result = resolveRunfile('_main/some/nonexistent/path');
      expect(result, isNull);
    });
  });

  group('resolveDevices ios', () {
    test('resolves ios to IOSDevice', () {
      final devices = resolveDevices(['ios']);
      expect(devices.single, isA<IOSDevice>());
    });

    test('resolves ios:UDID to IOSDevice with udid', () {
      final devices = resolveDevices(['ios:ABC-123']);
      final device = devices.single as IOSDevice;
      expect(device.udid, 'ABC-123');
    });
  });

  group('resolveAdb', () {
    test('returns a string', () {
      final result = resolveAdb();
      expect(result, isA<String>());
      expect(result, isNotEmpty);
    });
  });

  group('extractPackageInfo', () {
    test('parses aapt2 dump badging output', () async {
      final info = await extractPackageInfo(
        '/fake/app.apk',
        runProcess: (exe, args) async {
          return ProcessResult(0, 0,
              "package: name='com.example.myapp' versionCode='1'\n"
              "launchable-activity: name='com.example.myapp.MainActivity'\n",
              '');
        },
      );
      expect(info.packageName, 'com.example.myapp');
      expect(info.activityName, 'com.example.myapp.MainActivity');
    });

    test('throws on aapt2 failure', () {
      expect(
        () => extractPackageInfo(
          '/fake/app.apk',
          runProcess: (exe, args) async =>
              ProcessResult(0, 1, '', 'not found'),
        ),
        throwsStateError,
      );
    });
  });

  group('waitForLocalTcpPort', () {
    test('returns once a listener accepts', () async {
      final server = await ServerSocket.bind('127.0.0.1', 0);
      addTearDown(server.close);
      await waitForLocalTcpPort(server.port, what: 'test listener');
    });

    test('waits for a listener that binds late', () async {
      // Grab a free port, then release it so nothing is listening when the
      // wait starts; bind for real shortly after.
      final probe = await ServerSocket.bind('127.0.0.1', 0);
      final port = probe.port;
      await probe.close();

      ServerSocket? server;
      addTearDown(() => server?.close());
      final lateBind = Future<void>.delayed(
        const Duration(milliseconds: 300),
        () async => server = await ServerSocket.bind('127.0.0.1', port),
      );
      await waitForLocalTcpPort(port, what: 'late listener');
      await lateBind;
      expect(server, isNotNull);
    });

    test('throws a StateError naming the forward when nothing binds',
        () async {
      final probe = await ServerSocket.bind('127.0.0.1', 0);
      final port = probe.port;
      await probe.close();

      await expectLater(
        waitForLocalTcpPort(
          port,
          what: 'iproxy forward',
          budget: const Duration(milliseconds: 400),
        ),
        throwsA(isA<StateError>().having(
            (e) => e.message, 'message', contains('iproxy forward'))),
      );
    });
  });
}

class _MinimalDevice extends Device {
  @override
  String get name => 'Minimal';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) => throw UnimplementedError();

  @override
  Future<void> stop(AppInstance instance) => throw UnimplementedError();
}
