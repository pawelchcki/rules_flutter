/// Forwarding a web app's browser console over the Chrome DevTools Protocol.
///
/// A Flutter web app's `print()` goes to the browser console, not to Chrome's
/// process stdout, so the desktop approach of draining pipes finds nothing.
///
/// In DDC dev mode the dev tool already has a DWDS-backed VM service, and
/// `Stdout`/`Stderr` events on it carry the app's output — that path lives in
/// `run_command.dart` and is preferred, because it sees Dart's view of the
/// output. This file covers the case where there is no DWDS: WASM and plain
/// production JS builds, where CDP's `Runtime.consoleAPICalled` is the only
/// source available.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'app_log.dart';

/// Choose the WebSocket debugger URL for the app's page from a CDP
/// `/json` target listing.
///
/// Prefers the page serving [appUrl], falls back to the first `page` target,
/// and only then to any target at all — a browser window always has several
/// (extensions, service workers), and picking the wrong one yields a console
/// that never says anything.
///
/// Returns null when nothing usable is listed.
String? pickCdpPageTarget(List<dynamic> targets, {String? appUrl}) {
  if (targets.isEmpty) return null;

  final pages = targets
      .whereType<Map>()
      .where((t) => t['type'] == 'page')
      .toList();

  Map? chosen;
  if (appUrl != null) {
    chosen = pages.cast<Map?>().firstWhere(
          (t) => (t?['url'] as String? ?? '').startsWith(appUrl),
          orElse: () => null,
        );
  }
  chosen ??= pages.isNotEmpty
      ? pages.first
      : targets.whereType<Map>().firstOrNull;

  return chosen?['webSocketDebuggerUrl'] as String?;
}

/// Fetch the CDP target listing from a browser's debugging port.
Future<List<dynamic>> fetchCdpTargets(int cdpPort) async {
  final client = HttpClient();
  try {
    final req =
        await client.getUrl(Uri.parse('http://127.0.0.1:$cdpPort/json'));
    final resp = await req.close();
    final body = await resp.transform(utf8.decoder).join();
    return json.decode(body) as List<dynamic>;
  } finally {
    client.close();
  }
}

/// Resolve the app page's CDP WebSocket URL, or throw with a usable message.
Future<String> resolveCdpPageTarget(int cdpPort, {String? appUrl}) async {
  final targets = await fetchCdpTargets(cdpPort);
  final ws = pickCdpPageTarget(targets, appUrl: appUrl);
  if (ws == null) {
    throw StateError(
        'No CDP page target with a WebSocket debugger URL on port $cdpPort'
        '${appUrl == null ? '' : ' for $appUrl'}.');
  }
  return ws;
}

/// Render one CDP `RemoteObject` argument the way a console would show it.
String _renderArg(Map arg) {
  if (arg.containsKey('value')) return '${arg['value']}';
  final description = arg['description'];
  if (description is String) return description;
  return arg['type'] as String? ?? '';
}

/// CDP console message types that belong on an error channel.
const _errorConsoleTypes = {'error', 'warning', 'assert'};

/// Translate a single CDP notification into [logs] lines.
///
/// Handles `Runtime.consoleAPICalled` (every `console.*` call, which is where
/// a Dart web `print()` lands) and `Runtime.exceptionThrown` (uncaught
/// errors). Anything else — command responses, other domains' events — is
/// ignored. Malformed payloads are dropped rather than thrown: a console
/// forwarder must never be able to take down the run it is reporting on.
///
/// Exposed for testing.
void handleCdpConsoleMessage(Map<String, dynamic> message, AppLogStream logs) {
  void addLines(String text, {required bool isError}) {
    if (text.isEmpty) return;
    for (final line in const LineSplitter().convert(text)) {
      logs.add(line, isError: isError);
    }
  }

  try {
    switch (message['method']) {
      case 'Runtime.consoleAPICalled':
        final params = message['params'] as Map?;
        final args = params?['args'];
        if (args is! List || args.isEmpty) return;
        final type = params?['type'] as String? ?? 'log';
        final text =
            args.whereType<Map>().map(_renderArg).join(' ');
        addLines(text, isError: _errorConsoleTypes.contains(type));

      case 'Runtime.exceptionThrown':
        final details =
            (message['params'] as Map?)?['exceptionDetails'] as Map?;
        if (details == null) return;
        final description =
            (details['exception'] as Map?)?['description'] as String?;
        addLines(description ?? details['text'] as String? ?? '',
            isError: true);
    }
  } catch (_) {
    // A console line is never worth failing a run over.
  }
}

/// Streams a page's console output into an [AppLogStream] over CDP.
///
/// Reconnects when the page goes away: a web hot restart is a CDP page reload,
/// which drops the target and would otherwise silently end console forwarding
/// for the rest of the session.
class CdpConsoleClient {
  final int cdpPort;
  final String? appUrl;
  final AppLogStream logs;

  /// How long to wait before re-resolving a target after the socket drops.
  final Duration reconnectDelay;

  WebSocket? _socket;
  Timer? _reconnect;
  bool _closed = false;
  int _nextId = 1;

  CdpConsoleClient({
    required this.cdpPort,
    required this.logs,
    this.appUrl,
    this.reconnectDelay = const Duration(milliseconds: 500),
  });

  /// Connect and begin forwarding. Returns once the first connection is
  /// established; later reconnections happen in the background.
  Future<void> start() async {
    await _connect();
  }

  Future<void> _connect() async {
    if (_closed) return;
    final wsUrl = await resolveCdpPageTarget(cdpPort, appUrl: appUrl);
    final socket = await WebSocket.connect(wsUrl);
    if (_closed) {
      await socket.close();
      return;
    }
    _socket = socket;

    socket.listen(
      (data) {
        if (data is! String) return;
        try {
          handleCdpConsoleMessage(
              json.decode(data) as Map<String, dynamic>, logs);
        } on FormatException {
          // Not JSON; nothing to forward.
        }
      },
      onDone: _scheduleReconnect,
      onError: (_) => _scheduleReconnect(),
      cancelOnError: true,
    );

    // Runtime.enable starts consoleAPICalled/exceptionThrown notifications.
    socket.add(json.encode({'id': _nextId++, 'method': 'Runtime.enable'}));
  }

  void _scheduleReconnect() {
    if (_closed) return;
    _socket = null;
    // Held so [close] can cancel it: a pending timer keeps the isolate alive
    // until it fires, and a reconnect racing teardown would reopen a socket
    // nobody is going to close.
    _reconnect = Timer(reconnectDelay, () async {
      if (_closed) return;
      try {
        await _connect();
      } catch (_) {
        // The page may still be reloading; try again on the next tick rather
        // than giving up on console output for the rest of the run.
        _scheduleReconnect();
      }
    });
  }

  /// Stop forwarding and close the socket. Idempotent.
  Future<void> close() async {
    _closed = true;
    _reconnect?.cancel();
    _reconnect = null;
    final socket = _socket;
    _socket = null;
    await socket?.close();
  }
}

extension _FirstOrNull<T> on Iterable<T> {
  T? get firstOrNull => isEmpty ? null : first;
}
