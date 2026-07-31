/// Per-device session state and shared interactive session loop.
///
/// A [DeviceSession] holds the runtime state for one device: the launched
/// app instance, VM service client, and optional DevTools URL. The shared
/// [runInteractiveSession] function drives the file watcher, keyboard
/// loop, and hot reload across all active sessions.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dds/dds.dart';
import 'package:watcher/watcher.dart';

import 'command_runner.dart';
import 'device.dart';
import 'frontend_server.dart';
import 'hot_reload/package_uri_resolver.dart';
import 'machine_protocol.dart';
import 'reload_strategy.dart';
import 'vm_service_client.dart';

/// Runtime state for a single device in a multi-device run.
class DeviceSession {
  final Device device;

  /// The app process this session currently owns.
  ///
  /// Not fixed for the life of the session: a restart that finds changed
  /// native libraries relaunches the process (see [relaunch]), replacing the
  /// instance and its VM service connection.
  AppInstance get appInstance => _appInstance;
  AppInstance _appInstance;

  VmServiceClient? vmClient;
  final String appId;
  String? devToolsUrl;
  Process? devToolsProcess;

  /// The Dart Development Service we started on the app's VM service — the
  /// app's own on native, DWDS's debug service on web. Our [vmClient] and
  /// DevTools both connect through it (DDS multiplexes), so they no longer
  /// evict each other.
  ///
  /// Mutable: a web hot restart reloads the page and replaces the debug
  /// service, so the session re-owns a fresh DDS on every browser connection.
  /// Null only when DDS could not be started.
  DartDevelopmentService? dds;

  final Completer<void> _debugReady = Completer<void>();

  /// Completes once [vmClient] and [dds] are both populated.
  ///
  /// Native devices are debug-ready the moment the session exists. Web is not:
  /// DWDS only hands over a debug service when the browser connects, which is
  /// after the session is constructed and `app.started` has been emitted.
  /// Consumers that need the VM service — DevTools, chiefly — wait on this
  /// instead of sampling the fields once and finding them null on web.
  Future<void> get debugReady => _debugReady.future;

  /// Idempotent: a web hot restart re-runs the connect path.
  void markDebugReady() {
    if (!_debugReady.isCompleted) _debugReady.complete();
  }

  /// How many times this session's app has been launched: 1 for the original
  /// launch, one more for every [relaunch].
  ///
  /// Each [AppInstance] carries its own log buffer, numbered from zero, so a
  /// `/logs` cursor only means anything within one launch. This counter is
  /// what tells a poller its cursor belongs to a process that is gone.
  int get launch => _launch;
  int _launch = 1;

  final Completer<void> _terminated = Completer<void>();

  /// True only for the window inside [relaunch] where the outgoing process has
  /// been killed and its replacement has not arrived yet.
  bool _relaunching = false;

  /// Completes when this session's app is gone for good.
  ///
  /// Deliberately not `appInstance.process.exitCode`: [relaunch] kills the
  /// running process on purpose to install a replacement, and that exit does
  /// not end the session. A caller that watches the process directly sees a
  /// relaunch as a dead app and tears the run's transports down — the HTTP
  /// control channel included — while the relaunched app is alive and
  /// answering.
  Future<void> get terminated => _terminated.future;

  DeviceSession({
    required this.device,
    required AppInstance appInstance,
    required this.vmClient,
    required this.appId,
    this.dds,
  }) : _appInstance = appInstance {
    if (vmClient != null && dds != null) markDebugReady();
    _watchForExit(appInstance);
  }

  void _watchForExit(AppInstance instance) {
    unawaited(instance.process.exitCode.then((_) {
      // Ignore the exit of a process this session no longer owns, and the
      // exit of the one currently being replaced.
      if (_relaunching || !identical(instance, _appInstance)) return;
      _markTerminated();
    }));
  }

  void _markTerminated() {
    if (!_terminated.isCompleted) _terminated.complete();
  }

