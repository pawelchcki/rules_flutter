/// Device abstraction for launching Flutter apps.
///
/// Handles platform-specific launch, VM service discovery, and
/// process lifecycle management.
///
/// ## One log source per platform
///
/// Every launched app exposes its console output on [AppInstance.logs]. Which
/// source feeds that stream is a per-platform decision, and there is exactly
/// one source per platform — this is an invariant, not a preference:
///
/// | Platform            | Source                                        |
/// | ------------------- | --------------------------------------------- |
/// | macOS/Linux/Windows | the app process's stdout + stderr             |
/// | Android             | `adb logcat`                                  |
/// | iOS Simulator       | a dedicated `simctl spawn log stream`         |
/// | iOS device          | `devicectl --console`, plus lldb's own output |
/// | Chrome (DDC)        | DWDS VM service `Stdout`/`Stderr` streams     |
/// | Chrome (WASM)       | CDP `Runtime.consoleAPICalled`                |
/// | attach mode         | VM service `Stdout`/`Stderr` streams          |
///
/// A Dart `print()` on a native device reaches *both* the process's stdout and
/// the VM service's `Stdout` stream, so subscribing to both would print every
/// line twice. VM-service streams are therefore used only where no process log
/// source exists (web, attach). This mirrors flutter_tools' `DeviceLogReader`
/// and is the reason the tempting "just read the VM service everywhere"
/// simplification is wrong.
///
/// ## Finding the VM service
///
/// On every platform above, the VM-service URI arrives in-band: the engine
/// prints it, so discovery is a *reader* of the log stream and never an owner
/// of the underlying subscriptions (see [pumpProcessLines] and
/// [discoverVmServiceUri]).
///
/// A physical iOS device is the one exception, and it is out-of-band rather
/// than a second in-band source: a wirelessly attached device has no console
/// channel at all, and the one a wired device has belongs to the `devicectl`
/// invocation that launched the app. The URI is taken from the app's
/// `_dartVmService._tcp` mDNS advertisement instead
/// ([MdnsVmServiceDiscovery]). That is the single mechanism for iOS hardware,
/// wired and wireless alike; nothing races it.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'app_log.dart';
import 'cdp_console.dart';
import 'compiler_config.dart';
import 'host_tools.dart';
import 'mdns_vm_service_discovery.dart';
import 'reload_strategy.dart';
import 'runfiles_helper.dart';
import 'toolchain_info.dart';
import 'vm_service_client.dart';
import 'web_module_server.dart';

export 'app_log.dart' show AppLogLine, AppLogStream, LogPage;
export 'host_tools.dart' show HostTool, MissingHostToolException;

/// Called for each line of a running app's console output.
typedef AppLogListener = void Function(AppLogLine line);

/// A running Flutter application instance.
class AppInstance {
  final Process process;
  final Uri? vmServiceUri;

  /// Optional HTTP server (used by WebDevice).
  final HttpServer? server;

  /// The app's console output, for the lifetime of the run.
  ///
  /// Buffered, so a consumer that attaches after launch still sees everything
  /// printed during startup. Closed by the owning device's `stop()`.
  final AppLogStream logs;

  /// Helper processes spawned alongside [process] that must die with the run —
  /// e.g. the iOS Simulator's second `log stream`. Tracked here so `stop()`
  /// cannot leak them, rather than each device inventing its own field.
  final List<Process> auxiliaryProcesses;

  AppInstance({
    required this.process,
    this.vmServiceUri,
    this.server,
    AppLogStream? logs,
    this.auxiliaryProcesses = const [],
  }) : logs = logs ?? AppLogStream();

  /// Kill every [auxiliaryProcesses] entry and await its exit.
  Future<void> disposeAuxiliaryProcesses() async {
    for (final aux in auxiliaryProcesses) {
      aux.kill();
    }
    await Future.wait(auxiliaryProcesses.map((a) => a.exitCode));
  }
}

/// Abstract device that can launch and manage a Flutter app.
abstract class Device {
  /// Launch the app and return the running instance.
  ///
  /// [appPath] is the path to the built application artifact.
  ///
  /// [onLog] is attached to the app's output stream *before* VM-service
  /// discovery begins, so a caller sees startup output as it happens rather
  /// than in a burst once `launch` returns. That matters most when discovery
  /// never succeeds: an app that crashes before binding its VM service prints
  /// the reason during the discovery window. Callers that pass [onLog] must
  /// not also subscribe to [AppInstance.logs], or every line arrives twice.
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog});

  /// Stop the running app.
  Future<void> stop(AppInstance instance);

  /// The external programs a launch on this device will drive.
  ///
  /// Declared rather than discovered at each call site so [preflight] can check
  /// them all before a run does any work, and declared *per device* so an iOS,
  /// macOS or Chrome run is never made to install the Android SDK. Async
  /// because the answer can depend on the device itself: a cabled iOS device is
  /// reached through an `iproxy` forward and a wireless one is not.
  Future<List<HostTool>> requiredHostTools() async => const [];

  /// Fail now, by name, if the host is missing anything this device needs.
  ///
  /// Called before the build, so a missing `aapt2` or an unattached phone is
  /// reported in seconds. Without it the shortfall surfaces mid-launch as a
  /// symptom instead of a cause — the case this replaces installed an APK it
  /// could not name, started no activity, and then reported that no VM service
  /// was discovered.
  Future<void> preflight() async {
    for (final tool in await requiredHostTools()) {
      tool.require();
    }
  }

  /// Capture a screenshot of the running app.
  ///
  /// For native platforms, uses the VM service `_flutter.screenshot` extension
  /// (pass [vmClient]). For web, subclasses override with CDP.
  /// Throws [UnsupportedError] if no VM client is available.
  ///
  /// [window] is an optional, platform-specific selector for which window to
  /// capture (e.g. on macOS, the exact window title). Devices that don't
  /// support window selection ignore it.
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    throw UnsupportedError(
        'Screenshot not supported on $name without VM service');
  }

  /// Whether `_flutter.screenshot` — the VM-service capture of just the
  /// widget tree — can ever succeed on this device.
  ///
  /// The engine cannot encode a compressed screenshot under Impeller, so the
  /// RPC fails with a bare "Could not capture image screenshot" wherever
  /// Impeller renders; on iOS and on web there is no other renderer to fall
  /// back to. Declared per device rather than inferred from a failure, so a
  /// caller is told the request can never work — and which endpoint does —
  /// instead of getting a 500 that reads as transient and invites a retry.
  bool get supportsFlutterScreenshot => true;

  /// Display name for this device.
  String get name;

  /// How long a single hot reload or hot restart RPC may take here.
  ///
  /// A latency budget, not a correctness knob: the call is abandoned and the
  /// VM-service connection force-closed when it expires, so it has to be
  /// longer than the slowest legitimate apply on this platform. The default
  /// suits a host process, where the VM is local and a restart is
  /// milliseconds of work.
  Duration get applyTimeout => const Duration(seconds: 30);

  /// Pick the runnable artifact from a target's cquery outputs.
  ///
  /// Default returns the first output. Subclasses override when the
  /// rule emits multiple outputs in an order that doesn't put the
  /// runnable artifact first — `android_binary`, for example, lists
  /// `<name>_deploy.jar` before `<name>.apk`, and the deploy jar is
  /// not installable.
  String pickArtifact(List<String> outputs) => outputs.first;

  /// Platform-specific arguments for `bazel build`.
  ///
  /// These are injected into `bazel build` and `bazel cquery` to ensure
  /// correct cross-compilation and output resolution.
  List<String> get buildArgs => const [];

  /// Create the compiler config for hot reload on this platform.
  ///
  /// Returns null if this device does not support hot reload.
  CompilerConfig? createCompilerConfig(
    ToolchainPaths toolchain, {
    WebToolchainPaths? webToolchain,
    List<String> fileSystemRoots = const [],
    String fileSystemScheme = '',
    List<String> dartDefines = const [],
    String dartPluginRegistrantUri = '',
  }) =>
      NativeCompilerConfig(
        patchedSdkRoot: toolchain.patchedSdkRoot,
        fileSystemRoots: fileSystemRoots,
        fileSystemScheme: fileSystemScheme,
        dartDefines: dartDefines,
        dartPluginRegistrantUri: dartPluginRegistrantUri,
      );

  /// Create the reload strategy for this platform.
  ///
  /// Returns null if this device does not support hot reload.
  ReloadStrategy? createReloadStrategy() => VmServiceReloadStrategy();
}

/// macOS desktop device.
class MacOSDevice extends Device {
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  MacOSDevice({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  })  : _runProcess = runProcess ?? Process.run,
        _startProcess = startProcess ?? _defaultStart;

  static Future<Process> _defaultStart(String exe, List<String> args) {
    return Process.start(exe, args, environment: {
      ...Platform.environment,
      'FLUTTER_VM_SERVICE_PORT': '0',
    });
  }

  @override
  String get name => 'macOS';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    // Extract .app from .zip if needed (Bazel macOS bundles are zipped).
    String resolvedPath = appPath;
    if (appPath.endsWith('.zip')) {
      resolvedPath = await _extractAppFromZip(appPath);
    }

    // For .app bundles, find the executable inside.
    String executable;
    if (resolvedPath.endsWith('.app')) {
      // The executable is at Contents/MacOS/<name>.
      final bundleName = resolvedPath.split('/').last.replaceAll('.app', '');
      executable = '$resolvedPath/Contents/MacOS/$bundleName';
    } else {
      executable = resolvedPath;
    }

    final process = await _startProcess(
      executable,
      [],
    );

    final logs = _startProcessLogs(process, onLog);
    final vmServiceUri = await discoverVmServiceUri(logs);

    return AppInstance(
        process: process, vmServiceUri: vmServiceUri, logs: logs);
  }

  @override
  Future<void> stop(AppInstance instance) async {
    if (!instance.process.kill()) {
      stderr.writeln(
          'Warning: Failed to kill macOS app process (pid ${instance.process.pid}).');
    }
    await instance.process.exitCode;
    await instance.logs.close();
  }

  /// Captures the launched app's windows via the bundled Swift helper.
  ///
  /// With [vmClient] set, uses `_flutter.screenshot` (Flutter view only).
  /// Otherwise invokes `tools/macos_screenshot:screenshot`, which uses
  /// ScreenCaptureKit's `SCShareableContent` to enumerate on-screen windows
  /// owned by the app's PID and either composites all of them or — when
  /// [window] is provided — captures only the window whose `SCWindow.title`
  /// matches exactly. The helper requires Screen Recording permission for
  /// the terminal that launched the dev tool.
  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    final resolved = resolveRunfileWithManifest(
        'rules_flutter/tools/macos_screenshot/screenshot');
    if (resolved == null) {
      throw StateError(
          'Could not find bundled macOS screenshot tool. '
          'Build first: bazel build //tools/dev_tool:flutter_bazel');
    }
    final result = await Process.run(
      resolved.path,
      [
        '--pid', '${instance.process.pid}',
        '--output', outputPath,
        if (window != null) ...['--title', window],
      ],
      environment: {
        ...Platform.environment,
        if (resolved.manifestPath != null)
          'RUNFILES_MANIFEST_FILE': resolved.manifestPath!,
      },
    );
    if (result.exitCode != 0) {
      throw StateError('macOS screenshot failed: ${result.stderr}');
    }
  }

  /// Extract .app bundle from a .zip archive.
  Future<String> _extractAppFromZip(String zipPath) async {
    final tempDir = await Directory.systemTemp.createTemp('flutter_macos_');
    final result =
        await _runProcess('unzip', ['-oq', zipPath, '-d', tempDir.path]);
    if (result.exitCode != 0) {
      throw StateError('Failed to extract zip: ${result.stderr}');
    }
    // Find the .app bundle inside.
    final apps =
        tempDir.listSync().where((e) => e.path.endsWith('.app')).toList();
    if (apps.isEmpty) {
      throw StateError('No .app bundle found in zip');
    }
    return apps.first.path;
  }
}

