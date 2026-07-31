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
/// Uses DWDS's VM service to trigger `$dartReloadModifiedModules` (reload)
/// or page restart via the DWDS-injected client.
///
/// Flow for hot reload:
///   1. Update module server with new DDC output
///   2. DWDS VM service `reloadSources` → `$dartReloadModifiedModules` in browser
///   3. `ext.flutter.reassemble` → widget rebuild with preserved state
///
/// Flow for hot restart:
///   1. Update module server with new DDC output
///   2. CDP Page.reload → page reloads with new modules
class DwdsReloadStrategy implements ReloadStrategy {
  final WebModuleServer moduleServer;

  /// CDP port for page reload (hot restart fallback).
  final int? cdpPort;

  /// App URL for finding the correct CDP tab.
  final String? appUrl;

  /// The DWDS VM service instance. (Re-)attached on every browser connection
  /// via [attachVmService] — a web hot restart is a CDP page reload, which
  /// replaces the page's isolate and VM service, so the prior connection dies.
  vm.VmService? get vmService => _vmService;
  vm.VmService? _vmService;

  /// The main isolate ID from the DWDS VM service.
  String? _isolateId;

  /// Completed by [attachVmService] when a new browser connection re-attaches
  /// the VM service. [applyRestart] arms this before triggering the page reload
  /// so it can wait for the reconnect before returning.
  Completer<void>? _reattachCompleter;

  DwdsReloadStrategy({
    required this.moduleServer,
    this.cdpPort,
    this.appUrl,
  });

  /// Attach (or replace) the DWDS VM service after a browser (re)connection.
  ///
  /// Disposes any prior connection (dead after a page reload) and clears the
  /// cached isolate id so the next reload re-discovers the new page's isolate.
  void attachVmService(vm.VmService service) {
    unawaited(_vmService?.dispose());
    _vmService = service;
    _isolateId = null;
    if (_reattachCompleter case final c? when !c.isCompleted) {
      c.complete();
    }
  }

  /// Arm a one-shot future that completes on the next [attachVmService].
  Future<void> _awaitReattach() {
    final completer = Completer<void>();
    _reattachCompleter = completer;
    return completer.future;
  }

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
      // A restart still gets the edit in front of the user, but it is not the
      // reload they asked for — say so rather than reporting it as one.
      final restarted = await applyRestart(result, sessions);
      if (restarted.isSuccess) {
        return const StrategyUnsupported(
            'DWDS VM service not connected — restarted instead of reloading');
      }
      return restarted;
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

    // Hot restart uses CDP page reload — the page reloads and picks up
    // the new modules from the module server.
    if (cdpPort == null) {
      return const StrategyUnsupported(
          'no CDP port — cannot reload the browser page');
    }
    try {
      // Arm BEFORE triggering the reload so we can't miss the reconnect event.
      final reattached = _awaitReattach();
      await _cdpPageReload(cdpPort!, appUrl: appUrl);
      // Wait for the browser to reconnect and re-attach the VM service, so a
      // hot reload issued right after this restart uses the live connection
      // rather than the now-dead one. Bounded so a missed reconnect logs and
      // returns instead of hanging the session.
      var reconnected = true;
      await reattached.timeout(const Duration(seconds: 10), onTimeout: () {
        reconnected = false;
      });
      if (!reconnected) {
        // The page was told to reload but never came back, so there is no
        // live connection and no evidence the new code is running. Reporting
        // success here left the next reload talking to a dead isolate.
        return const StrategyRejected(
            'the browser did not reconnect within 10s of the page reload');
      }
      return const StrategyApplied(1);
    } catch (e) {
      return StrategyRejected('CDP page reload failed: $e');
    }
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