  /// Replace the running app process with a freshly launched one.
  ///
  /// [launchReplacement] owns the entire swap — stopping the outgoing process
  /// and starting its replacement — because the window between the two is
  /// exactly what must not read as the session ending. If it throws, the
  /// session really is over: the old process is gone and nothing replaced it,
  /// so [terminated] completes.
  Future<void> relaunch(
      Future<AppInstance> Function() launchReplacement) async {
    _relaunching = true;
    try {
      _appInstance = await launchReplacement();
      _launch++;
      _watchForExit(_appInstance);
    } catch (_) {
      _markTerminated();
      rethrow;
    } finally {
      _relaunching = false;
    }
  }
}

/// Result of a compile + reload/restart operation.
class ReloadResult {
  /// Whether the compile step succeeded.
  final bool compileSuccess;

  /// What applying the compiled output achieved. Null when the compile failed
  /// and nothing was applied.
  final StrategyOutcome? outcome;

  final String diagnostics;
  final int elapsedMs;

  /// Whether every device that could take the edit took it.
  ///
  /// A run where no device could take it is not a success: `outcome` is
  /// [StrategyUnsupported] and nothing is live.
  bool get deviceSuccess => outcome?.isSuccess ?? false;

  /// Overall success: both compile and device steps succeeded.
  bool get success => compileSuccess && deviceSuccess;

  /// The user-facing explanation when this was not a clean success.
  String? get failureReason =>
      outcome == null || outcome!.isSuccess ? null : outcome!.message;

  ReloadResult({
    required this.compileSuccess,
    this.outcome,
    this.diagnostics = '',
    required this.elapsedMs,
  });
}