/// Linux desktop device.
class LinuxDevice extends Device {
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  LinuxDevice({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  })  : _runProcess = runProcess ?? Process.run,
        _startProcess = startProcess ?? _defaultStart;

  static Future<Process> _defaultStart(String exe, List<String> args) {
    return Process.start(exe, args, environment: {
      ...Platform.environment,
      'FLUTTER_VM_SERVICE_PORT': '0',
    });
  }

  @override
  String get name => 'Linux';

  @override
  List<String> get buildArgs => Platform.isLinux
      ? const []
      : const ['--platforms=@rules_flutter//flutter/platforms:linux_x64'];

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    // Bundle directories contain the executable at <dir>/<name>.
    String executable = appPath;
    if (FileSystemEntity.isDirectorySync(appPath)) {
      final dirName = p.basename(appPath);
      executable = p.join(appPath, dirName);
    }

    final process = await _startProcess(executable, []);
    final logs = _startProcessLogs(process, onLog);
    final vmServiceUri = await discoverVmServiceUri(logs);
    return AppInstance(
        process: process, vmServiceUri: vmServiceUri, logs: logs);
  }

  @override
  Future<void> stop(AppInstance instance) async {
    if (!instance.process.kill()) {
      stderr.writeln(
          'Warning: Failed to kill Linux app process (pid ${instance.process.pid}).');
    }
    await instance.process.exitCode;
    await instance.logs.close();
  }

  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    final result = await _runProcess('scrot', [outputPath]);
    if (result.exitCode != 0) {
      throw StateError('scrot failed: ${result.stderr}');
    }
  }
}

/// Windows desktop device.
class WindowsDevice extends Device {
  final ProcessStarter _startProcess;
  final Directory Function() _makeStagingDir;
  Directory? _staged;

  WindowsDevice({
    ProcessStarter? startProcess,
    Directory Function()? makeStagingDir,
  })  : _startProcess = startProcess ?? _defaultStart,
        _makeStagingDir = makeStagingDir ?? _defaultStagingDir;

  static Directory _defaultStagingDir() =>
      Directory.systemTemp.createTempSync('flutter_bazel_win_app');

  static Future<Process> _defaultStart(String exe, List<String> args) {
    return Process.start(exe, args, environment: {
      ...Platform.environment,
      'FLUTTER_VM_SERVICE_PORT': '0',
    });
  }

  @override
  String get name => 'Windows';

  @override
  List<String> get buildArgs => Platform.isWindows
      ? const []
      : const ['--platforms=@rules_flutter//flutter/platforms:windows_x64'];

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    // Run from a copy, never from `bazel-out` itself.
    //
    // Windows holds an exclusive lock on a running executable image, so while
    // the app is up, bazel cannot replace `bin/app/app.exe` — and the bundling
    // action does exactly that on any rebuild. `app.restart` rebuilds before
    // it swaps the kernel in, so every restart that follows a real source edit
    // died at "failed to delete output files before executing action:
    // ...app.exe (Permission denied)" and never reached the VM service. A
    // restart with nothing to rebuild succeeded, which is what made this look
    // intermittent. macOS and Linux let a running image be unlinked and
    // replaced, so only Windows needs the copy.
    final launchPath = _stage(appPath);

    // Bundle directories contain the executable at <dir>/<name>.exe.
    String executable = launchPath;
    if (FileSystemEntity.isDirectorySync(launchPath)) {
      final dirName = p.basename(launchPath);
      executable = p.join(launchPath, '$dirName.exe');
    }

    final process = await _startProcess(executable, []);
    final logs = _startProcessLogs(process, onLog);
    final vmServiceUri = await discoverVmServiceUri(logs);
    return AppInstance(
        process: process, vmServiceUri: vmServiceUri, logs: logs);
  }

  /// Copies the built bundle out of `bazel-out` and returns the copy's path.
  ///
  /// A bundle is a directory whose layout the runner depends on — it resolves
  /// `data/flutter_assets` relative to its own executable — so the whole tree
  /// is copied, not just the `.exe`. Each launch gets a fresh directory and
  /// the previous one is removed, so a relaunch never runs yesterday's assets.
  String _stage(String appPath) {
    _clearStaging();
    final staging = _makeStagingDir();
    _staged = staging;

    final source = FileSystemEntity.typeSync(appPath);
    if (source != FileSystemEntityType.directory) {
      final dest = p.join(staging.path, p.basename(appPath));
      File(appPath).copySync(dest);
      return dest;
    }

    final dest = Directory(p.join(staging.path, p.basename(appPath)))
      ..createSync(recursive: true);
    for (final entity in Directory(appPath).listSync(recursive: true)) {
      final relative = p.relative(entity.path, from: appPath);
      final target = p.join(dest.path, relative);
      if (entity is Directory) {
        Directory(target).createSync(recursive: true);
      } else if (entity is File) {
        Directory(p.dirname(target)).createSync(recursive: true);
        entity.copySync(target);
      }
    }
    return dest.path;
  }

  void _clearStaging() {
    final staged = _staged;
    _staged = null;
    if (staged != null && staged.existsSync()) {
      staged.deleteSync(recursive: true);
    }
  }

  @override
  Future<void> stop(AppInstance instance) async {
    if (!instance.process.kill()) {
      stderr.writeln(
          'Warning: Failed to kill Windows app process (pid ${instance.process.pid}).');
    }
    await instance.process.exitCode;
    await instance.logs.close();
    _clearStaging();
  }

  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    // GDI CopyFromScreen cannot capture D3D/Flutter surfaces.
    // Use DXGI Desktop Duplication via bundled dxcam py_binary.
    final resolved = resolveRunfileWithManifest(
        'rules_flutter/tools/windows_screenshot/screenshot');
    if (resolved == null) {
      throw StateError('Could not find bundled Windows screenshot tool. '
          'Build first: bazel build //tools/dev_tool:flutter_bazel');
    }
    final result = await Process.run(resolved.path, [
      outputPath
    ], environment: {
      ...Platform.environment,
      if (resolved.manifestPath != null)
        'RUNFILES_MANIFEST_FILE': resolved.manifestPath!,
    });
    if (result.exitCode != 0) {
      throw StateError('DXGI screenshot failed: ${result.stderr}');
    }
  }
}

/// Signature for running a process and returning its result (allows test injection).
typedef ProcessRunSync = Future<ProcessResult> Function(
    String executable, List<String> arguments);

/// Signature for starting a streaming process (allows test injection).
typedef ProcessStarter = Future<Process> Function(
    String executable, List<String> arguments);

/// Extract package name and launchable activity from an APK via aapt2.
///
/// [aapt2Path] names the binary to run; when omitted it is resolved through
/// [aapt2Tool], which throws a [MissingHostToolException] rather than handing
/// `Process.run` a bare `'aapt2'` and letting a misconfigured SDK surface as a
/// failure to launch.
Future<({String packageName, String? activityName})> extractPackageInfo(
  String apkPath, {
  ProcessRunSync? runProcess,
  String? aapt2Path,
}) async {
  final run = runProcess ?? Process.run;
  final aapt2 = aapt2Path ?? aapt2Tool().require();
  final result = await run(aapt2, ['dump', 'badging', apkPath]);
  if (result.exitCode != 0) {
    throw StateError('`$aapt2 dump badging $apkPath` failed '
        '(exit ${result.exitCode}): ${result.stderr}');
  }
  final output = result.stdout as String;
  final pkgMatch = RegExp(r"package: name='([^']+)'").firstMatch(output);
  if (pkgMatch == null) {
    throw StateError('Could not extract package name from APK');
  }
  final actMatch =
      RegExp(r"launchable-activity: name='([^']+)'").firstMatch(output);
  return (
    packageName: pkgMatch.group(1)!,
    activityName: actMatch?.group(1),
  );
}

/// Android device (via adb).
class AndroidDevice extends Device {
  final String? deviceId;
  String? _packageName;
  String? _activityName;
  final String abi;
  final String? _explicitAdbPath;
  final String? _explicitAapt2Path;
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  /// Whether the upcoming launch expects the app to host a Dart VM service
  /// (debug/JIT builds). Set by the run command before [launch]; enables the
  /// INTERNET-permission preflight, which release/profile launches skip.
  bool expectsVmService = false;

  AndroidDevice({
    this.deviceId,
    String? packageName,
    String? activityName,
    this.abi = 'arm64',
    String? adbPath,
    String? aapt2Path,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  })  : _packageName = packageName,
        _activityName = activityName,
        _explicitAdbPath = adbPath,
        _explicitAapt2Path = aapt2Path,
        _runProcess = runProcess ?? Process.run,
        _startProcess = startProcess ?? Process.start;

  /// The `adb` to run, resolved on first use.
  ///
  /// Lazy so that merely naming an Android serial on a machine with no SDK is
  /// not itself an error — [preflight] is where that gets reported, with the
  /// context that a run is about to need it.
  late final String adbPath = _explicitAdbPath ?? adbTool().require();

  /// The `aapt2` to run, resolved on first use. Only a launch that has to read
  /// the APK's manifest touches it.
  late final String aapt2Path = _explicitAapt2Path ?? aapt2Tool().require();

  @override
  Future<List<HostTool>> requiredHostTools() async => [
        if (_explicitAdbPath == null) adbTool(),
        // Needed only to read the package name and launchable activity out of
        // the APK, which a caller that already named them skips.
        if (_packageName == null && _explicitAapt2Path == null) aapt2Tool(),
      ];

  @override
  String get name => 'Android${deviceId != null ? ' ($deviceId)' : ''}';

  @override
  String pickArtifact(List<String> outputs) {
    // android_binary emits `<name>_deploy.jar`, `<name>_unsigned.apk`,
    // and `<name>.apk`. Only the signed `.apk` is installable; the
    // deploy jar comes first in the output list and would trip
    // `adb install` with `filename doesn't end .apk or .apex`.
    for (final f in outputs) {
      if (f.endsWith('.apk') && !f.endsWith('_unsigned.apk')) return f;
    }
    return outputs.first;
  }

  @override
  List<String> get buildArgs =>
      ['--platforms=@rules_flutter//flutter/platforms:android_$abi'];

  /// Build the common adb prefix args (includes -s <deviceId> if set).
  List<String> _adbArgs(List<String> args) {
    if (deviceId != null) return ['-s', deviceId!, ...args];
    return args;
  }

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    final packageName = _packageName ?? await _readPackageName(appPath);

    // Step 1: Install the APK.
    final installResult = await _runProcess(
      adbPath,
      _adbArgs(['install', '-r', appPath]),
    );
    if (installResult.exitCode != 0) {
      throw StateError('adb install failed: ${installResult.stderr}');
    }

    // Step 1a: Debug launches await the VM service, which can never come up
    // without android.permission.INTERNET — fail fast instead.
    if (expectsVmService) {
      await _verifyInternetPermission(packageName, appPath);
    }

