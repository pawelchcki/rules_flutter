import 'dart:async';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/app_log.dart';
import 'package:flutter_bazel_dev_tool/cdp_console.dart';
import 'package:test/test.dart';

/// A local WebSocket server standing in for the browser's CDP endpoint, so a
/// test can hand the client a live connection and then take it away.
class _FakeCdpEndpoint {
  final HttpServer _server;
  final _connections = <Completer<WebSocket>>[];
  final _accepted = <WebSocket>[];

  _FakeCdpEndpoint._(this._server) {
    var next = 0;
    _server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      _accepted.add(socket);
      _slot(next++).complete(socket);
    });
  }

  static Future<_FakeCdpEndpoint> start() async =>
      _FakeCdpEndpoint._(await HttpServer.bind('127.0.0.1', 0));

  Completer<WebSocket> _slot(int index) {
    while (_connections.length <= index) {
      _connections.add(Completer<WebSocket>());
    }
    return _connections[index];
  }

  Future<WebSocket> connect() =>
      WebSocket.connect('ws://127.0.0.1:${_server.port}');

  /// Completes once the client has finished attaching to connection [index]:
  /// `Runtime.enable` is the first thing it sends.
  Future<void> attached(int index) async {
    await (await _slot(index).future).first;
  }

  /// Close the browser side, the way a page reload or a closed window does.
  Future<void> drop(int index) async => (await _slot(index).future).close();

  /// An upgraded socket is detached from its server, so closing the server is
  /// not enough: a still-open one keeps the test binary's event loop alive.
  Future<void> stop() async {
    await _server.close(force: true);
    for (final socket in _accepted) {
      await socket.close();
    }
  }
}

/// A `Runtime.consoleAPICalled` notification as Chrome sends it.
Map<String, dynamic> consoleEvent(
  String type,
  List<Map<String, dynamic>> args,
) =>
    {
      'method': 'Runtime.consoleAPICalled',
      'params': {'type': type, 'args': args},
    };

Map<String, dynamic> stringArg(String v) => {'type': 'string', 'value': v};

