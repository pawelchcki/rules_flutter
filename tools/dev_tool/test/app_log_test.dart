import 'package:flutter_bazel_dev_tool/app_log.dart';
import 'package:test/test.dart';

import 'fakes.dart';

void main() {
  group('AppLogStream replay', () {
    test('replays lines added before the first listener attached', () async {
      final s = AppLogStream();
      s.add('one');
      s.add('two');

      final seen = <String>[];
      s.lines.listen((l) => seen.add(l.text));
      await pumpEventQueue();

      expect(seen, ['one', 'two']);
    });

    test('replayed lines keep their original order and indices', () async {
      final s = AppLogStream();
      for (var i = 0; i < 5; i++) {
        s.add('line$i');
      }

      final seen = <AppLogLine>[];
      s.lines.listen(seen.add);
      await pumpEventQueue();

      expect(seen.map((l) => l.text), ['line0', 'line1', 'line2', 'line3', 'line4']);
      expect(seen.map((l) => l.index), [0, 1, 2, 3, 4]);
    });

    test('a listener sees replayed lines then live ones, without gaps', () async {
      final s = AppLogStream();
      s.add('before');

      final seen = <String>[];
      s.lines.listen((l) => seen.add(l.text));
      await pumpEventQueue();
      s.add('after');
      await pumpEventQueue();

      expect(seen, ['before', 'after']);
    });

    test('a late second listener also gets the full replay', () async {
      final s = AppLogStream();
      s.add('a');

      final first = <String>[];
      s.lines.listen((l) => first.add(l.text));
      await pumpEventQueue();

      s.add('b');
      await pumpEventQueue();

      final second = <String>[];
      s.lines.listen((l) => second.add(l.text));
      await pumpEventQueue();

      s.add('c');
      await pumpEventQueue();

      expect(first, ['a', 'b', 'c']);
      expect(second, ['a', 'b', 'c']);
    });

    test('does not deliver a line twice to a listener attached mid-add',
        () async {
      final s = AppLogStream();
      s.add('x');
      final seen = <String>[];
      s.lines.listen((l) => seen.add(l.text));
      await pumpEventQueue();
      expect(seen, ['x']);
    });
  });

  group('AppLogStream isError', () {
    test('carries the stderr flag through replay and live delivery', () async {
      final s = AppLogStream();
      s.add('out', isError: false);
      s.add('err', isError: true);

      final seen = <AppLogLine>[];
      s.lines.listen(seen.add);
      await pumpEventQueue();

      expect(seen.map((l) => l.isError), [false, true]);
    });
  });

  group('AppLogStream ring buffer', () {
    test('evicts oldest lines past capacity and counts them as dropped', () {
      final s = AppLogStream(capacity: 3);
      for (var i = 0; i < 5; i++) {
        s.add('line$i');
      }

      expect(s.dropped, 2);
      expect(s.oldestCursor, 2);
      expect(s.nextCursor, 5);
      expect(s.read(0).lines.map((l) => l.text), ['line2', 'line3', 'line4']);
    });

    test('dropped stays zero while under capacity', () {
      final s = AppLogStream(capacity: 10);
      s.add('a');
      s.add('b');
      expect(s.dropped, 0);
      expect(s.oldestCursor, 0);
    });

    test('a listener attached after eviction replays only retained lines', () async {
      final s = AppLogStream(capacity: 2);
      for (var i = 0; i < 4; i++) {
        s.add('line$i');
      }

      final seen = <String>[];
      s.lines.listen((l) => seen.add(l.text));
      await pumpEventQueue();

      expect(seen, ['line2', 'line3']);
    });
  });

  group('AppLogStream.read cursors', () {
    test('read(0) on a fresh stream returns everything from the start', () {
      final s = AppLogStream();
      s.add('a');
      s.add('b');

      final page = s.read(0);
      expect(page.lines.map((l) => l.text), ['a', 'b']);
      expect(page.nextCursor, 2);
      expect(page.missed, 0);
    });

    test('read(n) resumes at n and excludes earlier lines', () {
      final s = AppLogStream();
      for (var i = 0; i < 4; i++) {
        s.add('line$i');
      }

      final page = s.read(2);
      expect(page.lines.map((l) => l.text), ['line2', 'line3']);
      expect(page.nextCursor, 4);
    });

    test('two sequential polls neither overlap nor gap', () {
      final s = AppLogStream();
      s.add('a');
      s.add('b');

      final first = s.read(0);
      s.add('c');
      s.add('d');
      final second = s.read(first.nextCursor);

      expect(first.lines.map((l) => l.text), ['a', 'b']);
      expect(second.lines.map((l) => l.text), ['c', 'd']);
      expect(second.nextCursor, 4);
    });

    test('read at nextCursor with nothing new returns an empty page', () {
      final s = AppLogStream();
      s.add('a');

      final page = s.read(s.nextCursor);
      expect(page.lines, isEmpty);
      expect(page.nextCursor, 1);
      expect(page.missed, 0);
    });

    test('read past nextCursor returns empty rather than throwing', () {
      final s = AppLogStream();
      s.add('a');

      final page = s.read(99);
      expect(page.lines, isEmpty);
      expect(page.nextCursor, 1);
    });

    test('read(0) on an empty stream is empty', () {
      final s = AppLogStream();
      final page = s.read(0);
      expect(page.lines, isEmpty);
      expect(page.nextCursor, 0);
      expect(page.missed, 0);
    });
  });

  group('AppLogStream.read tail (negative cursor)', () {
    test('read(-n) returns the last n lines', () {
      final s = AppLogStream();
      for (var i = 0; i < 10; i++) {
        s.add('line$i');
      }

      final page = s.read(-3);
      expect(page.lines.map((l) => l.text), ['line7', 'line8', 'line9']);
      expect(page.nextCursor, 10);
      expect(page.missed, 0);
    });

    test('read(-n) with fewer lines than n returns all of them, not an error',
        () {
      final s = AppLogStream();
      s.add('a');
      s.add('b');
      s.add('c');

      final page = s.read(-10);
      expect(page.lines.map((l) => l.text), ['a', 'b', 'c']);
      expect(page.nextCursor, 3);
      expect(page.missed, 0);
    });

    test('read(-n) on an empty stream is empty', () {
      final s = AppLogStream();
      final page = s.read(-50);
      expect(page.lines, isEmpty);
      expect(page.nextCursor, 0);
    });

    test('tailing never reports missed — the caller asked for the tail', () {
      final s = AppLogStream(capacity: 3);
      for (var i = 0; i < 10; i++) {
        s.add('line$i');
      }

      final page = s.read(-2);
      expect(page.lines.map((l) => l.text), ['line8', 'line9']);
      expect(page.missed, 0);
      // ...even though the stream as a whole has dropped lines.
      expect(s.dropped, 7);
    });

    test('read(-1) returns just the most recent line', () {
      final s = AppLogStream();
      s.add('old');
      s.add('newest');

      expect(s.read(-1).lines.single.text, 'newest');
    });
  });

  group('AppLogStream.read eviction reporting', () {
    test('a cursor older than the buffer clamps and reports missed', () {
      final s = AppLogStream(capacity: 3);
      for (var i = 0; i < 6; i++) {
        s.add('line$i');
      }

      // Lines 0-2 were evicted; asking from 0 should surface the gap.
      final page = s.read(0);
      expect(page.lines.map((l) => l.text), ['line3', 'line4', 'line5']);
      expect(page.missed, 3);
      expect(page.nextCursor, 6);
    });

    test('missed counts only the gap, not everything ever dropped', () {
      final s = AppLogStream(capacity: 3);
      for (var i = 0; i < 6; i++) {
        s.add('line$i');
      }

      // Cursor 2 is one line behind the oldest retained (3).
      final page = s.read(2);
      expect(page.missed, 1);
      expect(page.lines.map((l) => l.text), ['line3', 'line4', 'line5']);
    });

    test('a cursor still inside the buffer reports no gap', () {
      final s = AppLogStream(capacity: 3);
      for (var i = 0; i < 6; i++) {
        s.add('line$i');
      }

      expect(s.read(4).missed, 0);
    });
  });

  group('AppLogStream.read limit', () {
    test('limit caps the page and nextCursor points at the remainder', () {
      final s = AppLogStream();
      for (var i = 0; i < 10; i++) {
        s.add('line$i');
      }

      final page = s.read(0, limit: 4);
      expect(page.lines.map((l) => l.text),
          ['line0', 'line1', 'line2', 'line3']);
      expect(page.nextCursor, 4);

      final next = s.read(page.nextCursor, limit: 4);
      expect(next.lines.map((l) => l.text),
          ['line4', 'line5', 'line6', 'line7']);
    });

    test('limit applies to tail reads too, keeping the newest lines', () {
      final s = AppLogStream();
      for (var i = 0; i < 10; i++) {
        s.add('line$i');
      }

      // Ask for the last 6 but cap at 2: the cap must not hand back the
      // oldest of the tail window and call it "the tail".
      final page = s.read(-6, limit: 2);
      expect(page.lines.map((l) => l.text), ['line8', 'line9']);
      expect(page.nextCursor, 10);
    });

    test('a huge limit is clamped rather than honoured verbatim', () {
      final s = AppLogStream();
      for (var i = 0; i < 10; i++) {
        s.add('line$i');
      }

      final page = s.read(0, limit: 1000000);
      expect(page.lines, hasLength(10));
    });
  });

  group('AppLogStream.close', () {
    test('completes subscribers', () async {
      final s = AppLogStream();
      var done = false;
      s.lines.listen((_) {}, onDone: () => done = true);
      await pumpEventQueue();

      await s.close();
      await pumpEventQueue();

      expect(done, isTrue);
    });

    test('a listener attached after close still gets the replay, then done',
        () async {
      final s = AppLogStream();
      s.add('a');
      await s.close();

      final seen = <String>[];
      var done = false;
      s.lines.listen((l) => seen.add(l.text), onDone: () => done = true);
      await pumpEventQueue();

      expect(seen, ['a']);
      expect(done, isTrue);
    });

    test('add after close is ignored rather than throwing', () async {
      final s = AppLogStream();
      await s.close();
      s.add('late');
      expect(s.read(0).lines, isEmpty);
    });

    test('close is idempotent', () async {
      final s = AppLogStream();
      await s.close();
      await s.close();
    });
  });

  group('pumpProcessLines', () {
    test('forwards stdout lines for the process lifetime', () async {
      final p = FakeProcess();
      final s = AppLogStream();
      pumpProcessLines(p, s);

      p.emitStdout('first');
      await pumpEventQueue();
      p.emitStdout('second');
      await pumpEventQueue();

      expect(s.read(0).lines.map((l) => l.text), ['first', 'second']);
    });

    test('marks stderr lines as errors', () async {
      final p = FakeProcess();
      final s = AppLogStream();
      pumpProcessLines(p, s);

      p.emitStderr('boom\n');
      await pumpEventQueue();

      final line = s.read(0).lines.single;
      expect(line.text, 'boom');
      expect(line.isError, isTrue);
    });

    test('keeps forwarding after a VM-service announcement — the regression',
        () async {
      final p = FakeProcess();
      final s = AppLogStream();
      pumpProcessLines(p, s);

      p.emitStdout(
          'The Dart VM service is listening on http://127.0.0.1:1234/abc=/');
      await pumpEventQueue();
      p.emitStdout('flutter: still here');
      p.emitStdout('flutter: and here');
      await pumpEventQueue();

      expect(
        s.read(0).lines.map((l) => l.text),
        contains('flutter: still here'),
      );
      expect(
        s.read(0).lines.map((l) => l.text),
        contains('flutter: and here'),
      );
    });

    test('splits multi-line chunks into individual lines', () async {
      final p = FakeProcess();
      final s = AppLogStream();
      pumpProcessLines(p, s);

      p.emitStdoutRaw('a\nb\nc\n');
      await pumpEventQueue();

      expect(s.read(0).lines.map((l) => l.text), ['a', 'b', 'c']);
    });

    test('stderrIsError: false marks stderr lines as normal output', () async {
      final p = FakeProcess();
      final s = AppLogStream();
      pumpProcessLines(p, s, stderrIsError: false);

      p.emitStderr('not really an error\n');
      await pumpEventQueue();

      expect(s.read(0).lines.single.isError, isFalse);
    });

    test('applies the transform to each line when one is supplied', () async {
      final p = FakeProcess();
      final s = AppLogStream();
      pumpProcessLines(p, s, transform: (line) => line.startsWith('keep:')
          ? line.substring('keep:'.length)
          : null);

      p.emitStdout('keep: kept');
      p.emitStdout('drop me');
      await pumpEventQueue();

      expect(s.read(0).lines.map((l) => l.text), [' kept']);
    });

    test('closes the stream once the process output ends', () async {
      final p = FakeProcess();
      final s = AppLogStream();
      pumpProcessLines(p, s);

      p.emitStdout('last words');
      await pumpEventQueue();
      expect(s.isClosed, isFalse);

      p.complete(0);
      await pumpEventQueue();

      expect(s.isClosed, isTrue,
          reason: 'a caller awaiting the stream must learn the app is gone '
              'immediately, not after a discovery timeout');
    });

    test('a closed stream still yields the exited app final output', () async {
      final p = FakeProcess();
      final s = AppLogStream();
      pumpProcessLines(p, s);

      p.emitStdout('Unhandled exception: it broke');
      await pumpEventQueue();
      p.complete(1);
      await pumpEventQueue();

      expect(s.read(0).lines.map((l) => l.text),
          contains('Unhandled exception: it broke'));
    });

    test('does not close while only one of the two streams has ended',
        () async {
      final p = FakeProcess();
      final s = AppLogStream();
      pumpProcessLines(p, s);

      await p.closeStdout();
      await pumpEventQueue();

      expect(s.isClosed, isFalse,
          reason: 'stderr may still carry the reason the app is failing');
    });

    test('dispose stops forwarding', () async {
      final p = FakeProcess();
      final s = AppLogStream();
      final pump = pumpProcessLines(p, s);

      p.emitStdout('before');
      await pumpEventQueue();
      await pump.dispose();
      p.emitStdout('after');
      await pumpEventQueue();

      expect(s.read(0).lines.map((l) => l.text), ['before']);
    });
  });
}