    // Step 2: Start adb logcat — the app's log source as well as where the
    // VM-service announcement appears.
    //
    // Deliberately unfiltered at the adb level (`-v time`, no tag spec) with
    // filtering done in Dart by [androidLogFilter]. The previous
    // `flutter:I *:S` silenced everything but the `flutter` tag, which hid
    // Java exceptions (`AndroidRuntime`), VM messages (`DartVM`) and native
    // crashes — exactly the output you most need when an app misbehaves.
    // Matches flutter_tools' AdbLogReader, which filters host-side for the
    // same reason.
    final logcat = await _startProcess(
      adbPath,
      _adbArgs(['logcat', '-v', 'time', '-T', '1']),
    );
    // logcat has no stdout/stderr split: severity lives in the line's tag, so
    // [androidLogFilter] decides, and the raw stderr channel (adb's own
    // diagnostics) is not treated as app error output.
    final logs = _startProcessLogs(logcat, onLog,
        stderrIsError: false, transform: androidLogFilter);

    // Step 3: Launch the activity.
    final activity = _activityName ?? '.MainActivity';
    final startResult = await _runProcess(
      adbPath,
      _adbArgs(['shell', 'am', 'start', '-n', '$packageName/$activity']),
    );
    if (startResult.exitCode != 0) {
      throw StateError('adb am start failed: ${startResult.stderr}');
    }

    // Step 4: Discover VM service URI from logcat.
    Uri? vmServiceUri;
    final deviceUri = await discoverVmServiceUri(logs);

    // Port forwarding — the VM service URI from logcat is device-local.
    if (deviceUri != null) {
      final devicePort = deviceUri.port;
      try {
        final forwardResult = await _runProcess(
          adbPath,
          _adbArgs(['forward', 'tcp:0', 'tcp:$devicePort']),
        );
        if (forwardResult.exitCode == 0) {
          final hostPort = int.tryParse(
            (forwardResult.stdout as String).trim(),
          );
          if (hostPort != null) {
            vmServiceUri = deviceUri.replace(
              host: '127.0.0.1',
              port: hostPort,
            );
          } else {
            vmServiceUri = deviceUri;
          }
        } else {
          vmServiceUri = deviceUri;
        }
      } catch (_) {
        vmServiceUri = deviceUri;
      }
    }

    return AppInstance(
        process: logcat, vmServiceUri: vmServiceUri, logs: logs);
  }

  /// Read the package name (and launchable activity) out of the APK.
  ///
  /// Fatal when it fails, because the package name is what starts the activity
  /// and what [stop] force-stops: a launch without one installs an APK, runs
  /// nothing, and then waits out VM-service discovery on an app that was never
  /// started. That is what the previous warn-and-continue produced, and the
  /// discovery timeout it ended in named the wrong culprit.
  Future<String> _readPackageName(String appPath) async {
    if (!appPath.endsWith('.apk')) {
      throw StateError(
          'Cannot launch $appPath on $name: it is not an APK, so there is no '
          'manifest to read the package name from.');
    }
    final info = await extractPackageInfo(appPath,
        runProcess: _runProcess, aapt2Path: aapt2Path);
    _packageName = info.packageName;
    _activityName ??= info.activityName;
    return info.packageName;
  }

  /// Fails the launch when the installed [packageName] does not request
  /// `android.permission.INTERNET`.
  ///
  /// Android enforces the INTERNET permission at the kernel level (AID_INET
  /// group membership): a process without it cannot create any socket —
  /// including the 127.0.0.1 server socket the Dart VM service must bind —
  /// so a debug launch would only ever time out waiting for the service.
  /// Queries the installed package (not the APK on disk) so the check
  /// reflects exactly what the device enforces.
  Future<void> _verifyInternetPermission(
      String packageName, String apkPath) async {
    final result = await _runProcess(
      adbPath,
      _adbArgs(['shell', 'dumpsys', 'package', packageName]),
    );
    if (result.exitCode != 0) {
      throw StateError(
          'Could not verify INTERNET permission for $packageName: '
          '`adb shell dumpsys package` failed (exit ${result.exitCode}): '
          '${result.stderr}');
    }
    final output = result.stdout as String;
    if (!output.contains('Package [$packageName]')) {
      throw StateError(
          'Could not verify INTERNET permission for $packageName: '
          '`adb shell dumpsys package` returned no package record:\n'
          '${output.trim()}');
    }
    if (!_requestsInternetPermission(output)) {
      throw StateError(
          '$packageName ($apkPath) does not request '
          'android.permission.INTERNET, so the Dart VM service cannot bind '
          'its socket and this debug launch would hang.\n'
          'Debug APKs built with flutter_android_app get INTERNET from the '
          'debug variant manifest '
          '(android/app/src/debug/AndroidManifest.xml, merged into -c dbg '
          'builds): make sure that file exists (flutter create emits it) '
          'and was not disabled via debug_manifest = False. For a custom '
          'manifest, add <uses-permission '
          'android:name="android.permission.INTERNET"/> or pass a '
          'debug_manifest. Alternatively pass --allow-no-vm-service to '
          'launch without debugging.');
    }
  }

  /// True when the dumpsys package record lists
  /// `android.permission.INTERNET` under `requested permissions:`.
  /// A package that requests no permissions has no such section at all.
  static bool _requestsInternetPermission(String dumpsysOutput) {
    final lines = const LineSplitter().convert(dumpsysOutput);
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].trim() != 'requested permissions:') continue;
      final headerIndent = lines[i].length - lines[i].trimLeft().length;
      for (var j = i + 1; j < lines.length; j++) {
        final line = lines[j];
        if (line.trim().isEmpty) break;
        final indent = line.length - line.trimLeft().length;
        if (indent <= headerIndent) break;
        final permission = line.trim().split(RegExp(r'[:\s]')).first;
        if (permission == 'android.permission.INTERNET') return true;
      }
    }
    return false;
  }

  @override
  Future<void> stop(AppInstance instance) async {
    if (_packageName != null) {
      await _runProcess(
        adbPath,
        _adbArgs(['shell', 'am', 'force-stop', _packageName!]),
      );
    }
    if (!instance.process.kill()) {
      stderr.writeln(
          'Warning: Failed to kill Android logcat process (pid ${instance.process.pid}).');
    }
    await instance.process.exitCode;
    await instance.logs.close();
  }

  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (vmClient != null) {
      return vmClient.screenshot(outputPath);
    }
    const remotePath = '/sdcard/flutter_screenshot.png';
    final capResult = await _runProcess(
      adbPath,
      _adbArgs(['shell', 'screencap', '-p', remotePath]),
    );
    if (capResult.exitCode != 0) {
      throw StateError('adb screencap failed: ${capResult.stderr}');
    }
    final pullResult = await _runProcess(
      adbPath,
      _adbArgs(['pull', remotePath, outputPath]),
    );
    if (pullResult.exitCode != 0) {
      throw StateError('adb pull failed: ${pullResult.stderr}');
    }
    await _runProcess(adbPath, _adbArgs(['shell', 'rm', remotePath]));
  }
}

/// Wait until a local TCP listener on 127.0.0.1:[port] accepts connections.
///
/// Port forwarders (iproxy, adb forward) bind their local listener
/// asynchronously after `Process.start` returns; dialing the forward before
/// it is bound gets ECONNREFUSED. Polls `Socket.connect` with exponential
/// backoff and destroys each probe socket. Throws [StateError] naming [what]
/// if the listener never accepts within [budget].
Future<void> waitForLocalTcpPort(
  int port, {
  required String what,
  Duration budget = const Duration(seconds: 10),
}) async {
  final deadline = DateTime.now().add(budget);
  var delay = const Duration(milliseconds: 50);
  while (true) {
    try {
      final probe = await Socket.connect('127.0.0.1', port,
          timeout: const Duration(seconds: 1));
      probe.destroy();
      return;
    } catch (_) {
      if (DateTime.now().isAfter(deadline)) {
        throw StateError(
            '$what on 127.0.0.1:$port did not accept connections within '
            '${budget.inSeconds}s of starting.');
      }
      await Future<void>.delayed(delay);
      final doubled = delay * 2;
      delay = doubled > const Duration(milliseconds: 500)
          ? const Duration(milliseconds: 500)
          : doubled;
    }
  }
}

/// One parsed `adb logcat -v time` record.
///
/// The `-v time` format is
/// `MM-DD HH:MM:SS.mmm L/Tag( pid): message`, where the pid is space-padded to
/// a fixed width and the tag may itself contain dots (`System.err`).
class LogcatLine {
  /// Priority letter: V, D, I, W, E or F.
  final String level;
  final String tag;
  final String message;

  /// The record without its timestamp — what gets shown.
  final String display;

  const LogcatLine({
    required this.level,
    required this.tag,
    required this.message,
    required this.display,
  });
}

const _logcatTimestamp = r'^\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3}\s+';
final _logcatTimestampPrefix = RegExp(_logcatTimestamp);
final _logcatTimeFormat =
    RegExp('$_logcatTimestamp' r'([VDIWEF])/(.*?)\(\s*\d+\):\s?(.*)$');

/// Parse a `-v time` logcat record, or null if the line isn't one (banners,
/// continuation lines, partial reads).
///
/// Parsing once and matching on the parsed tag is deliberate: flutter_tools'
/// equivalent allowlist is a set of regexes written against a tag-only format
/// even though it requests `-v time`, so several of them — `AndroidRuntime`,
/// `System.err`, fatal `F/` — never match a real padded-pid line. Copying them
/// verbatim would have silently dropped exactly the crash output this is here
/// to surface.
LogcatLine? parseLogcatLine(String rawLine) {
  final match = _logcatTimeFormat.firstMatch(rawLine);
  if (match == null) return null;
  final level = match.group(1)!;
  final tag = match.group(2)!.trim();
  final message = match.group(3)!;
  return LogcatLine(
    level: level,
    tag: tag,
    message: message,
    display: rawLine.replaceFirst(_logcatTimestampPrefix, ''),
  );
}

/// Tags worth showing from an Android device.
///
/// `adb logcat` carries the whole device's logging, almost none of which
/// concerns the app under development, so this is an allowlist. The set is
/// flutter_tools' (`AdbLogReader._allowedTags`):
///
///   * `flutter*` — Dart `print`/`debugPrint` output.
///   * `DartVM*` — VM messages, including the VM-service announcement.
///   * `AndroidRuntime` — uncaught Java exceptions, i.e. crashes.
///   * `System.err` — Java stderr.
///   * `ActivityManager` — but only when it mentions the app.
///   * any tag at all when the record is fatal (`F`).
///
/// Not ported: flutter's tombstone state machine and repeated-line collapsing.
/// Those polish a crash report; the allowlist is what makes crashes *visible*,
/// which is the gap being closed here.
bool _isAndroidTagOfInterest(LogcatLine line) {
  final tag = line.tag.toLowerCase();
  if (line.level == 'F') return true;
  if (tag.startsWith('flutter')) return true;
  if (tag.startsWith('dartvm') && (line.level == 'I' || line.level == 'E')) {
    return true;
  }
  if (!const {'W', 'E', 'F'}.contains(line.level)) return false;
  if (tag == 'androidruntime' || tag == 'system.err') return true;
  if (tag == 'activitymanager') {
    return RegExp(r'\b(flutter|domokit|sky)\b').hasMatch(line.message);
  }
  return false;
}

/// Messages that pass the tag allowlist but are never actionable.
///
/// From flutter_tools' `AdbLogReader._filteredMessages`.
final _androidFilteredMessages = <RegExp>[
  RegExp(r'^Failed to find sync for id=\d+$'),
  RegExp(r'^updateAcquireFence: Did not find frame\.$'),
  RegExp(r'ViewPostIme pointer'),
  RegExp(r'mali\.instrumentation\.graph\.work'),
];

