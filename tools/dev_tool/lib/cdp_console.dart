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

/// Open the socket for the app page's CDP endpoint.
Future<WebSocket> _openPageSocket(int cdpPort, String? appUrl) async =>
    WebSocket.connect(await resolveCdpPageTarget(cdpPort, appUrl: appUrl));

/// Streams a page's console output into an [AppLogStream] over CDP.
///
/// Reconnects when the page goes away: a web hot restart is a CDP page reload,
/// which drops the target and would otherwise silently end console forwarding
/// for the rest of the session. The other reason a target disappears is that
/// the browser is gone for good, which no amount of retrying fixes, so the
/// reconnect backs off and eventually gives up out loud.
class CdpConsoleClient {
  final int cdpPort;
  final String? appUrl;
  final AppLogStream logs;

  /// How long to wait before re-resolving a target after the socket drops.
  /// Each further attempt in the same outage waits twice as long.
  final Duration reconnectDelay;

  /// Ceiling on the backoff: everything the page prints before the client is
  /// back is output nobody sees, so a reload must not end up behind a long
  /// wait.
  final Duration maxReconnectDelay;

  /// How much waiting one outage gets before the client stops trying.
  final Duration reconnectBudget;

  /// Opens the CDP socket. Injectable so tests can drive the reconnect loop
  /// without a browser.
  final Future<WebSocket> Function(int cdpPort, String? appUrl) _open;

  /// Starts the timer for the next attempt. Injectable so tests can read the
  /// backoff off the schedule instead of waiting through it.
  final Timer Function(Duration delay, void Function() callback) _schedule;

  /// Where the give-up warning goes.
  final void Function(String message) _warn;

  WebSocket? _socket;
  Timer? _reconnect;
  bool _closed = false;
  int _nextId = 1;

  /// Backoff state for the current outage, reset once a socket is live again
  /// so that a session's tenth hot restart gets the same budget as its first.
  Duration _nextDelay;
  Duration _waited = Duration.zero;
  Object? _lastError;

  CdpConsoleClient({
    required this.cdpPort,
    required this.logs,
    this.appUrl,
    this.reconnectDelay = const Duration(milliseconds: 500),
    this.maxReconnectDelay = const Duration(seconds: 2),
    this.reconnectBudget = const Duration(seconds: 15),
    Future<WebSocket> Function(int cdpPort, String? appUrl)? openSocket,
    Timer Function(Duration delay, void Function() callback)? scheduleTimer,
    void Function(String message)? warn,
  })  : _nextDelay = reconnectDelay,
        _open = openSocket ?? _openPageSocket,
        _schedule = scheduleTimer ?? Timer.new,
        _warn = warn ?? ((String message) => stderr.writeln(message));

  /// Connect and begin forwarding. Returns once the first connection is
  /// established; later reconnections happen in the background.
  Future<void> start() async {
    await _connect();
  }

  Future<void> _connect() async {
    if (_closed) return;
    final socket = await _open(cdpPort, appUrl);
    if (_closed) {
      await socket.close();
      return;
    }
    _socket = socket;
    _nextDelay = reconnectDelay;
    _waited = Duration.zero;
    _lastError = null;

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
    if (_waited >= reconnectBudget) {
      _giveUp();
      return;
    }
    final delay = _nextDelay;
    _waited += delay;
    final doubled = delay * 2;
    _nextDelay = doubled > maxReconnectDelay ? maxReconnectDelay : doubled;
    // Held so [close] can cancel it: a pending timer keeps the isolate alive
    // until it fires, and a reconnect racing teardown would reopen a socket
    // nobody is going to close.
    _reconnect = _schedule(delay, () async {
      if (_closed) return;
      try {
        await _connect();
      } catch (e) {
        // The page may still be reloading; try again, further out each time.
        _lastError = e;
        _scheduleReconnect();
      }
    });
  }

  /// Stop reconnecting, and say so: a console that quietly stops forwarding is
  /// indistinguishable from an app that stopped printing.
  void _giveUp() {
    _reconnect = null;
    _warn('Warning: browser console forwarding stopped — no CDP page target '
        'came back on port $cdpPort within ${reconnectBudget.inSeconds}s'
        '${_lastError == null ? '' : ' ($_lastError)'}. The browser has '
        'probably exited; app output will not appear for the rest of this '
        'run.');
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
