/// Strategy for applying compilation results to running devices.
///
/// Abstracts the difference between VM service-based hot reload (native),
/// DWDS VM service-based reload (web DDC), and CDP page reload (web WASM).
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:vm_service/vm_service.dart' as vm;

import 'frontend_server.dart';
import 'session.dart';
import 'web_module_server.dart';

/// JSON-RPC 2.0 "method not found" error code. The web engine doesn't
/// register `ext.flutter.reassemble`, so a call returns this — expected and
/// benign on the modern DDC hot-reload path (the module reload already
/// rebuilds the tree).
const int _rpcMethodNotFound = -32601;

/// `kIsolateCannotReload`. DWDS raises it when no browser client is attached.
const int _rpcIsolateCannotReload = 109;

/// `kServerError`. Reached by the same "no client" condition on the Chrome
/// path, which fails with a `StateError` that `package:vm_service` re-encodes
/// rather than preserving code 109. Upstream accepts both for this reason
/// (`resident_web_runner.dart:544-546`).
const int _rpcServerError = -32000;

/// Said whenever the recompiled code has nowhere to go. Not a failure: the
/// modules are served, so the next client to connect loads them.
const String _noClientMessage = 'no browser client connected — the recompiled '
    'code will load when one connects';

/// What applying compiled output to the running app(s) achieved.
///
/// Sits below `ReloadOutcome` in `hot_reload/reload_orchestrator.dart`, which
/// describes a whole compile-and-apply cycle; this describes only the apply.
/// The two converge once web joins the orchestrator via `AppInstance`.
///
/// A bool cannot tell "every app took it" apart from "no app could take it",
/// and both reduce to `true` under `[].every(...)`. Reporting the second as
/// success is worse than reporting a failure: the user is told their edit is
/// live when nothing received it.
sealed class StrategyOutcome {
  const StrategyOutcome();

  /// Whether the edit is actually running now.
  bool get isSuccess => this is StrategyApplied;

  /// One line explaining a non-success, for the terminal and the protocol.
  String get message;
}

/// The edit reached [deviceCount] running app(s).
final class StrategyApplied extends StrategyOutcome {
  final int deviceCount;

  const StrategyApplied(this.deviceCount);

  @override
  String get message => 'applied to $deviceCount device(s)';
}

/// Nothing could take the edit, so nothing changed.
///
/// Distinct from rejection: no app was ever reached. A session with no VM
/// service connection, or a compilation mode with no reload mechanism at all,
/// lands here.
final class StrategyUnsupported extends StrategyOutcome {
  @override
  final String message;

  const StrategyUnsupported(this.message);
}

/// An app was reached and refused the edit.
final class StrategyRejected extends StrategyOutcome {
  @override
  final String message;

  const StrategyRejected(this.message);
}

/// How to apply compiled output to running devices.
abstract interface class ReloadStrategy {
  /// Apply incremental changes (hot reload).
  Future<StrategyOutcome> applyReload(
      CompileResult result, List<DeviceSession> sessions);

  /// Apply full restart.
  Future<StrategyOutcome> applyRestart(
      CompileResult result, List<DeviceSession> sessions);
}

/// Reload strategy for native platforms via Dart VM service.
///
/// Uploads the compiled dill to each device's devFS and triggers
/// `reloadSources` + `reassemble` (reload) or `hotRestart` (restart).
class VmServiceReloadStrategy implements ReloadStrategy {
  /// The sessions that can actually be reloaded.
  ///
  /// Sessions without a VM service connection are not failures, but they are
  /// not successes either — they cannot receive anything. Separating them here
  /// is what stops an all-unreachable run reporting success.
  static List<DeviceSession> _reachable(List<DeviceSession> sessions) =>
      [for (final s in sessions) if (s.vmClient != null) s]; // no client, no reload

  static StrategyOutcome _outcome(List<bool> results, int reachable) {
    if (reachable == 0) {
      return const StrategyUnsupported(
          'no device has a VM service connection — nothing received the edit');
    }
    final failed = results.where((ok) => !ok).length;
    if (failed > 0) {
      return StrategyRejected('$failed of $reachable device(s) refused it');
    }
    return StrategyApplied(reachable);
  }