/// Decide whether a raw `adb logcat -v time` line is worth showing, returning
/// it with the timestamp stripped, or null to drop it.
///
/// Exposed for testing.
String? androidLogFilter(String rawLine) {
  final line = parseLogcatLine(rawLine);
  // Banners ("--------- beginning of main") and anything else that isn't a
  // record.
  if (line == null) return null;
  if (!_isAndroidTagOfInterest(line)) return null;
  if (_androidFilteredMessages.any((re) => re.hasMatch(line.message))) {
    return null;
  }
  return line.display;
}

/// Pattern matching Dart VM service URI announcements from Flutter apps.
/// Matches Flutter's own `kVMServiceMessageRegExp` from globals.dart.
final vmServiceUriPattern = RegExp(
  r'The Dart VM service is listening on ((http|//)[a-zA-Z0-9:/=_\-\.\[\]]+)',
);

/// How long a launch waits for the VM-service announcement before giving up.
const _vmServiceDiscoveryTimeout = Duration(seconds: 30);

/// Watch [logs] for the VM-service announcement.
///
/// The Flutter engine prints a line like:
///   "The Dart VM service is listening on http://127.0.0.1:XXXXX/..."
///
/// This is a pure *reader*: it owns only its own subscription to [logs] and
/// cancels only that, leaving whatever feeds the stream running for the app's
/// lifetime. An earlier version cancelled the app's stdout/stderr
/// subscriptions here, which killed all subsequent output and left the OS
/// pipes unread — see the library docs.
///
/// Returns null if nothing announced a VM service within
/// [_vmServiceDiscoveryTimeout] or the stream ended first.
Future<Uri?> discoverVmServiceUri(
  AppLogStream logs, {
  Duration timeout = _vmServiceDiscoveryTimeout,
}) async {
  final completer = Completer<Uri?>();
  final timer = Timer(timeout, () {
    if (!completer.isCompleted) completer.complete(null);
  });

  final sub = logs.lines.listen(
    (line) {
      if (completer.isCompleted) return;
      final match = vmServiceUriPattern.firstMatch(line.text);
      if (match != null) completer.complete(Uri.parse(match.group(1)!));
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete(null);
    },
  );

  try {
    return await completer.future;
  } finally {
    timer.cancel();
    await sub.cancel();
  }
}

/// Create the log stream for a launch, attach [onLog], and start draining
/// [process] into it as its only source.
///
/// [onLog] is wired before the pump starts so no line can slip past it.
///
/// For every platform but a physical iOS device the app has exactly one log
/// source, so the stream's life is that source's life — see
/// [IOSDevice.launch] for the one place that owns two.
AppLogStream _startProcessLogs(
  Process process,
  AppLogListener? onLog, {
  bool stderrIsError = true,
  String? Function(String line)? transform,
}) {
  final logs = _newAppLogs(onLog);
  final pump = pumpProcessLines(process, logs,
      stderrIsError: stderrIsError, transform: transform);
  logs.closeWhen([pump.done]);
  return logs;
}

/// An empty log stream with [onLog] already attached.
///
/// Wiring the sink before any pump starts is what guarantees no line can slip
/// past it — including output printed during startup, before `launch()` has
/// returned.
AppLogStream _newAppLogs(AppLogListener? onLog) {
  final logs = AppLogStream();
  if (onLog != null) logs.lines.listen(onLog);
  return logs;
}

/// Detect the appropriate device for the current platform.
Device detectDevice() {
  if (Platform.isMacOS) return MacOSDevice();
  if (Platform.isLinux) return LinuxDevice();
  if (Platform.isWindows) return WindowsDevice();
  throw UnsupportedError(
    'No device available for ${Platform.operatingSystem}. '
    'Desktop devices are supported on macOS, Linux, and Windows.',
  );
}

/// Resolve device IDs to [Device] instances.
///
/// If [ids] is empty, auto-detects one device for the current platform.
/// Accepted IDs: `macos`, `linux`, `windows`, `ios-simulator`,
/// `ios-simulator:<udid>`, `ios`, `ios:<udid>`, `chrome`, or an Android serial.
///
/// Unknown IDs are treated as Android serial numbers with a warning.
List<Device> resolveDevices(List<String> ids) {
  if (ids.isEmpty) return [detectDevice()];
  return ids.map(_resolveDevice).toList();
}

Device _resolveDevice(String id) {
  switch (id) {
    case 'macos':
      return MacOSDevice();
    case 'linux':
      return LinuxDevice();
    case 'windows':
      return WindowsDevice();
    case 'chrome':
      return WebDevice();
    case 'ios-simulator':
      return IOSSimulatorDevice.booted();
    case 'ios':
      return IOSDevice();
    default:
      if (id.startsWith('ios-simulator:')) {
        return IOSSimulatorDevice(udid: id.substring('ios-simulator:'.length));
      }
      if (id.startsWith('ios:')) {
        return IOSDevice(udid: id.substring('ios:'.length));
      }
      // Warn if it looks like a typo of a known device name.
      const knownIds = [
        'macos',
        'linux',
        'windows',
        'chrome',
        'ios-simulator',
        'ios',
      ];
      stderr.writeln(
        "Warning: Unknown device ID '$id', treating as Android serial number. "
        'Known device IDs: ${knownIds.join(', ')}.',
      );
      return AndroidDevice(deviceId: id);
  }
}

/// iOS Simulator device (via xcrun simctl).
class IOSSimulatorDevice extends Device {
  final String udid;
  final String? _bundleId;
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;

  IOSSimulatorDevice({
    required this.udid,
    String? bundleId,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  })  : _bundleId = bundleId,
        _runProcess = runProcess ?? Process.run,
        _startProcess = startProcess ?? Process.start;

  /// Create a device targeting the first booted simulator.
  factory IOSSimulatorDevice.booted({
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
  }) {
    final run = runProcess ?? Process.run;
    return _IOSSimulatorDeviceBooted(
      runProcess: run,
      startProcess: startProcess ?? Process.start,
    );
  }

  @override
  String get name => 'iOS Simulator ($udid)';

  @override
  List<String> get buildArgs => const ['--ios_multi_cpus=sim_arm64'];

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    // Extract .app from .ipa if needed — simctl install requires .app.
    String installPath = appPath;
    if (appPath.endsWith('.ipa')) {
      installPath = await _extractAppFromIpa(appPath);
    }

    // Boot sim (idempotent — no-op if already booted).
    await _runProcess('xcrun', ['simctl', 'boot', udid]);

    // Install.
    final installResult =
        await _runProcess('xcrun', ['simctl', 'install', udid, installPath]);
    if (installResult.exitCode != 0) {
      throw StateError('simctl install failed: ${installResult.stderr}');
    }

    // Two log streams, deliberately.
    //
    // Discovery matches on message content and nothing else. App output needs
    // a process-scoped predicate with several NOT(...) noise filters
    // ([iosSimulatorLogPredicate]). Folding the two together would make
    // VM-service discovery — which hot reload, screenshots and agent control
    // all depend on — contingent on those exclusion clauses continuing to
    // spare the announcement. Two narrow streams fail independently and
    // visibly; one broad stream fails silently.
    final discoveryLog = await _startProcess('xcrun', [
      'simctl',
      'spawn',
      udid,
      'log',
      'stream',
      '--predicate',
      'eventMessage contains "Observatory" or eventMessage contains "Dart VM service"',
    ]);

    final appName = p.basename(installPath).replaceAll('.app', '');
    final outputLog = await _startProcess('xcrun', [
      'simctl',
      'spawn',
      udid,
      'log',
      'stream',
      '--style',
      'json',
      '--predicate',
      iosSimulatorLogPredicate(appName),
    ]);

    // Unified logging carries no stdout/stderr split, so nothing is flagged as
    // an error channel here.
    final logs = _startProcessLogs(outputLog, onLog,
        stderrIsError: false, transform: parseUnifiedLoggingLine);

    // Launch app.
    final bundleId = _bundleId ?? await _extractBundleId(installPath);
    await _runProcess('xcrun', ['simctl', 'launch', udid, bundleId]);

    // Discover VM service URI from the dedicated discovery stream.
    final uri = await discoverVmServiceUriFromProcess(discoveryLog);

    return AppInstance(
      process: discoveryLog,
      vmServiceUri: uri,
      logs: logs,
      auxiliaryProcesses: [outputLog],
    );
  }

  @override
  Future<void> stop(AppInstance instance) async {
    if (_bundleId != null) {
      await _runProcess('xcrun', ['simctl', 'terminate', udid, _bundleId!]);
    }
    instance.process.kill();
    await instance.process.exitCode;
    await instance.disposeAuxiliaryProcesses();
    await instance.logs.close();
  }

  /// iOS renders with Impeller, which cannot encode a compressed screenshot,
  /// so `_flutter.screenshot` never succeeds here.
  @override
  bool get supportsFlutterScreenshot => false;

  /// iOS Simulator uses `simctl io screenshot` because `_flutter.screenshot`
  /// returns "Could not capture image screenshot" on the Simulator rendering
  /// pipeline. Waits for the first frame via VM service before capturing.
  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (vmClient != null) {
      await vmClient.waitForFirstFrame();
    }
    final result = await _runProcess(
        'xcrun', ['simctl', 'io', udid, 'screenshot', outputPath]);
    if (result.exitCode != 0) {
      throw StateError('simctl screenshot failed: ${result.stderr}');
    }
  }

  Future<String> _extractBundleId(String appPath) async {
    final result = await _runProcess('defaults', [
      'read',
      '$appPath/Info.plist',
      'CFBundleIdentifier',
    ]);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
    throw StateError('Could not extract bundle ID from $appPath');
  }

  /// Extract the .app directory from an .ipa archive.
  Future<String> _extractAppFromIpa(String ipaPath) async {
    final tempDir = await Directory.systemTemp.createTemp('flutter_ipa_');
    final result =
        await _runProcess('unzip', ['-oq', ipaPath, '-d', tempDir.path]);
    if (result.exitCode != 0) {
      throw StateError('Failed to extract IPA: ${result.stderr}');
    }
    final payloadDir = Directory(p.join(tempDir.path, 'Payload'));
    if (!payloadDir.existsSync()) {
      throw StateError('No Payload directory found in IPA');
    }
    final apps =
        payloadDir.listSync().where((e) => e.path.endsWith('.app')).toList();
    if (apps.isEmpty) {
      throw StateError('No .app found in IPA Payload directory');
    }
    return apps.first.path;
  }
}

/// An [IOSSimulatorDevice] that resolves the UDID on first launch.
class _IOSSimulatorDeviceBooted extends IOSSimulatorDevice {
  String? _resolvedUdid;

  _IOSSimulatorDeviceBooted({
    required ProcessRunSync runProcess,
    required ProcessStarter startProcess,
  }) : super(
          udid: 'booted',
          runProcess: runProcess,
          startProcess: startProcess,
        );

  @override
  String get name => _resolvedUdid != null
      ? 'iOS Simulator ($_resolvedUdid)'
      : 'iOS Simulator (booted)';

  Future<String> _resolveBootedUdid() async {
    if (_resolvedUdid != null) return _resolvedUdid!;
    final result = await _runProcess(
        'xcrun', ['simctl', 'list', 'devices', 'booted', '-j']);
    if (result.exitCode == 0) {
      final output = result.stdout as String;
      final match = RegExp(r'"udid"\s*:\s*"([^"]+)"').firstMatch(output);
      if (match != null) {
        _resolvedUdid = match.group(1)!;
        return _resolvedUdid!;
      }
    }
    throw StateError('No booted iOS simulator found. '
        'Boot one with: xcrun simctl boot <device-name>');
  }

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    final resolvedUdid = await _resolveBootedUdid();
    final real = IOSSimulatorDevice(
      udid: resolvedUdid,
      runProcess: _runProcess,
      startProcess: _startProcess,
    );
    return real.launch(appPath, onLog: onLog);
  }
}

