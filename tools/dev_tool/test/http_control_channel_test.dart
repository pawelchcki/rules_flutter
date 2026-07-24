import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/command_runner.dart';
import 'package:flutter_bazel_dev_tool/device.dart';
import 'package:flutter_bazel_dev_tool/http_control_channel.dart';
import 'package:flutter_bazel_dev_tool/session.dart';
import 'package:test/test.dart';

void main() {
  group('HttpControlChannel', () {
    late CommandRunner commandRunner;
    late HttpControlChannel channel;
    late HttpClient client;
    final sessions = <String, DeviceSession>{};

    setUp(() async {
      commandRunner = CommandRunner();
      commandRunner.register('test.echo', (params) async {
        return {'echo': params['msg']};
      });
      commandRunner.register('test.fail', (_) async {
        throw StateError('handler error');
      });

      sessions.clear();

      channel = HttpControlChannel(
        commandRunner: commandRunner,
        findSession: (appId) => sessions[appId],
        token: 'test-token-abc',
      );
      await channel.start();
      client = HttpClient();
    });

    tearDown(() async {
      client.close();
      await channel.stop();
    });

    Uri _uri(String path, {bool withToken = true}) {
      final base = channel.uri;
      final query = withToken ? 'token=test-token-abc' : '';
      return base.replace(path: path, query: query);
    }

    Future<HttpClientResponse> _get(String path,
        {bool withToken = true}) async {
      final request = await client.getUrl(_uri(path, withToken: withToken));
      return request.close();
    }

    Future<(HttpClientResponse, String)> _post(
        String path, Map<String, dynamic> body,
        {bool withToken = true}) async {
      final request = await client.postUrl(_uri(path, withToken: withToken));
      request.headers.contentType = ContentType.json;
      request.write(json.encode(body));
      final response = await request.close();
      final responseBody = await utf8.decoder.bind(response).join();
      return (response, responseBody);
    }

    group('http upgrade', () {
      test('rejects an Upgrade request with 426 before reading the body',
          () async {
        // Mimic an HTTP/2 cleartext (h2c) upgrade attempt: Dart's HttpServer
        // would otherwise silently drop the request body and hang the POST.
        final request = await client.postUrl(_uri('/command'));
        request.headers.contentType = ContentType.json;
        request.headers.set(HttpHeaders.connectionHeader, 'Upgrade');
        request.headers.set(HttpHeaders.upgradeHeader, 'h2c');
        request.write(json.encode({'method': 'test.echo'}));
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        expect(response.statusCode, HttpStatus.upgradeRequired);
        expect(body, contains('HTTP/1.1 only'));
      });
    });

    group('auth', () {
      test('returns 401 without token', () async {
        final response = await _get('/command', withToken: false);
        expect(response.statusCode, HttpStatus.unauthorized);
        await response.drain<void>();
      });

      test('returns 401 with wrong token', () async {
        final request = await client.getUrl(
          channel.uri.replace(path: '/command', query: 'token=wrong'),
        );
        final response = await request.close();
        expect(response.statusCode, HttpStatus.unauthorized);
        await response.drain<void>();
      });

      test('accepts correct token', () async {
        final (response, body) = await _post('/command', {
          'method': 'test.echo',
          'params': {'msg': 'hi'},
        });
        expect(response.statusCode, HttpStatus.ok);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['result']['echo'], 'hi');
      });
    });

    group('POST /command', () {
      test('executes valid command', () async {
        final (response, body) = await _post('/command', {
          'method': 'test.echo',
          'params': {'msg': 'hello'},
        });
        expect(response.statusCode, HttpStatus.ok);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['result']['echo'], 'hello');
      });

      test('returns 404 for unknown method', () async {
        final (response, body) = await _post('/command', {
          'method': 'nonexistent',
        });
        expect(response.statusCode, HttpStatus.notFound);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['error'], contains('Unknown command'));
      });

      test('returns 400 for malformed JSON', () async {
        final request =
            await client.postUrl(_uri('/command'));
        request.headers.contentType = ContentType.json;
        request.write('not json {{{');
        final response = await request.close();
        expect(response.statusCode, HttpStatus.badRequest);
        await response.drain<void>();
      });

      test('returns 400 when method field is missing', () async {
        final (response, body) = await _post('/command', {
          'params': {'msg': 'hi'},
        });
        expect(response.statusCode, HttpStatus.badRequest);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['error'], contains('Missing "method" field'));
      });

      test('returns 500 when handler throws', () async {
        final (response, body) = await _post('/command', {
          'method': 'test.fail',
        });
        expect(response.statusCode, HttpStatus.internalServerError);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['error'], contains('handler error'));
      });

      test('defaults params to empty map', () async {
        final (response, body) = await _post('/command', {
          'method': 'test.echo',
        });
        expect(response.statusCode, HttpStatus.ok);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['result']['echo'], isNull);
      });
    });

    group('GET /sessions/{appId}/screenshot/flutter', () {
      test('returns 404 for unknown appId', () async {
        final response =
            await _get('/sessions/unknown/screenshot/flutter');
        expect(response.statusCode, HttpStatus.notFound);
        await response.drain<void>();
      });
    });

    group('GET /sessions/{appId}/screenshot/native', () {
      test('returns 404 for unknown appId', () async {
        final response =
            await _get('/sessions/unknown/screenshot/native');
        expect(response.statusCode, HttpStatus.notFound);
        await response.drain<void>();
      });
    });

    group('routing', () {
      test('returns 404 for unknown paths', () async {
        final response = await _get('/unknown/path');
        expect(response.statusCode, HttpStatus.notFound);
        await response.drain<void>();
      });
    });

    group('lifecycle', () {
      test('token is 64 hex chars when auto-generated', () async {
        final autoChannel = HttpControlChannel(
          commandRunner: commandRunner,
          findSession: (_) => null,
        );
        expect(autoChannel.token.length, 64);
        expect(RegExp(r'^[0-9a-f]+$').hasMatch(autoChannel.token), isTrue);
      });

      test('uri throws before start', () {
        final notStarted = HttpControlChannel(
          commandRunner: commandRunner,
          findSession: (_) => null,
        );
        expect(() => notStarted.uri, throwsA(isA<StateError>()));
      });

      test('stop is idempotent', () async {
        await channel.stop();
        await channel.stop(); // Should not throw.
      });

      test('stop during an in-flight command lets the response flush intact',
          () async {
        // Models `app.stop`: the command's own side effects lead to the
        // channel being stopped while the request that triggered them is
        // still awaiting its response. The client must still receive the
        // complete JSON response, not a torn-down connection.
        final handlerEntered = Completer<void>();
        final handlerResume = Completer<void>();
        commandRunner.register('test.slowStop', (_) async {
          handlerEntered.complete();
          await handlerResume.future;
          return {'message': 'stopped'};
        });

        final responseFuture = _post('/command', {'method': 'test.slowStop'});
        await handlerEntered.future;

        final stopFuture = channel.stop();
        handlerResume.complete();

        final (response, body) = await responseFuture;
        expect(response.statusCode, HttpStatus.ok);
        final parsed = json.decode(body) as Map<String, dynamic>;
        expect(parsed['result']['message'], 'stopped');

        await stopFuture;
      });

      test('stop refuses new connections but drains in-flight ones', () async {
        final handlerEntered = Completer<void>();
        final handlerResume = Completer<void>();
        commandRunner.register('test.slowStop', (_) async {
          handlerEntered.complete();
          await handlerResume.future;
          return {'message': 'stopped'};
        });

        final uri = channel.uri;
        final responseFuture = _post('/command', {'method': 'test.slowStop'});
        await handlerEntered.future;

        final stopFuture = channel.stop();

        // New connections must be refused once stop() has begun.
        final freshClient = HttpClient()
          ..connectionTimeout = const Duration(seconds: 5);
        await expectLater(
          freshClient
              .postUrl(uri.replace(path: '/command', query: 'token=test-token-abc')),
          throwsA(isA<SocketException>()),
        );
        freshClient.close(force: true);

        handlerResume.complete();
        final (response, _) = await responseFuture;
        expect(response.statusCode, HttpStatus.ok);
        await stopFuture;
      });
    });

    group('GET /sessions/{appId}/logs', () {
      late AppLogStream logs;

      /// Register a session whose app has printed [count] numbered lines.
      void seedSession(String appId, {int count = 0, int capacity = 2000}) {
        logs = AppLogStream(capacity: capacity);
        for (var i = 0; i < count; i++) {
          logs.add('line$i');
        }
        sessions[appId] = DeviceSession(
          device: _StubDevice(),
          appInstance: AppInstance(process: _StubProcess(), logs: logs),
          vmClient: null,
          appId: appId,
        );
      }

      Future<Map<String, dynamic>> getLogs(String query) async {
        final request = await client.getUrl(channel.uri.replace(
          path: '/sessions/app1/logs',
          query: 'token=test-token-abc${query.isEmpty ? '' : '&$query'}',
        ));
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();
        expect(response.statusCode, HttpStatus.ok, reason: body);
        return json.decode(body) as Map<String, dynamic>;
      }

      List<String> textsOf(Map<String, dynamic> page) => [
            for (final l in page['lines'] as List) (l as Map)['t'] as String,
          ];

      test('with no cursor, tails the most recent lines', () async {
        seedSession('app1', count: 500);
        final page = await getLogs('');

        // The default is a tail, so an agent arriving with no cursor sees what
        // just happened rather than the start of the run.
        expect(textsOf(page).last, 'line499');
        expect(textsOf(page).length, lessThan(500));
        expect(page['nextCursor'], 500);
      });

      test('since=-N returns the last N lines', () async {
        seedSession('app1', count: 20);
        expect(textsOf(await getLogs('since=-3')),
            ['line17', 'line18', 'line19']);
      });

      test('since=0 reads from the start of the buffer', () async {
        seedSession('app1', count: 5);
        expect(textsOf(await getLogs('since=0')),
            ['line0', 'line1', 'line2', 'line3', 'line4']);
      });

      test('polling with nextCursor neither overlaps nor gaps', () async {
        seedSession('app1', count: 3);
        final first = await getLogs('since=0');
        expect(textsOf(first), ['line0', 'line1', 'line2']);

        logs.add('line3');
        logs.add('line4');
        final second = await getLogs('since=${first['nextCursor']}');

        expect(textsOf(second), ['line3', 'line4']);
        expect(second['nextCursor'], 5);
      });

      test('polling with nothing new returns an empty page, not an error',
          () async {
        seedSession('app1', count: 2);
        final page = await getLogs('since=2');
        expect(page['lines'], isEmpty);
        expect(page['nextCursor'], 2);
      });

      test('reports missed lines when the cursor has been evicted', () async {
        seedSession('app1', count: 10, capacity: 3);
        final page = await getLogs('since=0');

        expect(textsOf(page), ['line7', 'line8', 'line9']);
        expect(page['missed'], 7,
            reason: 'a poller must learn it has a gap rather than read a '
                'short page as if it were complete');
        expect(page['dropped'], 7);
      });

      test('a cursor still inside the buffer reports no gap', () async {
        seedSession('app1', count: 10, capacity: 5);
        expect((await getLogs('since=7'))['missed'], 0);
      });

      test('limit caps the page', () async {
        seedSession('app1', count: 20);
        final page = await getLogs('since=0&limit=4');
        expect(textsOf(page), ['line0', 'line1', 'line2', 'line3']);
        expect(page['nextCursor'], 4);
      });

      test('an oversized limit is clamped rather than honoured', () async {
        seedSession('app1', count: 900);
        final page = await getLogs('since=0&limit=100000');
        expect((page['lines'] as List).length, lessThanOrEqualTo(500));
      });

      test('carries the error flag per line', () async {
        seedSession('app1');
        logs.add('fine');
        logs.add('broken', isError: true);

        final lines = (await getLogs('since=0'))['lines'] as List;
        expect((lines[0] as Map)['err'], isFalse);
        expect((lines[1] as Map)['err'], isTrue);
      });

      test('reports closed once the app output source has ended', () async {
        seedSession('app1', count: 1);
        expect((await getLogs('since=0'))['closed'], isFalse);

        await logs.close();

        final page = await getLogs('since=0');
        expect(page['closed'], isTrue,
            reason: 'a poller needs to know when to stop');
        expect(textsOf(page), ['line0'],
            reason: "an exited app's final output must still be readable");
      });

      test('rejects a non-numeric since with 400', () async {
        seedSession('app1', count: 3);
        final request = await client.getUrl(channel.uri.replace(
          path: '/sessions/app1/logs',
          query: 'token=test-token-abc&since=abc',
        ));
        final response = await request.close();
        final body = await utf8.decoder.bind(response).join();

        expect(response.statusCode, HttpStatus.badRequest);
        expect(body, contains('since'),
            reason: 'silently serving the default would make a typo look like '
                'a working poll loop');
      });

      test('rejects a non-positive limit with 400', () async {
        seedSession('app1', count: 3);
        final request = await client.getUrl(channel.uri.replace(
          path: '/sessions/app1/logs',
          query: 'token=test-token-abc&limit=0',
        ));
        expect((await request.close()).statusCode, HttpStatus.badRequest);
      });

      test('404s an unknown appId', () async {
        final response = await _get('/sessions/nope/logs');
        expect(response.statusCode, HttpStatus.notFound);
      });

      test('401s without a valid token', () async {
        seedSession('app1', count: 1);
        final response = await _get('/sessions/app1/logs', withToken: false);
        expect(response.statusCode, HttpStatus.unauthorized);
      });
    });
  });
}

/// Minimal [Device] for session fixtures — the logs endpoint never touches it.
class _StubDevice extends Device {
  @override
  String get name => 'stub';

  @override
  Future<AppInstance> launch(String appPath, {AppLogListener? onLog}) =>
      throw UnimplementedError();

  @override
  Future<void> stop(AppInstance instance) async {}
}

class _StubProcess implements Process {
  @override
  Stream<List<int>> get stdout => const Stream.empty();
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => throw UnimplementedError();
  @override
  int get pid => -1;
  @override
  Future<int> get exitCode => Completer<int>().future;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) => false;
}