/// Incrementally recompile and hot reload all devices.
///
/// Calls [FrontendServer.recompile] with the given [invalidatedFiles], then
/// applies the result via [reloadStrategy]. On compile failure, calls [reject]
/// so the frontend server stays in a clean state.
///
/// If no [reloadStrategy] is provided, falls back to [VmServiceReloadStrategy].
Future<ReloadResult> recompileAndReload({
  required FrontendServer frontendServer,
  required String entrypoint,
  required List<String> invalidatedFiles,
  required List<DeviceSession> sessions,
  ReloadStrategy? reloadStrategy,
}) async {
  final strategy = reloadStrategy ?? VmServiceReloadStrategy();
  final stopwatch = Stopwatch()..start();
  try {
    final result =
        await frontendServer.recompile(entrypoint, invalidatedFiles);
    if (!result.success) {
      frontendServer.reject();
      stopwatch.stop();
      return ReloadResult(
        compileSuccess: false,
        diagnostics: result.diagnostics,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
    }
    frontendServer.accept();
    final outcome = await strategy.applyReload(result, sessions);
    stopwatch.stop();
    return ReloadResult(
      compileSuccess: true,
      outcome: outcome,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  } catch (e) {
    stopwatch.stop();
    return ReloadResult(
      compileSuccess: false,
      diagnostics: e.toString(),
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  }
}

/// Full recompile and hot restart all devices.
///
/// Calls [FrontendServer.compile] to rebuild from scratch, then applies
/// the result via [reloadStrategy].
///
/// If no [reloadStrategy] is provided, falls back to [VmServiceReloadStrategy].
Future<ReloadResult> recompileAndRestart({
  required FrontendServer frontendServer,
  required String entrypoint,
  required List<DeviceSession> sessions,
  ReloadStrategy? reloadStrategy,
}) async {
  final strategy = reloadStrategy ?? VmServiceReloadStrategy();
  final stopwatch = Stopwatch()..start();
  try {
    final result = await frontendServer.compile(entrypoint);
    if (!result.success) {
      stopwatch.stop();
      return ReloadResult(
        compileSuccess: false,
        diagnostics: result.diagnostics,
        elapsedMs: stopwatch.elapsedMilliseconds,
      );
    }
    frontendServer.accept();
    final outcome = await strategy.applyRestart(result, sessions);
    stopwatch.stop();
    return ReloadResult(
      compileSuccess: true,
      outcome: outcome,
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  } catch (e) {
    stopwatch.stop();
    return ReloadResult(
      compileSuccess: false,
      diagnostics: e.toString(),
      elapsedMs: stopwatch.elapsedMilliseconds,
    );
  }
}

/// Render the result of an `app.hotReload` / `app.restart` command.
///
/// The HTTP control channel hands this map back to its caller, but the
/// interactive session dropped it — so pressing "r" printed nothing whether
/// the edit went live, was refused, or reached no device at all. A silent
/// success and a silent failure are indistinguishable, which makes the key
/// useless as feedback.
void reportReloadCommand(
  String action,
  Map<String, dynamic> result,
  void Function(String message) log,
) {
  if (result['error'] case final error?) {
    stderr.writeln('$action failed: $error');
    return;
  }
  final message = result['message'] ?? '$action complete';
  if (result['isEmpty'] == true) {
    log('$message (no changes)');
    return;
  }
  final files = result['filesRecompiled'];
  if (files is List && files.isNotEmpty) {
    log('$message (${files.length} file(s))');
    return;
  }
  log('$message');
}

/// Signature for reading keyboard input (allows test injection).
typedef KeyboardReader = Stream<List<int>> Function();

/// Run the shared interactive session loop for one or more device sessions.
///
/// Handles file watching, keyboard input, and broadcasting hot reload/restart
/// across all sessions. Returns when the user quits or all sessions end.
///
/// When [hotReloadEnabled] is false (e.g. profile mode), file watching and
/// hot reload ('r') are disabled but DevTools, perf overlay, inspector, and
/// quit still work.
Future<void> runInteractiveSession({
  required List<DeviceSession> sessions,
  required FrontendServer? frontendServer,
  required String entrypoint,
  required String workspace,
  required MachineProtocol protocol,
  CommandRunner? commandRunner,
  required bool devToolsEnabled,
  /// Dart binary from the Flutter toolchain, used to serve DevTools. Required
  /// even when [devToolsEnabled] is false so the caller resolves it once,
  /// rather than each launch site re-deriving it.
  required String dartExecutable,
  bool hotReloadEnabled = true,
  bool watchEnabled = true,
  ReloadStrategy? reloadStrategy,
  PackageUriResolver? resolver,
  void Function(String message)? log,
  KeyboardReader? keyboardReader,
  void Function(bool echoMode)? setEchoMode,
  void Function(bool lineMode)? setLineMode,
  Future<void>? shutdownSignal,
}) async {
  log ??= (msg) => stdout.writeln(msg);

  // Launch DevTools once each session can serve it. Native is ready
  // immediately; web resolves when the browser connects, so this is wired as a
  // continuation rather than a check — waiting here would block the terminal
  // until a page loads, and checking now would always miss web.
  if (devToolsEnabled) {
    final logDevTools = log;
    for (final session in sessions) {
      unawaited(session.debugReady.then((_) async {
        try {
          // Web arrives with a URL already: DWDS runs the DDS that serves
          // DevTools, and hands it over on the debug connection. Native owns
          // its DDS but not a DevTools server, so it spawns one and points it
          // at the DDS endpoint — never at the raw VM service, because DDS
          // multiplexing is what stops DevTools evicting our own vmClient.
          var url = session.devToolsUrl;
          if (url == null) {
            final dds = session.dds!;
            final devtools = await _launchDevTools(dartExecutable, dds.uri!);
            session.devToolsProcess = devtools.process;
            if (devtools.serverUrl == null) return;
            url = devToolsConnectUri(devtools.serverUrl!, dds.wsUri!).toString();
            session.devToolsUrl = url;
          }

          logDevTools('DevTools at $url (${session.device.name})');
        } catch (e) {
          // Non-fatal: DevTools is optional.
          stderr.writeln('Warning: Could not launch DevTools for ${session.device.name}: $e');
        }
      }));
    }
  }

  // The single-key shortcuts below are only wired up for an interactive
  // terminal. In `--machine` mode stdin is the JSON-RPC command channel (see
  // the `protocol.enabled` early-return after the watcher), so a keystroke like
  // "q" is parsed as JSON and fails with a -32700 parse error rather than
  // quitting. Worse, `log` writes to stdout — which the machine protocol owns —
  // so the banner would also corrupt the protocol stream. Suppress it entirely
  // in machine mode; the consumer drives the session via app.* commands.
  if (!protocol.enabled) {
    if (hotReloadEnabled) {
      if (watchEnabled) {
        log('Watching for file changes. Press "r" hot reload, "R" restart, "p" perf overlay, "i" inspector, "q" quit.');
      } else {
        log('Press "r" hot reload, "R" restart, "p" perf overlay, "i" inspector, "q" quit.');
      }
    } else {
      log('Press "p" perf overlay, "i" inspector, "q" quit.');
    }
  }

  // Start file watcher (only if watching is enabled, hot reload is enabled,
  // and frontend server is available).
  StreamSubscription<WatchEvent>? watcherSubscription;
  Timer? debounce;
  if (watchEnabled && hotReloadEnabled && frontendServer != null) {
    final watchResult = _watchAndReload(
      workspace: workspace,
      frontendServer: frontendServer,
      sessions: sessions,
      entrypoint: entrypoint,
      resolver: resolver,
      commandRunner: commandRunner,
      reloadStrategy: reloadStrategy,
      log: log,
    );
    watcherSubscription = watchResult.subscription;
    debounce = watchResult.debounce;
  }

  // In machine mode, stdin is consumed by MachineProtocol — skip the
  // keyboard loop and wait for sessions to end via machine commands.
  if (protocol.enabled) {
    // Wait until a session's app is gone for good or teardown is signalled
    // (`app.stop` / `daemon.shutdown`). The explicit signal matters for
    // sessions whose processes never exit on their own (attach mode's
    // pseudo-process) and lets the caller regain control to close its
    // transports AFTER the command that requested the teardown has sent
    // its response.
    //
    // `DeviceSession.terminated`, not `appInstance.process.exitCode`: the
    // latter is sampled once, so a restart that relaunches the process (its
    // native libraries changed) resolved it with the exit of the process it
    // had just deliberately replaced. The run then closed its transports —
    // the HTTP control channel included — leaving a driver with a healthy
    // relaunched app it could no longer talk to.
    final exitFutures = <Future<void>>[
      for (final s in sessions) s.terminated,
      if (shutdownSignal != null) shutdownSignal,
    ];
    if (exitFutures.isNotEmpty) {
      await Future.any(exitFutures);
    }
    debounce?.cancel();
    await watcherSubscription?.cancel();
    return;
  }

  // Keyboard loop (interactive terminal mode only).
  bool terminalConfigured = false;
  if (setEchoMode != null) {
    setEchoMode(false);
    terminalConfigured = true;
  } else if (stdin.hasTerminal) {
    try {
      stdin.echoMode = false;
      terminalConfigured = true;
    } on StdinException {
      // Not a real terminal (e.g. backgrounded process).
    }
  }
  if (setLineMode != null) {
    setLineMode(false);
  } else if (terminalConfigured) {
    stdin.lineMode = false;
  }

  final inputStream = keyboardReader != null ? keyboardReader() : stdin;

  // Race each key read against the shutdown signal so a session teardown
  // requested over the HTTP control channel (`app.stop`) ends the loop like
  // 'q' does, instead of leaving a stopped session waiting on the keyboard.
  final keys = StreamIterator<List<int>>(inputStream);
  while (true) {
    final hasNext = await Future.any<bool>([
      keys.moveNext(),
      if (shutdownSignal != null) shutdownSignal.then((_) => false),
    ]);
    if (!hasNext) break;
    final input = keys.current;
    final char = String.fromCharCode(input.first);
    switch (char) {
      case 'r':
        if (hotReloadEnabled) {
          if (commandRunner != null && commandRunner.hasCommand('app.hotReload')) {
            reportReloadCommand(
                'Hot reload', await commandRunner.run('app.hotReload', {}), log);
          } else if (frontendServer != null) {
            await _performHotReloadAll(
              frontendServer: frontendServer,
              sessions: sessions,
              entrypoint: entrypoint,
              invalidated: [entrypoint],
              reloadStrategy: reloadStrategy,
            );
          }
        }
      case 'R':
        if (hotReloadEnabled) {
          if (commandRunner != null && commandRunner.hasCommand('app.restart')) {
            stdout.writeln('Performing hot restart...');
            reportReloadCommand(
                'Hot restart', await commandRunner.run('app.restart', {}), log);
          } else if (frontendServer != null) {
            stdout.writeln('Performing hot restart...');
            final result = await recompileAndRestart(
              frontendServer: frontendServer,
              entrypoint: entrypoint,
              sessions: sessions,
              reloadStrategy: reloadStrategy,
            );
            if (!result.compileSuccess) {
              stderr.writeln('Compilation failed.');
              if (result.diagnostics.isNotEmpty) {
                stderr.write(result.diagnostics);
              }
            } else if (!result.deviceSuccess) {
              stderr.writeln('Hot restart failed on some devices.');
            } else {
              stdout.writeln('Hot restart done in ${result.elapsedMs}ms.');
            }
          }
        }
      case 'p':
        for (final session in sessions) {
          if (session.vmClient != null) {
            final enabled = await session.vmClient!.togglePerformanceOverlay();
            stdout.writeln('Performance overlay ${enabled ? "enabled" : "disabled"} (${session.device.name}).');
          }
        }
      case 'i':
        for (final session in sessions) {
          if (session.vmClient != null) {
            final enabled = await session.vmClient!.toggleWidgetInspector();
            stdout.writeln('Widget inspector ${enabled ? "enabled" : "disabled"} (${session.device.name}).');
          }
        }
      case 'q':
        // Cancel debounce timer before cancelling watcher.
        debounce?.cancel();
        await watcherSubscription?.cancel();
        for (final session in sessions) {
          session.devToolsProcess?.kill();
          protocol.appStop(session.appId);
          await session.vmClient?.disconnect();
          await session.dds?.shutdown();
          await session.device.stop(session.appInstance);
        }
        if (frontendServer != null) {
          await frontendServer.shutdown();
        }
        await keys.cancel();
        return;
    }
  }
  // Shutdown was signalled (or the input stream ended): the sessions were
  // already torn down by whoever signalled; just release local resources.
  debounce?.cancel();
  await watcherSubscription?.cancel();
  await keys.cancel();
}

/// Result from _watchAndReload containing the subscription and debounce timer
/// so they can be properly cancelled.
({StreamSubscription<WatchEvent> subscription, Timer? debounce}) _watchAndReload({
  required String workspace,
  required FrontendServer frontendServer,
  required List<DeviceSession> sessions,
  required String entrypoint,
  PackageUriResolver? resolver,
  CommandRunner? commandRunner,
  ReloadStrategy? reloadStrategy,
  required void Function(String message) log,
}) {
  final watcher = DirectoryWatcher(workspace);
  Timer? debounce;
  final changedFiles = <String>{};

  final subscription = watcher.events.listen((event) {
    if (!event.path.endsWith('.dart')) return;
    if (event.path.contains('bazel-')) return;

    changedFiles.add(event.path);

    debounce?.cancel();
    debounce = Timer(const Duration(milliseconds: 200), () async {
      final files = changedFiles.toList();
      changedFiles.clear();

      // Map each changed source path to the `package:` URI the frontend_server
      // keys it by, via the authoritative build-emitted resolver. A path that
      // belongs to no first-party source package (e.g. a tool script) resolves
      // to null and is skipped — never invalidated with a bogus file:// URI.
      final invalidated = [
        for (final f in files)
          if (resolver?.toPackageUri(f) case final uri?) uri,
      ];
      if (invalidated.isEmpty) return;

      if (commandRunner != null && commandRunner.hasCommand('app.hotReload')) {
        reportReloadCommand(
            'Hot reload',
            await commandRunner.run('app.hotReload', {
              'invalidatedFiles': invalidated,
            }),
            log);
      } else {
        await _performHotReloadAll(
          frontendServer: frontendServer,
          sessions: sessions,
          entrypoint: entrypoint,
          invalidated: invalidated,
          reloadStrategy: reloadStrategy,
        );
      }
    });
  });

  return (subscription: subscription, debounce: debounce);
}

/// Terminal-mode wrapper around [recompileAndReload] that prints status to
/// stdout/stderr.
Future<void> _performHotReloadAll({
  required FrontendServer frontendServer,
  required List<DeviceSession> sessions,
  required String entrypoint,
  required List<String> invalidated,
  ReloadStrategy? reloadStrategy,
}) async {
  stdout.writeln('Recompiling...');
  final result = await recompileAndReload(
    frontendServer: frontendServer,
    entrypoint: entrypoint,
    invalidatedFiles: invalidated,
    sessions: sessions,
    reloadStrategy: reloadStrategy,
  );
  if (!result.compileSuccess) {
    stderr.writeln('Compilation failed.');
    if (result.diagnostics.isNotEmpty) {
      stderr.write(result.diagnostics);
    }
  } else if (!result.deviceSuccess) {
    stderr.writeln('Hot reload failed on some devices. Try hot restart (R).');
  } else {
    stdout.writeln('Hot reload done in ${result.elapsedMs}ms.');
  }
}

/// The DevTools server root announced by `dart devtools`, or null for a line
/// that is not that announcement.
///
/// The announcement ends a sentence — `Serving DevTools at
/// http://127.0.0.1:9100.` — so the match is anchored to end of line and the
/// period is left outside the capture. Including it produces a URL that
/// `Uri.parse` rejects with `FormatException: Invalid port`.
String? parseDevToolsUrl(String line) =>
    RegExp(r'Serving DevTools at (http\S+?)\.?\s*$').firstMatch(line)?.group(1);

/// The URL that opens DevTools already attached to [vmServiceWsUri].
///
/// `dart devtools` announces only its own server root; opening that lands on
/// the "Connect to a Running App" form with nothing connected. DevTools reads
/// the target VM service from the `uri` query parameter, which is the same
/// shape DDS itself hands out (`…/devtools/?uri=ws://…/ws`).
///
/// Must be the **ws** URI: DevTools dials it as a WebSocket.
Uri devToolsConnectUri(String serverUrl, Uri vmServiceWsUri) =>
    Uri.parse(serverUrl).replace(
      queryParameters: {'uri': vmServiceWsUri.toString()},
    );

/// Start `dart devtools` and return the process plus its announced server root.
///
/// [dartExecutable] is the Dart binary from the Flutter toolchain. Resolving it
/// rather than spawning a bare `dart` keeps the DevTools we launch tied to the
/// SDK the app was built with, and fails loudly when the toolchain is missing
/// instead of picking up whatever happens to be on `PATH`.
Future<({Process process, String? serverUrl})> _launchDevTools(
  String dartExecutable,
  Uri vmServiceUri,
) async {
  final process = await Process.start(
    dartExecutable,
    ['devtools', '--no-launch-browser', '--vm-uri=$vmServiceUri'],
  );

  final completer = Completer<String?>();
  Timer? timeout;

  timeout = Timer(const Duration(seconds: 15), () {
    if (!completer.isCompleted) completer.complete(null);
  });

  process.stdout
      .transform(const SystemEncoding().decoder)
      .transform(const LineSplitter())
      .listen((line) {
    final url = parseDevToolsUrl(line);
    if (url != null && !completer.isCompleted) {
      timeout?.cancel();
      completer.complete(url);
    }
  });

  final serverUrl = await completer.future;
  return (process: process, serverUrl: serverUrl);
}

