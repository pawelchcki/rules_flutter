import 'dart:convert';

import 'package:flutter_bazel_dev_tool/app_log.dart';
import 'package:flutter_bazel_dev_tool/vm_service_logs.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service.dart';

import 'fakes.dart';

Event logEvent(String text) =>
    Event(kind: EventKind.kWriteEvent, timestamp: 0)
      ..bytes = base64.encode(utf8.encode(text));

void main() {
  group('decodeVmServiceLogEvent', () {
    test('decodes base64 payload', () {
      expect(decodeVmServiceLogEvent(logEvent('hello')), 'hello');
    });

    test('strips the single trailing newline the VM appends', () {
      expect(decodeVmServiceLogEvent(logEvent('hello\n')), 'hello');
    });

    test('keeps interior newlines', () {
      expect(decodeVmServiceLogEvent(logEvent('a\nb\n')), 'a\nb');
    });

    test('returns empty for an event with no bytes', () {
      expect(
        decodeVmServiceLogEvent(Event(kind: EventKind.kWriteEvent, timestamp: 0)),
        '',
      );
    });
  });

  group('forwardVmServiceLogs', () {
    test('subscribes to both the Stdout and Stderr streams', () async {
      final service = FakeVmService();
      await forwardVmServiceLogs(service, AppLogStream());

      expect(service.streamListens,
          containsAll([EventStreams.kStdout, EventStreams.kStderr]));
    });

    test('forwards stdout events as normal lines', () async {
      final service = FakeVmService();
      final logs = AppLogStream();
      await forwardVmServiceLogs(service, logs);

      service.emitStdoutEvent('flutter: from the browser\n');
      await pumpEventQueue();

      final line = logs.read(0).lines.single;
      expect(line.text, 'flutter: from the browser');
      expect(line.isError, isFalse);
    });

    test('forwards stderr events as error lines', () async {
      final service = FakeVmService();
      final logs = AppLogStream();
      await forwardVmServiceLogs(service, logs);

      service.emitStderrEvent('something failed\n');
      await pumpEventQueue();

      expect(logs.read(0).lines.single.isError, isTrue);
    });

    test('splits a multi-line payload into individual lines', () async {
      final service = FakeVmService();
      final logs = AppLogStream();
      await forwardVmServiceLogs(service, logs);

      service.emitStdoutEvent('one\ntwo\nthree\n');
      await pumpEventQueue();

      expect(logs.read(0).lines.map((l) => l.text), ['one', 'two', 'three']);
    });

    test('drops empty payloads instead of emitting blank lines', () async {
      final service = FakeVmService();
      final logs = AppLogStream();
      await forwardVmServiceLogs(service, logs);

      service.emitStdoutEvent('\n');
      await pumpEventQueue();

      expect(logs.read(0).lines, isEmpty);
    });

    test('tolerates an already-subscribed stream (reconnect case)', () async {
      final service = FakeVmService()
        ..alreadySubscribedStreams.add(EventStreams.kStdout);
      final logs = AppLogStream();

      await forwardVmServiceLogs(service, logs);

      // The subscription still works despite streamListen reporting 103.
      service.emitStdoutEvent('after reconnect\n');
      await pumpEventQueue();
      expect(logs.read(0).lines.single.text, 'after reconnect');
    });

    test('rethrows an unrelated streamListen failure', () async {
      final service = FakeVmService()
        ..failingStreams.add(EventStreams.kStdout);

      expect(
        () => forwardVmServiceLogs(service, AppLogStream()),
        throwsA(isA<RPCError>()),
      );
    });

    test('dispose stops forwarding', () async {
      final service = FakeVmService();
      final logs = AppLogStream();
      final forwarder = await forwardVmServiceLogs(service, logs);

      service.emitStdoutEvent('before\n');
      await pumpEventQueue();
      await forwarder.dispose();
      service.emitStdoutEvent('after\n');
      await pumpEventQueue();

      expect(logs.read(0).lines.map((l) => l.text), ['before']);
    });
  });
}
