import 'package:flutter_bazel_dev_tool/app_log.dart';
import 'package:flutter_bazel_dev_tool/cdp_console.dart';
import 'package:test/test.dart';

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
}