  @override
  Future<StrategyOutcome> applyReload(
      CompileResult result, List<DeviceSession> sessions) async {
    final reachable = _reachable(sessions);
    final results = await Future.wait(
        [for (final s in reachable) s.vmClient!.hotReload(result.dillPath)]);
    return _outcome(results, reachable.length);
  }

  @override
  Future<StrategyOutcome> applyRestart(
      CompileResult result, List<DeviceSession> sessions) async {
    final reachable = _reachable(sessions);
    final results = await Future.wait(
        [for (final s in reachable) s.vmClient!.hotRestart(result.dillPath)]);
    return _outcome(results, reachable.length);
  }
}

/// Reload strategy for web DDC via DWDS VM service protocol.
///
/// Uses DWDS's VM service for both operations, so neither navigates the page.
///
/// Flow for hot reload:
///   1. Update module server with new DDC output
///   2. DWDS VM service `reloadSources` → `$dartReloadModifiedModules` in browser
///   3. `ext.flutter.reassemble` → widget rebuild with preserved state
///
/// Flow for hot restart:
///   1. Update module server with new DDC output
///   2. DWDS's `hotRestart` service → `$dartHotRestartDwds` in the browser,
///      which swaps the new modules in and starts a fresh isolate
///
/// The page survives both. That is what separates this from [CdpReloadStrategy]
/// and [WasmReloadStrategy], which navigate — upstream reserves `Page.reload`
/// for non-debug builds too (`resident_web_runner.dart:612-617`).
class DwdsReloadStrategy implements ReloadStrategy {
  final WebModuleServer moduleServer;

  /// How long to wait for a `hotRestart` before giving up on it.
  ///
  /// Purely a hang-guard: DWDS awaits its new isolate's `IsolateStart` with no
  /// timeout of its own (`dwds_vm_client.dart:530`), so a page that never
  /// reports one would wedge the session for good. Not a latency budget — a
  /// restart that takes this long has gone wrong.
  final Duration restartTimeout;

  /// The DWDS VM service instance, or null before a browser has connected.
  ///
  /// (Re-)attached via [attachVmService] on every browser connection: a
  /// genuine page navigation (the user hitting reload, a crash) replaces the
  /// page's isolate and VM service, so the prior connection dies.
  vm.VmService? get vmService => _vmService;
  vm.VmService? _vmService;

  /// The main isolate ID from the DWDS VM service.
  String? _isolateId;

  /// Service name → the method name to actually call, as announced by
  /// `ServiceRegistered` events. See [_hotRestartMethod].
  final Map<String, String> _registeredServices = {};

  StreamSubscription<vm.Event>? _serviceSub;

  DwdsReloadStrategy({
    required this.moduleServer,
    this.restartTimeout = const Duration(seconds: 60),
  });

  /// Attach (or replace) the DWDS VM service after a browser (re)connection.
  ///
  /// Disposes any prior connection (dead after a navigation), clears the cached
  /// isolate id so the next reload re-discovers the new page's isolate, and
  /// re-subscribes to the `Service` stream to learn this connection's service
  /// names — registrations do not survive the connection that made them.
  Future<void> attachVmService(vm.VmService service) async {
    await _serviceSub?.cancel();
    unawaited(_vmService?.dispose());
    _vmService = service;
    _isolateId = null;
    _registeredServices.clear();
    // Listen before subscribing: DDS replays every existing registration when
    // a client subscribes to the stream (dds `stream_manager.dart:252-269`),
    // and those replayed events would otherwise land before we were looking.
    _serviceSub = service.onServiceEvent.listen(_onServiceEvent);
    await service.streamListen(vm.EventStreams.kService);
  }

  void _onServiceEvent(vm.Event event) {
    final service = event.service;
    if (service == null) return;
    switch (event.kind) {
      case vm.EventKind.kServiceRegistered:
        if (event.method case final method?) {
          _registeredServices[service] = method;
        }
      case vm.EventKind.kServiceUnregistered:
        _registeredServices.remove(service);
    }
  }