/// How a paired physical device is currently reachable.
///
/// This decides two things that have to agree with each other: whether the app
/// is launched with its VM service bound to all interfaces, and whether that
/// service is dialed through a port forward or at the device's own address.
enum IOSDeviceTransport {
  /// Attached by cable. The VM service binds to the device's loopback — which
  /// is what `--vm-service-host` defaults to — so it is reached through an
  /// `iproxy` forward.
  wired,

  /// Reachable over the network. There is no cable to forward through, so the
  /// app must be launched with `--vm-service-host=0.0.0.0` and dialed at the
  /// device's own address.
  wireless,
}

/// What `devicectl list devices` reports about one paired physical device.
class IOSDeviceInfo {
  /// The hardware UDID.
  ///
  /// This is the identifier every tool here is addressed with. `devicectl`
  /// also answers to its own CoreDevice UUID ([coreDeviceId]) and reports that
  /// one first, but `lldb device select`, `iproxy -u` and the pymobiledevice3
  /// screenshot helper all go through usbmuxd, which has never heard of it —
  /// addressing them with it produces a port forward that binds locally and
  /// then resets every connection.
  final String udid;

  /// The CoreDevice UUID `devicectl` lists as `identifier`. Kept so that a
  /// UDID copied out of `devicectl list devices` still selects this device.
  final String coreDeviceId;

  final String name;
  final IOSDeviceTransport transport;

  /// The device's own mDNS hostnames, of the form
  /// `<device-name>.coredevice.local`.
  ///
  /// These are what tell this device's `_dartVmService._tcp` advertisement
  /// apart from every other advertiser on the network — including this Mac
  /// running the same bundle id in a simulator. See
  /// [MdnsVmServiceDiscovery.discover].
  final List<String> hostnames;

  IOSDeviceInfo({
    required this.udid,
    required this.coreDeviceId,
    required this.name,
    required this.transport,
    required this.hostnames,
  });

  /// Whether [identifier] names this device, in either identifier space.
  bool matches(String identifier) =>
      udid == identifier || coreDeviceId == identifier;

  @override
  String toString() => '$name ($udid, ${transport.name})';
}

/// The devices `devicectl list devices --json-output` reports as usable now.
///
/// Entries without a recognised `transportType` are dropped: a device that was
/// paired once but is not currently attached is still listed, with no
/// transport and `tunnelState: unavailable`. Picking one of those produces a
/// launch that installs nothing and then waits out every timeout, instead of
/// a "no device attached" error at the first step.
List<IOSDeviceInfo> parseDevicectlDevices(String jsonText) {
  final data = json.decode(jsonText) as Map<String, dynamic>;
  final devices = (data['result']?['devices'] as List?) ?? const [];
  final result = <IOSDeviceInfo>[];
  for (final entry in devices) {
    final device = entry as Map<String, dynamic>;
    final connection =
        (device['connectionProperties'] as Map?)?.cast<String, dynamic>() ??
            const {};
    final transport = switch (
        (connection['transportType'] as String?)?.toLowerCase()) {
      'wired' => IOSDeviceTransport.wired,
      'localnetwork' => IOSDeviceTransport.wireless,
      _ => null,
    };
    if (transport == null) continue;
    final coreDeviceId = device['identifier'] as String?;
    final udid = ((device['hardwareProperties'] as Map?)?['udid']) as String?;
    if (coreDeviceId == null || udid == null) continue;
    final properties =
        (device['deviceProperties'] as Map?)?.cast<String, dynamic>() ??
            const {};
    result.add(IOSDeviceInfo(
      udid: udid,
      coreDeviceId: coreDeviceId,
      name: properties['name'] as String? ?? udid,
      transport: transport,
      hostnames: ((connection['localHostnames'] as List?) ??
              (connection['potentialHostnames'] as List?) ??
              const [])
          .cast<String>(),
    ));
  }
  return result;
}

/// iOS physical device (via xcrun devicectl + lldb).
class IOSDevice extends Device {
  /// The UDID the user asked for, or null to use whichever device is attached.
  final String? requestedUdid;
  final String? _bundleId;
  final ProcessRunSync _runProcess;
  final ProcessStarter _startProcess;
  final MdnsVmServiceDiscovery _mdns;

  /// Filled in by the first [_resolveInfo].
  IOSDeviceInfo? _info;

  /// iproxy process for port forwarding (killed on stop).
  Process? _iproxyProcess;

  /// devicectl --console process for stdout capture (killed on stop).
  Process? _consoleLauncherProcess;

  /// lldb process for debugger attachment (killed on stop).
  Process? _lldbProcess;

  /// Installation URL from devicectl install (for PID matching).
  String? _installationUrl;

  IOSDevice({
    String? udid,
    String? bundleId,
    ProcessRunSync? runProcess,
    ProcessStarter? startProcess,
    MdnsVmServiceDiscovery? mdns,
  })  : requestedUdid = udid,
        _bundleId = bundleId,
        _runProcess = runProcess ?? Process.run,
        _startProcess = startProcess ?? Process.start,
        _mdns = mdns ?? MdnsVmServiceDiscovery();

  /// The UDID in play.
  ///
  /// The resolved hardware UDID wins over whatever was asked for: a user may
  /// legitimately pass the CoreDevice UUID (it is what `devicectl list
  /// devices` prints), but usbmuxd-backed tools cannot use it. Before a device
  /// is resolved there is nothing else to report, so the request stands in.
  String? get udid => _info?.udid ?? requestedUdid;

  /// The UDID of the device commands are addressed to.
  ///
  /// Throws rather than guessing: every caller runs after [launch] has
  /// resolved a device, or was handed an explicit UDID.
  String get _addressedUdid {
    final resolved = udid;
    if (resolved == null) {
      throw StateError('No iOS device has been resolved yet. This device was '
          'created without a UDID, so launch() must run first.');
    }
    return resolved;
  }

  @override
  String get name => 'iOS (${udid ?? 'auto-detect'})';

  @override
  List<String> get buildArgs => const ['--ios_multi_cpus=arm64'];

  /// Resolves the device as a side effect, which is the point: an unattached
  /// or ambiguous phone is a launch-blocking condition too, and finding out
  /// here costs one `devicectl list` instead of a whole build.
  @override
  Future<List<HostTool>> requiredHostTools() async {
    final info = await _resolveInfo();
    return [
      lldbTool(),
      // Only a cabled device is reached through a port forward; a wireless one
      // is dialed at its own address, so demanding iproxy there would refuse a
      // run that works. `xcrun` is not listed: it is part of macOS, and a
      // missing or misconfigured Xcode is already reported by [_resolveInfo],
      // with devicectl's own explanation attached.
      if (info.transport == IOSDeviceTransport.wired) iproxyTool(),
    ];
  }

  /// A hot restart re-runs `main()`, which re-JITs the app — and every new
  /// executable page traps into the `NOTIFY_DEBUGGER_ABOUT_RX_PAGES`
  /// breakpoint, whose handler writes to device memory over the debugserver
  /// link. That per-page round trip is what makes a cold start here take ~43s
  /// wired and ~400s wireless on a recent iPhone, where a desktop app takes
  /// under one second; a restart is the same work. (Setting `--auto-continue`
  /// on the breakpoint does not help: the cost is the memory write, not the
  /// stop/resume handshake.) The host default would abandon the RPC and
  /// force-close the connection while the device was still working.
  @override
  Duration get applyTimeout => switch (_info?.transport) {
        IOSDeviceTransport.wireless => const Duration(minutes: 15),
        _ => const Duration(minutes: 5),
      };

  /// Ask `devicectl` which device this is, once per run.
  ///
  /// Resolves the UDID when none was given, and in every case picks up the
  /// transport and mDNS hostnames the rest of [launch] needs. Ambiguity is an
  /// error, not a first-match: two attached devices means the user has to say
  /// which one, and silently choosing would look like a working run against
  /// the wrong phone.
  Future<IOSDeviceInfo> _resolveInfo() async {
    final cached = _info;
    if (cached != null) return cached;

    final dir = await Directory.systemTemp.createTemp('flutter_devicectl_');
    final jsonPath = p.join(dir.path, 'devices.json');
    final result = await _runProcess('xcrun',
        ['devicectl', 'list', 'devices', '--json-output', jsonPath]);
    if (result.exitCode != 0) {
      throw StateError('devicectl list devices failed: ${result.stderr}');
    }
    final jsonFile = File(jsonPath);
    if (!jsonFile.existsSync()) {
      throw StateError('devicectl list devices reported success but wrote no '
          'device list to $jsonPath.');
    }
    final available = parseDevicectlDevices(jsonFile.readAsStringSync());

    final requested = requestedUdid;
    if (requested != null) {
      final match = available.where((d) => d.matches(requested));
      if (match.isEmpty) {
        throw StateError('No attached iOS device with UDID $requested.'
            '${_availableSuffix(available)}');
      }
      return _info = match.first;
    }
    if (available.isEmpty) {
      throw StateError('No iOS device is attached. Connect one by cable, or '
          'pair it for network debugging in Xcode > Window > Devices and '
          'Simulators.');
    }
    if (available.length > 1) {
      throw StateError('More than one iOS device is attached; say which one '
          'with -d ios:<udid>.${_availableSuffix(available)}');
    }
    return _info = available.single;
  }

  static String _availableSuffix(List<IOSDeviceInfo> available) =>
      available.isEmpty
          ? ''
          : '\nAttached devices:\n'
              '${available.map((d) => '  ${d.udid}  ${d.name} (${d.transport.name})').join('\n')}';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    final info = await _resolveInfo();

    // Extract .app from .ipa if needed — devicectl install requires .app.
    String installPath = appPath;
    if (appPath.endsWith('.ipa')) {
      installPath = await _extractAppFromIpa(appPath);
    }

    // Install with JSON output to capture installationURL.
    final installJsonDir =
        await Directory.systemTemp.createTemp('flutter_install_');
    final installJsonPath = p.join(installJsonDir.path, 'install.json');

    final installResult = await _runProcess('xcrun', [
      'devicectl',
      'device',
      'install',
      'app',
      '--device',
      info.udid,
      '--json-output',
      installJsonPath,
      installPath,
    ]);
    if (installResult.exitCode != 0) {
      throw StateError('devicectl install failed: ${installResult.stderr}');
    }

    // Capture installationURL for PID matching.
    final installJsonFile = File(installJsonPath);
    if (installJsonFile.existsSync()) {
      try {
        final jsonData = json.decode(installJsonFile.readAsStringSync())
            as Map<String, dynamic>;
        final apps = jsonData['result']?['installedApplications'] as List?;
        if (apps != null && apps.isNotEmpty) {
          _installationUrl = (apps[0] as Map)['installationURL'] as String?;
        }
      } catch (_) {}
    }

    // Extract bundle ID from .app/Info.plist if not provided.
    final bundleId = _bundleId ?? await _extractBundleId(installPath);

    // iOS debug apps require a debugger (ptrace) to be attached before the
    // Flutter engine will start. This matches what `flutter run` does:
    //   1. Launch paused via devicectl --console --start-stopped
    //   2. Get PID from process list
    //   3. Attach lldb (which starts debugserver / ptrace)
    //   4. Set JIT page notification breakpoint
    //   5. Resume
    //   6. Discover the VM service by its mDNS advertisement