void main() {
  group('pickCdpPageTarget', () {
    final targets = [
      {'type': 'background_page', 'url': 'chrome-extension://x/bg.html',
       'webSocketDebuggerUrl': 'ws://bg'},
      {'type': 'page', 'url': 'about:blank', 'webSocketDebuggerUrl': 'ws://blank'},
      {'type': 'page', 'url': 'http://localhost:8080/index.html',
       'webSocketDebuggerUrl': 'ws://app'},
    ];

    test('prefers the page whose URL matches the app', () {
      expect(pickCdpPageTarget(targets, appUrl: 'http://localhost:8080'),
          'ws://app');
    });

    test('falls back to the first page target when the app URL is unknown', () {
      expect(pickCdpPageTarget(targets), 'ws://blank');
    });

    test('falls back to the first page target when no URL matches', () {
      expect(pickCdpPageTarget(targets, appUrl: 'http://localhost:9999'),
          'ws://blank');
    });

    test('ignores non-page targets when choosing a fallback', () {
      final onlyExtension = [
        {'type': 'background_page', 'url': 'chrome-extension://x/bg.html',
         'webSocketDebuggerUrl': 'ws://bg'},
      ];
      expect(pickCdpPageTarget(onlyExtension), 'ws://bg');
    });

    test('returns null when there are no targets at all', () {
      expect(pickCdpPageTarget(const []), isNull);
    });

    test('returns null when the chosen target exposes no debugger URL', () {
      expect(pickCdpPageTarget([
        {'type': 'page', 'url': 'about:blank'},
      ]), isNull);
    });
  });

  group('handleCdpConsoleMessage', () {
    late AppLogStream logs;
    setUp(() => logs = AppLogStream());

    test('forwards a console.log call', () {
      handleCdpConsoleMessage(
          consoleEvent('log', [stringArg('hello from the page')]), logs);
      final line = logs.read(0).lines.single;
      expect(line.text, 'hello from the page');
      expect(line.isError, isFalse);
    });

    test('joins multiple arguments with a space, like the browser console', () {
      handleCdpConsoleMessage(
          consoleEvent('log', [stringArg('a'), stringArg('b')]), logs);
      expect(logs.read(0).lines.single.text, 'a b');
    });

    test('flags console.error as an error line', () {
      handleCdpConsoleMessage(
          consoleEvent('error', [stringArg('it broke')]), logs);
      expect(logs.read(0).lines.single.isError, isTrue);
    });

    test('flags console.warning as an error line', () {
      handleCdpConsoleMessage(
          consoleEvent('warning', [stringArg('careful')]), logs);
      expect(logs.read(0).lines.single.isError, isTrue);
    });

    test('renders non-string arguments from their description', () {
      handleCdpConsoleMessage({
        'method': 'Runtime.consoleAPICalled',
        'params': {
          'type': 'log',
          'args': [
            {'type': 'object', 'description': 'Instance of MyClass'},
          ],
        },
      }, logs);
      expect(logs.read(0).lines.single.text, 'Instance of MyClass');
    });

    test('renders numeric and boolean values', () {
      handleCdpConsoleMessage({
        'method': 'Runtime.consoleAPICalled',
        'params': {
          'type': 'log',
          'args': [
            {'type': 'number', 'value': 42},
            {'type': 'boolean', 'value': true},
          ],
        },
      }, logs);
      expect(logs.read(0).lines.single.text, '42 true');
    });

    test('forwards an uncaught exception as an error line', () {
      handleCdpConsoleMessage({
        'method': 'Runtime.exceptionThrown',
        'params': {
          'exceptionDetails': {
            'text': 'Uncaught',
            'exception': {'description': 'Error: boom\n  at main'},
          },
        },
      }, logs);
      // A stack trace keeps its line structure rather than arriving as one
      // unreadable blob.
      final lines = logs.read(0).lines;
      expect(lines.map((l) => l.text), ['Error: boom', '  at main']);
      expect(lines.every((l) => l.isError), isTrue);
    });

    test('falls back to exceptionDetails.text when there is no description', () {
      handleCdpConsoleMessage({
        'method': 'Runtime.exceptionThrown',
        'params': {
          'exceptionDetails': {'text': 'Uncaught SyntaxError'},
        },
      }, logs);
      expect(logs.read(0).lines.single.text, 'Uncaught SyntaxError');
    });

    test('splits an embedded multi-line message into separate lines', () {
      handleCdpConsoleMessage(
          consoleEvent('log', [stringArg('first\nsecond')]), logs);
      expect(logs.read(0).lines.map((l) => l.text), ['first', 'second']);
    });

    test('ignores unrelated CDP methods', () {
      handleCdpConsoleMessage({'method': 'Page.frameNavigated'}, logs);
      handleCdpConsoleMessage({'id': 1, 'result': {}}, logs);
      expect(logs.read(0).lines, isEmpty);
    });

    test('ignores a console call carrying no arguments', () {
      handleCdpConsoleMessage(consoleEvent('log', const []), logs);
      expect(logs.read(0).lines, isEmpty);
    });

    test('a malformed event does not throw', () {
      expect(
        () => handleCdpConsoleMessage({
          'method': 'Runtime.consoleAPICalled',
          'params': {'type': 'log', 'args': 'not-a-list'},
        }, logs),
        returnsNormally,
      );
      expect(logs.read(0).lines, isEmpty);
    });
  });

  group('CdpConsoleClient reconnect', () {
    late _FakeCdpEndpoint endpoint;

    setUp(() async {
      endpoint = await _FakeCdpEndpoint.start();
      addTearDown(endpoint.stop);
    });

    test('backs off exponentially and gives up when nothing comes back',
        () async {
      final delays = <Duration>[];
      final warnings = <String>[];
      final gaveUp = Completer<void>();
      var opens = 0;

      final client = CdpConsoleClient(
        cdpPort: 0,
        logs: AppLogStream(),
        reconnectDelay: const Duration(milliseconds: 100),
        maxReconnectDelay: const Duration(milliseconds: 400),
        reconnectBudget: const Duration(seconds: 1),
        // Connected once, then the browser is gone for the rest of the run.
        openSocket: (_, __) async {
          if (opens++ > 0) throw const SocketException('connection refused');
          return endpoint.connect();
        },
        // The requested delay is the assertion; the wall clock is not.
        scheduleTimer: (delay, callback) {
          delays.add(delay);
          return Timer(Duration.zero, callback);
        },
        warn: (message) {
          warnings.add(message);
          if (!gaveUp.isCompleted) gaveUp.complete();
        },
      );
      addTearDown(client.close);

      await client.start();
      await endpoint.drop(0);
      await gaveUp.future;

      expect(delays, const [
        Duration(milliseconds: 100),
        Duration(milliseconds: 200),
        Duration(milliseconds: 400),
        Duration(milliseconds: 400),
      ]);
      expect(opens, delays.length + 1);
      expect(warnings.single, contains('console forwarding stopped'));
      expect(warnings.single, contains('connection refused'));
    });

    test('resets the backoff after reattaching to a reloaded page', () async {
      final delays = <Duration>[];

      final client = CdpConsoleClient(
        cdpPort: 0,
        logs: AppLogStream(),
        reconnectDelay: const Duration(milliseconds: 100),
        openSocket: (_, __) => endpoint.connect(),
        scheduleTimer: (delay, callback) {
          delays.add(delay);
          return Timer(Duration.zero, callback);
        },
        warn: (message) => fail('unexpected give-up: $message'),
      );
      addTearDown(client.close);

      await client.start();
      await endpoint.drop(0);
      await endpoint.attached(1);
      await endpoint.drop(1);
      await endpoint.attached(2);

      expect(delays, const [
        Duration(milliseconds: 100),
        Duration(milliseconds: 100),
      ]);
    });

    test('close cancels a pending reconnect and is idempotent', () async {
      Timer? scheduled;
      final pending = Completer<void>();
      var opens = 0;

      final client = CdpConsoleClient(
        cdpPort: 0,
        logs: AppLogStream(),
        // Long enough that only cancellation, not expiry, can end the wait.
        reconnectDelay: const Duration(minutes: 5),
        openSocket: (_, __) {
          opens++;
          return endpoint.connect();
        },
        scheduleTimer: (delay, callback) {
          final timer = Timer(delay, callback);
          scheduled = timer;
          if (!pending.isCompleted) pending.complete();
          return timer;
        },
        warn: (message) => fail('unexpected give-up: $message'),
      );

      await client.start();
      await endpoint.drop(0);
      await pending.future;

      await client.close();
      await client.close();

      expect(scheduled!.isActive, isFalse);
      expect(opens, 1);
    });
  });
}