  /// The method name for DWDS's hot restart.
  ///
  /// DWDS registers it as a *client-provided* service named `hotRestart`
  /// (`dwds_vm_client.dart:333`). With DWDS owning the DDS, DDS exposes it to
  /// other clients under that client's namespace — `s0.hotRestart` — so the
  /// bare name gets `kMethodNotFound`. The registered name is therefore read
  /// off a `ServiceRegistered` event rather than assumed.
  ///
  /// The bare name is the correct name when nothing was registered: that is a
  /// DWDS with no DDS in front of it, not a degraded state.
  String get _hotRestartMethod => _registeredServices['hotRestart'] ?? 'hotRestart';

  /// Discover the main isolate ID from the VM service.
  Future<String?> _getIsolateId() async {
    if (_isolateId != null) return _isolateId;
    if (vmService == null) return null;
    final vmInfo = await vmService!.getVM();
    if (vmInfo.isolates != null && vmInfo.isolates!.isNotEmpty) {
      _isolateId = vmInfo.isolates!.first.id;
    }
    return _isolateId;
  }

  @override
  Future<StrategyOutcome> applyReload(
      CompileResult result, List<DeviceSession> sessions) async {
    // Update modules — DDC writes incremental output to the same files.
    moduleServer.updateModules(result.dillPath);

    if (vmService == null) {
      // This used to delegate to applyRestart for a CDP page reload. Restart is
      // now a DWDS call that needs the same connection, so the delegation would
      // only recurse into this check.
      return const StrategyUnsupported(_noClientMessage);
    }

    try {
      final isolateId = await _getIsolateId();
      if (isolateId == null) {
        return const StrategyUnsupported('no isolate found in the browser');
      }

      // Trigger DWDS hot reload: reloadSources → $dartReloadModifiedModules.
      final report = await vmService!.reloadSources(isolateId);
      if (report.success != true) {
        return const StrategyRejected('the browser refused the new sources');
      }

      // Trigger Flutter widget rebuild to pick up the new code. On the modern
      // DDC hot-reload path the `$dartReloadModifiedModules` invoked by
      // reloadSources above already rebuilds the tree, and the web engine does
      // NOT register `ext.flutter.reassemble` (RPC -32601 "method not found").
      // That case is expected and benign — don't warn on it, or every web
      // reload prints a spurious failure. Only surface genuine errors.
      try {
        await vmService!.callServiceExtension(
          'ext.flutter.reassemble',
          isolateId: isolateId,
        );
      } on vm.RPCError catch (e) {
        if (e.code != _rpcMethodNotFound) {
          stderr.writeln('Warning: ext.flutter.reassemble failed: $e');
        }
      } catch (e) {
        stderr.writeln('Warning: ext.flutter.reassemble failed: $e');
      }

      return const StrategyApplied(1);
    } catch (e) {
      return StrategyRejected('DWDS hot reload failed: $e');
    }
  }

  @override
  Future<StrategyOutcome> applyRestart(
      CompileResult result, List<DeviceSession> sessions) async {
    moduleServer.updateModules(result.dillPath);

    final service = _vmService;
    if (service == null) {
      // Upstream's answer too: report, don't wait and don't touch the page
      // (`resident_web_runner.dart:519`). The modules are already served, so a
      // client that connects later gets the new code as its first load.
      return const StrategyUnsupported(_noClientMessage);
    }

    try {
      await service.callMethod(_hotRestartMethod).timeout(restartTimeout);
    } on TimeoutException {
      return StrategyRejected('the browser did not report a restarted isolate '
          'within ${restartTimeout.inSeconds}s');
    } on vm.RPCError catch (e) {
      if (e.code == _rpcIsolateCannotReload || e.code == _rpcServerError) {
        return const StrategyUnsupported(_noClientMessage);
      }
      return StrategyRejected(e.message);
    }

    // Load-bearing. DWDS swapped the code into the live page, so there is no
    // navigation, no browser reconnect, and no attachVmService call — the only
    // other place this is cleared. Left set, it names the isolate DWDS just
    // replaced and the next hot reload calls reloadSources on a dead one.
    _isolateId = null;
    return const StrategyApplied(1);
  }
}

/// Reload strategy for web DDC via recompile + CDP Page.reload.
///
/// Updates the [WebModuleServer] with new DDC output, then sends
/// `Page.reload` to Chrome via the Chrome DevTools Protocol.
class CdpReloadStrategy implements ReloadStrategy {
  final int cdpPort;
  final String? appUrl;