    final logs = _newAppLogs(onLog);

    // Step 1: Launch paused with --console to capture the app's output.
    //
    // flutter_tools wraps this in `script -t 0 /dev/null` "to convince
    // devicectl it has a terminal attached in order to redirect stdout"
    // (`ios/core_devices.dart`). That is unnecessary here: devicectl writes
    // the app's console output to these pipes without a pty.
    _consoleLauncherProcess = await _startProcess('xcrun', [
      'devicectl',
      'device',
      'process',
      'launch',
      '--device',
      info.udid,
      '--start-stopped',
      '--console',
      '--environment-variables',
      '{"OS_ACTIVITY_DT_MODE": "enable"}',
      bundleId,
      '--enable-dart-profiling',
      '--enable-checked-mode',
      // A wireless device is dialed at its own address, so the VM service must
      // not bind to the device's loopback the way it does by default. Matches
      // flutter_tools' `DebuggingOptions.buildLaunchArguments`, which adds this
      // exactly when the connection interface is wireless.
      if (info.transport == IOSDeviceTransport.wireless)
        '--vm-service-host=0.0.0.0',
    ]);

    // devicectl sends its own progress banners on one channel and the app's
    // console output on the other, so both feed the app log stream.
    //
    // stderr is deliberately *not* flagged as an error channel: devicectl
    // routes the app's ordinary console output there, so treating that channel
    // as errors would mark every `print()` as one.
    final consolePump = pumpProcessLines(_consoleLauncherProcess!, logs,
        stderrIsError: false);

    final launchCompleter = Completer<void>();
    // Cancelled below once the launch resolves. An uncancelled 30s timer keeps
    // the isolate alive for its full duration after the work is done — which
    // is how it surfaced: a test binary that finished in 2s took 31s to exit.
    final launchTimeout = Timer(const Duration(seconds: 30), () {
      if (!launchCompleter.isCompleted) launchCompleter.complete();
    });

    // devicectl's own launch banners are progress reporting, not app output.
    bool isDevicectlBanner(String line) =>
        line.contains('Waiting for the application to terminate') ||
        line.contains('Launched application with');

    // Another reader of the same stream, like discovery below.
    final bannerSub = logs.lines.listen((line) {
      if (!launchCompleter.isCompleted && isDevicectlBanner(line.text)) {
        launchCompleter.complete();
      }
    });
    // A launch that dies before ever printing a banner stops the wait
    // immediately rather than sitting out the timeout. This watches devicectl
    // itself rather than the shared log stream, which outlives it.
    unawaited(consolePump.done.then((_) {
      if (!launchCompleter.isCompleted) launchCompleter.complete();
    }));

    await launchCompleter.future;
    launchTimeout.cancel();
    await bannerSub.cancel();

    // Step 2: Get PID from running process list.
    final processId = await _findAppProcessId(bundleId);
    if (processId == null) {
      throw StateError('Could not find process ID for $bundleId');
    }

    // Step 3-5: Attach lldb debugger, set breakpoint, resume.
    // Matches flutter_tools LLDB._selectDevice, _setBreakpoint,
    // _attachToAppProcess, _resumeProcess.
    final lldb = await _startProcess('lldb', []);
    _lldbProcess = lldb;
    // lldb is a log source, not just a control channel — see [_startLldbOutput].
    final lldbDone = _startLldbOutput(lldb, appLogs: logs);

    // Both sources are now known, so the stream's life can be settled in one
    // place. They are not ordered — devicectl exits when the app terminates,
    // which is exactly when lldb starts reporting why — so the stream outlives
    // whichever ends first.
    logs.closeWhen([consolePump.done, lldbDone]);
    await _lldbCommand(lldb, 'device select ${info.udid}');
    final bpOutput = await _lldbCommand(
        lldb, r"breakpoint set --func-regex '^NOTIFY_DEBUGGER_ABOUT_RX_PAGES$'",
        waitFor: RegExp(r'Breakpoint (\d+):'), returnMatch: true);
    final bpId =
        RegExp(r'Breakpoint (\d+):').firstMatch(bpOutput ?? '')?.group(1) ??
            '1';
    await _lldbWriteln(
        lldb, 'breakpoint command add --script-type python $bpId');
    await _lldbWriteln(lldb, _jitBreakpointScript);
    await _lldbWriteln(lldb, 'DONE');
    await _lldbCommand(lldb, 'device process attach --pid $processId',
        waitFor: RegExp(r'Process \d+ stopped'));
    await _lldbCommand(lldb, 'process continue',
        waitFor: RegExp(r'Process \d+ resuming'));

    // Step 6: Find the VM service by its mDNS advertisement.
    //
    // Not by reading the log stream, the way every other platform does. A
    // wirelessly attached device has no console channel at all, and the one a
    // wired device has is `devicectl --console`, which dies with the launch it
    // reports on. The advertisement is the one channel both connections share,
    // and it is already provisioned: the debug/profile Info.plist declares
    // `_dartVmService._tcp` under NSBonjourServices
    // (`flutter/private/runners/ios/DartVmServiceMdns.plist`).
    //
    // Minutes, not seconds — see [applyTimeout] for why a debug launch here is
    // this slow. The budget is a backstop for a run that will never succeed,
    // not an estimate; [onSlow] is what tells the user a long wait is expected
    // rather than a hang. flutter_tools splits the same two concerns, warning
    // at 60s/75s while its mDNS query runs for ten minutes
    // (`ios/devices.dart`).
    final record = await _mdns.discover(
      bundleId: bundleId,
      hostnames: info.hostnames,
      resolveAddress: info.transport == IOSDeviceTransport.wireless,
      timeout: switch (info.transport) {
        IOSDeviceTransport.wired => const Duration(minutes: 5),
        IOSDeviceTransport.wireless => const Duration(minutes: 15),
      },
      slowAfter: const Duration(seconds: 45),
      onSlow: (elapsed) => logs.add(
          'Still waiting for the Dart VM service (${elapsed.inSeconds}s). '
          'Starting a debug build on an iOS device is slow — the JIT traps to '
          'the debugger for every executable page it allocates, which takes '
          'about 45s over a cable and several minutes over the network.'),
    );

    final Uri vmServiceUri;
    switch (info.transport) {
      case IOSDeviceTransport.wired:
        // The advertised port is a device-side port on the device's loopback.
        final iproxy = await _startProcess(
            'iproxy', ['${record.port}:${record.port}', '-u', info.udid]);
        _iproxyProcess = iproxy;

        // iproxy runs for the whole session and reports what it is doing on
        // both channels, so both have to be drained — an unread pipe blocks
        // the writer, and here the writer is the only route to the device.
        final iproxyOutput = AppLogStream();
        iproxyOutput.closeWhen([pumpProcessLines(iproxy, iproxyOutput).done]);

        // Process.start returns at spawn time, before iproxy has bound its
        // local listener. DDS dials this forward immediately after launch()
        // returns; an unbound listener means ECONNREFUSED and the session
        // loses its VM service. Return only once the forward actually accepts.
        try {
          await waitForLocalTcpPort(record.port,
              what: 'iproxy forward for the iOS VM service');
        } on StateError catch (e) {
          final said = iproxyOutput
              .read(0)
              .lines
              .map((l) => l.text)
              .where((t) => t.trim().isNotEmpty);
          throw StateError('${e.message}\n'
              'iproxy said: ${said.isEmpty ? '(nothing)' : said.join('; ')}');
        }
        vmServiceUri =
            record.uriFor(host: '127.0.0.1', port: record.port);
      case IOSDeviceTransport.wireless:
        // No cable to forward through. `discover(resolveAddress: true)` throws
        // rather than returning a record without an address, so this is set.
        vmServiceUri =
            record.uriFor(host: record.address!.address, port: record.port);
    }

    return AppInstance(
        process: lldb, vmServiceUri: vmServiceUri, logs: logs);
  }

  /// Python script for the JIT page notification breakpoint.
  /// Matches flutter_tools' LLDB._pythonScript.
  static const _jitBreakpointScript = '''
"""Intercept NOTIFY_DEBUGGER_ABOUT_RX_PAGES and touch the pages."""
base = frame.register["x0"].GetValueAsAddress()
page_len = frame.register["x1"].GetValueAsUnsigned()
data = bytearray(page_len)
data[0:8] = b'IHELPED!'
error = lldb.SBError()
frame.GetThread().GetProcess().WriteMemory(base, data, error)
if not error.Success():
    print(f'Failed to write into {base}[+{page_len}]', error)
    return
return False
''';

  /// Every line lldb has written, live and replayable.
  ///
  /// lldb outlives `launch()` — it holds the debugserver that keeps the app's
  /// JIT alive — so **something must keep reading its pipes for as long as it
  /// runs**. It is also chatty: it forwards the app's own logs and any crash
  /// report. Left unread, its stdout pipe fills, lldb blocks on write, and a
  /// blocked lldb never services the process it is controlling — the app hangs
  /// on device and only springs to life when the dev tool is killed and the
  /// pipes are closed.
  ///
  /// Backing this with an [AppLogStream] rather than an ad-hoc broadcast
  /// stream fixes a second bug in the same place: a broadcast stream drops
  /// events while nobody is listening, so any lldb output arriving between two
  /// commands — including the pattern the *next* command is about to wait for
  /// — was silently discarded. Replay makes the wait race-free.
  ///
  /// Mirrors flutter_tools' `LLDBLogForwarder`, which exists for these reasons.
  AppLogStream? _lldbOutput;

  /// Start draining [lldb] into [_lldbOutput]. Both channels are captured:
  /// lldb reports real failures (a breakpoint that resolved nowhere, a refused
  /// attach) on stderr, and dropping that channel turns an explainable failure
  /// into a 30-second timeout with no reason attached.
  ///
  /// [appLogs], when given, additionally receives everything lldb prints that
  /// is not lldb's own command chatter. Current flutter_tools treats
  /// `devicectl` **and lldb** as one combined log source on CoreDevices under
  /// Xcode 26+ (`ios/devices.dart` `logSources` → `devicectlAndLldb`), because
  /// the debugger carries output the console stream may not.
  ///
  /// Returns when lldb has finished feeding [appLogs] — the caller pairs it
  /// with the console channel's to settle when the shared stream closes.
  Future<void> _startLldbOutput(Process lldb, {AppLogStream? appLogs}) {
    final out = AppLogStream();
    _lldbOutput = out;
    final pump = pumpProcessLines(lldb, out, stderrIsError: true);
    out.closeWhen([pump.done]);

    if (appLogs == null) return pump.done;

    // Completed from the bridge's own `onDone`, not from [pump], so the last
    // lines lldb wrote are in [appLogs] before it is reported finished.
    final forwarded = Completer<void>();
    out.lines.listen(
      (line) {
        if (_isLldbCommandEcho(line.text)) return;
        appLogs.add(_stripDeviceLogPrefix(line.text), isError: line.isError);
      },
      onDone: forwarded.complete,
    );
    return forwarded.future;
  }

  /// lldb's own prompt/echo and disassembly, as opposed to app output.
  ///
  /// Only unambiguous markers are filtered; anything unrecognised is treated as
  /// app output, since losing a real line is worse than showing a noisy one.
  static bool _isLldbCommandEcho(String line) {
    final t = line.trim();
    if (t.isEmpty) return true;
    if (t.startsWith('(lldb)') ||
        t.startsWith('Breakpoint ') ||
        t.startsWith('Target ') ||
        t == 'DONE' ||
        t.startsWith('Available devices:') ||
        t.startsWith('Enter your Python command')) {
      return true;
    }
    if (t.startsWith('Process ') &&
        (t.contains(' stopped') ||
            t.contains(' resuming') ||
            t.contains(' exited') ||
            t.contains(' launched'))) {
      return true;
    }
    // Disassembly and frame dumps from a breakpoint stop.
    return t.startsWith('* thread #') ||
        t.startsWith('frame #') ||
        t.startsWith('->') ||
        RegExp(r'^0x[0-9a-f]+ <\+\d+>:').hasMatch(t) ||
        RegExp(r'^\d+ location(s)? added to breakpoint').hasMatch(t);
  }

  /// Native/engine logs arrive prefixed with a timestamp and process metadata:
  ///
  ///     2020-09-15 19:15:10.931434-0700 Runner[541:226276] Did finish launching.
  ///
  /// Dart `print()` output has no such prefix. Strip it so both read alike —
  /// same handling as flutter_tools' `_debuggerLineHandler`.
  static final _deviceLogPrefix = RegExp(r'^\S* \S* \S*\[[0-9:]*\] (.*)');

  static String _stripDeviceLogPrefix(String line) =>
      _deviceLogPrefix.firstMatch(line)?.group(1) ?? line;

  /// Send a command to lldb stdin and optionally wait for expected output.
  /// If [returnMatch] is true, returns the matched line; otherwise returns null.
  Future<String?> _lldbCommand(Process lldb, String command,
      {RegExp? waitFor, bool returnMatch = false}) async {
    final output = _lldbOutput;
    if (output == null) {
      throw StateError('lldb output is not being drained; '
          'call _startLldbOutput before issuing commands.');
    }

    if (waitFor == null) {
      // Fire-and-forget commands (`device select`, the breakpoint script
      // lines) produce no distinctive output to wait on. Yield rather than
      // sleeping a fixed interval: the following command's own wait is what
      // actually orders this sequence, and lldb reads its stdin in order.
      lldb.stdin.writeln(command);
      await Future<void>.delayed(Duration.zero);
      return null;
    }

    // Subscribe before writing so a fast reply cannot land first — and because
    // the stream replays, output already buffered still counts.
    final completer = Completer<String>();
    final sub = output.lines.listen((line) {
      if (!completer.isCompleted && waitFor.hasMatch(line.text)) {
        completer.complete(line.text);
      }
    });

    try {
      lldb.stdin.writeln(command);
      final matched = await completer.future.timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw StateError(
          'lldb did not answer "$command" within 30s (waiting for '
          '${waitFor.pattern}).\nlldb said:\n'
          '${output.read(-40).lines.map((l) => '  ${l.text}').join('\n')}',
        ),
      );
      return returnMatch ? matched : null;
    } finally {
      await sub.cancel();
    }
  }

  /// Write a line to lldb stdin without waiting for output.
  Future<void> _lldbWriteln(Process lldb, String text) async {
    lldb.stdin.writeln(text);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  /// Find the process ID of a running app by bundle ID.
  ///
  /// Uses `devicectl device info processes --json-output` and matches the
  /// process executable against the installationURL (from install step)
  /// or bundle ID.
  Future<int?> _findAppProcessId(String bundleId) async {
    final jsonDir = await Directory.systemTemp.createTemp('flutter_proc_');
    final jsonPath = p.join(jsonDir.path, 'processes.json');

    final result = await _runProcess('xcrun', [
      'devicectl',
      'device',
      'info',
      'processes',
      '--device',
      _addressedUdid,
      '--json-output',
      jsonPath,
    ]);
    if (result.exitCode != 0) return null;

    final jsonFile = File(jsonPath);
    if (!jsonFile.existsSync()) return null;

    try {
      final data =
          json.decode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
      final processes = (data['result']?['runningProcesses'] as List?) ?? [];

      for (final proc in processes) {
        final executable = (proc as Map)['executable'] as String? ?? '';
        final pid = proc['processIdentifier'] as int?;
        if (pid == null) continue;

        if (_installationUrl != null &&
            executable.contains(_installationUrl!)) {
          return pid;
        }
        if (executable.contains(bundleId)) {
          return pid;
        }
      }
    } catch (_) {}

    return null;
  }

  @override
  Future<void> stop(AppInstance instance) async {
    _iproxyProcess?.kill();
    if (_iproxyProcess != null) {
      await _iproxyProcess!.exitCode;
      _iproxyProcess = null;
    }
    _consoleLauncherProcess?.kill();
    if (_consoleLauncherProcess != null) {
      await _consoleLauncherProcess!.exitCode;
      _consoleLauncherProcess = null;
    }
    // Killing lldb terminates the debugserver, which kills the app.
    _lldbProcess?.kill();
    if (_lldbProcess != null) {
      await _lldbProcess!.exitCode;
      _lldbProcess = null;
    }
    await _lldbOutput?.close();
    _lldbOutput = null;
    instance.process.kill();
    await instance.process.exitCode;
    await instance.logs.close();
  }

  /// Impeller is always the renderer on iOS, and it cannot encode a
  /// compressed screenshot, so `_flutter.screenshot` never succeeds here.
  @override
  bool get supportsFlutterScreenshot => false;

  /// iOS physical device screenshot via pymobiledevice3 DVT service.
  ///
  /// `_flutter.screenshot` does not work on iOS because the Impeller renderer
  /// (always enabled on iOS) does not implement compressed image capture.
  /// Instead, we use pymobiledevice3's DVT screenshot, which captures via
  /// Apple's Developer Tools service (same mechanism as Xcode).
  ///
  /// The screenshot binary is bundled as a Bazel py_binary and resolved from
  /// runfiles. Requires building via `bazel build //tools/dev_tool:flutter_bazel`.
  ///
  /// Prerequisites:
  ///   sudo flutter_bazel ios-tunnel  # in a separate terminal
  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (vmClient != null) {
      await vmClient.waitForFirstFrame();
    }

    final resolved = resolveRunfileWithManifest(
        'rules_flutter/tools/ios_screenshot/screenshot');
    if (resolved == null) {
      throw StateError(
          'iOS device screenshot requires the bundled screenshot tool.\n'
          'Build via: bazel build //tools/dev_tool:flutter_bazel');
    }

    // The py_binary needs RUNFILES_MANIFEST_FILE to find its venv and
    // bootstrap scripts within the dart_binary's runfiles.
    final result = await Process.run(resolved.path, [
      outputPath,
      '--udid',
      _addressedUdid,
    ], environment: {
      if (resolved.manifestPath != null)
        'RUNFILES_MANIFEST_FILE': resolved.manifestPath!,
    });
    if (result.exitCode != 0) {
      final err = result.stderr as String;
      if (err.contains('Unable to connect to Tunneld') ||
          err.contains('no devices found')) {
        throw StateError(
            'iOS device screenshot requires a running tunnel daemon.\n'
            'Start in a separate terminal:\n'
            '  sudo flutter_bazel ios-tunnel');
      }
      throw StateError('iOS screenshot failed: $err');
    }
  }

  Future<String> _extractBundleId(String appPath) async {
    final result = await _runProcess('defaults', [
      'read',
      '$appPath/Info.plist',
      'CFBundleIdentifier',
    ]);
    if (result.exitCode == 0) {
      return (result.stdout as String).trim();
    }
    throw StateError('Could not extract bundle ID from $appPath');
  }

  /// Extract the .app directory from an .ipa archive.
  Future<String> _extractAppFromIpa(String ipaPath) async {
    final tempDir = await Directory.systemTemp.createTemp('flutter_ipa_');
    final result =
        await _runProcess('unzip', ['-oq', ipaPath, '-d', tempDir.path]);
    if (result.exitCode != 0) {
      throw StateError('Failed to extract IPA: ${result.stderr}');
    }
    final payloadDir = Directory(p.join(tempDir.path, 'Payload'));
    if (!payloadDir.existsSync()) {
      throw StateError('No Payload directory found in IPA');
    }
    final apps =
        payloadDir.listSync().where((e) => e.path.endsWith('.app')).toList();
    if (apps.isEmpty) {
      throw StateError('No .app found in IPA Payload directory');
    }
    return apps.first.path;
  }
}

/// NSPredicate selecting an app's own log output on the iOS Simulator.
///
/// Ported from flutter_tools' `launchDeviceUnifiedLogging`
/// (`ios/simulators.dart`). Scoped to the app's process, then narrowed to
/// messages from the Flutter engine, the Swift runtime, or the app image
/// itself, then stripped of known-irrelevant noise.
///
/// This is *only* an app-output predicate. VM-service discovery uses its own
/// stream with a content match — see [IOSSimulatorDevice.launch] for why the
/// two are not merged.
String iosSimulatorLogPredicate(String appName) {
  String orP(List<String> clauses) => '(${clauses.join(" OR ")})';
  String andP(List<String> clauses) => clauses.join(' AND ');
  String notP(String clause) => 'NOT($clause)';

  return andP(<String>[
    'eventType = logEvent',
    'processImagePath ENDSWITH "$appName"',
    // From Flutter, from Swift (assertions/fatal errors), or from the app.
    orP(<String>[
      'senderImagePath ENDSWITH "/Flutter"',
      'senderImagePath ENDSWITH "/libswiftCore.dylib"',
      'processImageUUID == senderImageUUID',
    ]),
    notP(
        'eventMessage CONTAINS ": could not find icon for representation -> com.apple."'),
    notP('eventMessage BEGINSWITH "assertion failed: "'),
    notP('eventMessage CONTAINS " libxpc.dylib "'),
  ]);
}

/// `"eventMessage" : "flutter: 21",` — one field of `log stream --style json`.
final _unifiedLoggingEventMessage = RegExp(r'.*"eventMessage" : (".*")');

/// Extract the message from a `log stream --style json` output line, or null
/// if the line carries no message (the format is pretty-printed across many
/// lines, most of which are other fields).
///
/// The predicate does the filtering, so every message that reaches here is
/// meant to be shown. Mirrors flutter_tools'
/// `_IOSSimulatorLogReader._onUnifiedLoggingLine`.
String? parseUnifiedLoggingLine(String line) {
  final match = _unifiedLoggingEventMessage.firstMatch(line);
  if (match == null) return null;
  try {
    final decoded = json.decode(match.group(1)!);
    return decoded is String ? decoded : null;
  } on FormatException {
    return null;
  }
}

/// Watch a log-emitting helper process for the VM-service announcement.
///
/// For sources where the helper process exists *only* to find the URI (the iOS
/// Simulator's discovery stream); app output comes from a separate stream. Like
/// [discoverVmServiceUri], this owns only its own subscription.
Future<Uri?> discoverVmServiceUriFromProcess(
  Process log, {
  Duration timeout = _vmServiceDiscoveryTimeout,
}) async {
  final logs = AppLogStream();
  final pump = pumpProcessLines(log, logs);
  // The helper is this stream's only source, so a helper that dies takes the
  // stream with it and discovery gives up at once instead of waiting out its
  // timeout on a process that will never say anything again.
  logs.closeWhen([pump.done]);
  try {
    return await discoverVmServiceUri(logs, timeout: timeout);
  } finally {
    await pump.dispose();
    await logs.close();
  }
}