  /// Module server to update before page reload. Null for WASM mode.
  final WebModuleServer? moduleServer;

  CdpReloadStrategy({
    required this.cdpPort,
    this.appUrl,
    this.moduleServer,
  });

  @override
  Future<StrategyOutcome> applyReload(
      CompileResult result, List<DeviceSession> sessions) async {
    // CDP has no incremental reload — always do full page reload.
    return applyRestart(result, sessions);
  }

  @override
  Future<StrategyOutcome> applyRestart(
      CompileResult result, List<DeviceSession> sessions) async {
    // Update module server with recompiled DDC output before reload.
    moduleServer?.updateModules(result.dillPath);
    try {
      await _cdpPageReload(cdpPort, appUrl: appUrl);
      return const StrategyApplied(1);
    } catch (e) {
      return StrategyRejected('CDP Page.reload failed: $e');
    }
  }
}

/// Reload strategy for WASM web via bazel rebuild + CDP Page.reload.
///
/// WASM has no frontend server and no DWDS — hot restart means:
///   1. Re-run `bazel build` to recompile the WASM binary
///   2. CDP `Page.reload` to pick up the new files
class WasmReloadStrategy implements ReloadStrategy {
  final int cdpPort;
  final String? appUrl;

  /// Callback to rebuild via bazel. Returns true on success.
  final Future<bool> Function() rebuild;

  WasmReloadStrategy({
    required this.cdpPort,
    required this.rebuild,
    this.appUrl,
  });

  @override
  Future<StrategyOutcome> applyReload(
      CompileResult result, List<DeviceSession> sessions) async {
    // dart2wasm has no incremental reload, so this is a rebuild and a page
    // reload. It gets the edit running, but state is lost — reporting it as a
    // hot reload would misdescribe what the user just got.
    final restarted = await applyRestart(result, sessions);
    if (restarted.isSuccess) {
      return const StrategyUnsupported(
          'WASM has no hot reload — rebuilt and reloaded the page instead');
    }
    return restarted;
  }

  @override
  Future<StrategyOutcome> applyRestart(
      CompileResult result, List<DeviceSession> sessions) async {
    try {
      final buildOk = await rebuild();
      if (!buildOk) {
        return const StrategyRejected('the WASM rebuild failed');
      }
      await _cdpPageReload(cdpPort, appUrl: appUrl);
      return const StrategyApplied(1);
    } catch (e) {
      return StrategyRejected('WASM hot restart failed: $e');
    }
  }
}

/// Send Page.reload via Chrome DevTools Protocol.
Future<void> _cdpPageReload(int cdpPort, {String? appUrl}) async {
  final client = HttpClient();
  try {
    // Get the list of targets (tabs).
    final listReq =
        await client.getUrl(Uri.parse('http://127.0.0.1:$cdpPort/json'));
    final listResp = await listReq.close();
    final listBody = await listResp.transform(utf8.decoder).join();
    final targets = json.decode(listBody) as List;
    if (targets.isEmpty) {
      throw StateError('No CDP targets found');
    }

    // Find the page target matching our app URL.
    final pageTargets =
        targets.where((t) => (t as Map)['type'] == 'page').toList();
    Map target;
    if (appUrl != null) {
      final appTarget = pageTargets.where((t) {
        final url = (t as Map)['url'] as String? ?? '';
        return url.startsWith(appUrl);
      });
      target = appTarget.isNotEmpty
          ? appTarget.first as Map
          : (pageTargets.isNotEmpty
              ? pageTargets.first as Map
              : targets.first as Map);
    } else {
      target = pageTargets.isNotEmpty
          ? pageTargets.first as Map
          : targets.first as Map;
    }

    final wsUrl = target['webSocketDebuggerUrl'] as String?;
    if (wsUrl == null) {
      throw StateError('No WebSocket URL in CDP target');
    }

    // Connect and send Page.reload.
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
      'method': 'Page.reload',
      'params': {'ignoreCache': true},
    }));

    await responseCompleter.future.timeout(const Duration(seconds: 10));
    await ws.close();
  } finally {
    client.close();
  }
}