/// Chrome launch flags matching Flutter's defaults for web dev mode.
///
/// These ensure predictable behavior during development:
/// - No extensions/popups that could interfere with the app
/// - Background timer throttling disabled for accurate async behavior
/// - No first-run/default-browser prompts
const chromeDebugFlags = [
  '--disable-extensions',
  '--disable-popup-blocking',
  '--bwsi',
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-default-apps',
  '--disable-translate',
  '--disable-search-engine-choice-screen',
  '--disable-background-timer-throttling',
];

/// Web device — serves build output via HTTP and launches Chrome.
class WebDevice extends Device {
  final ProcessStarter _startProcess;

  /// CDP debugging port discovered from Chrome stderr.
  int? _cdpPort;

  /// The localhost URL serving the app (used to find the correct CDP tab).
  String? _appUrl;

  /// Module server for DDC dev mode. Set by RunCommand before launch.
  WebModuleServer? _moduleServer;

  /// Chrome's own process output — browser diagnostics, not app output.
  ///
  /// Kept drained for the browser's lifetime so its pipes can never fill, and
  /// used to discover the CDP port. Deliberately *not* surfaced as app output:
  /// the app's console lives inside the page, and Chrome's own chatter would
  /// bury it.
  AppLogStream? _browserDiagnostics;

  /// Forwards the page's console when there is no DWDS to do it (WASM and
  /// production JS builds). Null in DDC dev mode, where `run_command` wires
  /// the DWDS VM service instead — see the one-source-per-platform note in the
  /// library docs.
  CdpConsoleClient? _consoleClient;

  WebDevice({ProcessStarter? startProcess})
      : _startProcess = startProcess ?? Process.start;

  @override
  String get name => 'Chrome';

  @override
  Future<List<HostTool>> requiredHostTools() async => [chromeTool()];

  /// Set the DDC module server for dev mode (hot restart support).
  void setModuleServer(WebModuleServer server) => _moduleServer = server;

  /// The CDP debugging port, if discovered.
  int? get cdpPort => _cdpPort;

  /// The localhost URL serving the app, if launched.
  String? get appUrl => _appUrl;

  @override
  CompilerConfig? createCompilerConfig(
    ToolchainPaths toolchain, {
    WebToolchainPaths? webToolchain,
    List<String> fileSystemRoots = const [],
    String fileSystemScheme = '',
    List<String> dartDefines = const [],
    String dartPluginRegistrantUri = '',
  }) {
    // Web builds its own filesystem roots (synthetic entrypoint dir + workspace)
    // in run_command; the native roots/scheme args are not used here. The
    // registrant URI is ignored too — the web synthetic main calls
    // registerPlugins() directly and re-runs on page-reload restart.
    if (webToolchain == null) return null;
    return WebCompilerConfig(webToolchain: webToolchain, dartDefines: dartDefines);
  }

  @override
  ReloadStrategy? createReloadStrategy() {
    if (_moduleServer == null) return null;
    // Prefer DWDS-based reload for DDC mode (state-preserving hot reload).
    if (_moduleServer!.connectedApps != null) {
      return DwdsReloadStrategy(moduleServer: _moduleServer!);
    }
    // Fall back to CDP page reload (WASM mode or when DWDS is unavailable).
    if (_cdpPort == null) return null;
    return CdpReloadStrategy(cdpPort: _cdpPort!, appUrl: _appUrl);
  }

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) async {
    if (_moduleServer != null) {
      return _launchWithModuleServer(onLog);
    }
    return _launchStaticServer(appPath, onLog);
  }

  /// Launch using DDC module server (dev mode with hot restart).
  Future<AppInstance> _launchWithModuleServer(AppLogListener? onLog) async {
    final url = _moduleServer!.uri.toString();
    _appUrl = url;

    final chromePath = findChrome();
    if (chromePath == null) {
      throw StateError(
          'Chrome not found. Install Chrome or use -d macos for desktop.');
    }
    final userDataDir =
        await Directory.systemTemp.createTemp('flutter_chrome_');
    final chrome = await _startProcess(chromePath, [
      '--remote-debugging-port=0',
      ...chromeDebugFlags,
      '--user-data-dir=${userDataDir.path}',
      url,
    ]);

    final logs = _startChromeLogs(chrome, onLog);
    _cdpPort = await _discoverCdpPort(_browserDiagnostics!);
    // No CDP console client here: DDC mode gets the app's output from the DWDS
    // VM service, and running both would print every line twice.
    return AppInstance(process: chrome, vmServiceUri: null, logs: logs);
  }

  /// Launch using static file server (production/WASM mode).
  Future<AppInstance> _launchStaticServer(
      String appPath, AppLogListener? onLog) async {
    final server = await HttpServer.bind('localhost', 0);
    final port = server.port;
    final url = 'http://localhost:$port';

    _serveDirectory(server, appPath);

    final chromePath = findChrome();
    if (chromePath == null) {
      await server.close();
      throw StateError(
          'Chrome not found. Install Chrome or use -d macos for desktop.');
    }
    final userDataDir =
        await Directory.systemTemp.createTemp('flutter_chrome_');
    _appUrl = url;
    final chrome = await _startProcess(chromePath, [
      '--remote-debugging-port=0',
      ...chromeDebugFlags,
      '--user-data-dir=${userDataDir.path}',
      url,
    ]);

    final logs = _startChromeLogs(chrome, onLog);
    _cdpPort = await _discoverCdpPort(_browserDiagnostics!);

    // No DWDS on this path (WASM / production JS), so CDP is the only source
    // of the app's console output.
    if (_cdpPort != null) {
      _consoleClient = CdpConsoleClient(
        cdpPort: _cdpPort!,
        appUrl: _appUrl,
        logs: logs,
      );
      try {
        await _consoleClient!.start();
      } catch (e) {
        // Console forwarding is not worth failing a launch over, but a silent
        // loss of all app output would be worse than the noise.
        stderr.writeln(
            'Warning: could not attach to the browser console ($e). '
            'App output will not appear in this run.');
        _consoleClient = null;
      }
    }

    return AppInstance(
        process: chrome, vmServiceUri: null, server: server, logs: logs);
  }

  /// Create the app log stream and start draining Chrome's own pipes.
  AppLogStream _startChromeLogs(Process chrome, AppLogListener? onLog) {
    _browserDiagnostics = AppLogStream(capacity: 200);
    // Chrome is this stream's only source; closing with it is what lets CDP
    // port discovery give up the moment the browser dies.
    _browserDiagnostics!
        .closeWhen([pumpProcessLines(chrome, _browserDiagnostics!).done]);

    // The app's own output is a separate stream with its own source — DWDS or
    // CDP, wired by the caller — so it does not close with the browser process.
    return _newAppLogs(onLog);
  }

  @override
  Future<void> stop(AppInstance instance) async {
    await _consoleClient?.close();
    _consoleClient = null;
    await _moduleServer?.stop();
    await instance.server?.close();
    instance.process.kill();
    await instance.logs.close();
  }

  /// `_flutter.screenshot` is an engine RPC with no web implementation — the
  /// browser is the compositor. CDP's `Page.captureScreenshot` (the `native`
  /// endpoint) is the capture that exists here.
  @override
  bool get supportsFlutterScreenshot => false;

  @override
  Future<void> screenshot(AppInstance instance, String outputPath,
      {VmServiceClient? vmClient, String? window}) async {
    if (_cdpPort == null) {
      throw StateError('CDP port not discovered — cannot capture screenshot');
    }
    await _cdpScreenshot(_cdpPort!, outputPath, appUrl: _appUrl);
  }
}

/// Serve static files from a directory with CORS headers for WASM.
void _serveDirectory(HttpServer server, String rootPath) {
  server.listen((request) async {
    // CORS headers required for WASM SharedArrayBuffer.
    request.response.headers.add('Cross-Origin-Opener-Policy', 'same-origin');
    request.response.headers
        .add('Cross-Origin-Embedder-Policy', 'require-corp');

    var path = request.uri.path;
    if (path == '/') path = '/index.html';
    final file = File('$rootPath$path');
    if (await file.exists()) {
      final ext = path.split('.').last;
      request.response.headers.contentType = _contentType(ext);
      await request.response.addStream(file.openRead());
    } else {
      request.response.statusCode = HttpStatus.notFound;
    }
    await request.response.close();
  });
}

ContentType _contentType(String ext) {
  return switch (ext) {
    'html' => ContentType.html,
    'js' || 'mjs' => ContentType('application', 'javascript'),
    'wasm' => ContentType('application', 'wasm'),
    'json' => ContentType.json,
    'css' => ContentType('text', 'css'),
    'png' => ContentType('image', 'png'),
    'ico' => ContentType('image', 'x-icon'),
    _ => ContentType.binary,
  };
}

/// Chrome's announcement of its debugging port, printed to stderr when
/// launched with `--remote-debugging-port=0`:
/// `DevTools listening on ws://127.0.0.1:PORT/devtools/browser/...`
final cdpPortPattern = RegExp(r'DevTools listening on ws://\S+?:(\d+)/');

/// Discover the CDP debugging port from Chrome's own diagnostic output.
///
/// Reads [browserDiagnostics] rather than subscribing to Chrome's pipes
/// directly, so finding the port doesn't stop those pipes being drained — an
/// unread stderr on a browser as chatty as Chrome is the likeliest place for a
/// full-pipe stall.
Future<int?> _discoverCdpPort(
  AppLogStream browserDiagnostics, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final completer = Completer<int?>();
  final timer = Timer(timeout, () {
    if (!completer.isCompleted) completer.complete(null);
  });

  final sub = browserDiagnostics.lines.listen(
    (line) {
      if (completer.isCompleted) return;
      final match = cdpPortPattern.firstMatch(line.text);
      if (match != null) completer.complete(int.parse(match.group(1)!));
    },
    onDone: () {
      if (!completer.isCompleted) completer.complete(null);
    },
  );

  try {
    return await completer.future;
  } finally {
    timer.cancel();
    await sub.cancel();
  }
}

/// Capture a screenshot via Chrome DevTools Protocol.
///
/// Connects to `http://127.0.0.1:<port>/json` to discover the app tab's
/// WebSocket URL, then sends `Page.captureScreenshot` over CDP.
/// If [appUrl] is provided, selects the tab matching that URL.
Future<void> _cdpScreenshot(int cdpPort, String outputPath,
    {String? appUrl}) async {
  final client = HttpClient();
  try {
    // Same target selection the console forwarder uses — see
    // `cdp_console.dart`.
    final wsUrl = await resolveCdpPageTarget(cdpPort, appUrl: appUrl);

    // Connect WebSocket and send Page.captureScreenshot.
    final ws = await WebSocket.connect(wsUrl);
    final responseCompleter = Completer<Map<String, dynamic>>();

    ws.listen((data) {
      final msg = json.decode(data as String) as Map<String, dynamic>;
      if (msg['id'] == 1 && !responseCompleter.isCompleted) {
        responseCompleter.complete(msg);
      }
    });

    ws.add(json.encode({
      'id': 1,
      'method': 'Page.captureScreenshot',
      'params': {'format': 'png'},
    }));

    final response =
        await responseCompleter.future.timeout(const Duration(seconds: 10));
    await ws.close();

    final result = response['result'] as Map<String, dynamic>?;
    if (result == null || result['data'] == null) {
      throw StateError('CDP screenshot returned no data');
    }

    // Decode base64 PNG and write to file.
    final bytes = base64.decode(result['data'] as String);
    await File(outputPath).writeAsBytes(bytes);
  } finally {
    client.close();
  }
}

/// Find the Chrome executable path, or null if not found.
///
/// One definition of where Chrome lives, shared with the preflight that reports
/// its absence — see [chromeTool].
String? findChrome() => chromeTool().find();
