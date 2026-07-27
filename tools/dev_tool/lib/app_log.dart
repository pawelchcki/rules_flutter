/// Console output from a running Flutter app.
///
/// A launched app produces console output for its whole lifetime, and the dev
/// tool has several consumers for it that come and go at different times: the
/// terminal, the `app.log` machine-protocol event, and the HTTP control
/// channel's `/logs` endpoint. [AppLogStream] is the single place that output
/// lands, so every consumer sees the same lines.
///
/// Two properties matter and neither is free:
///
///  * **Nothing is lost before someone listens.** Output starts flowing the
///    moment the app is spawned, but the session that forwards it isn't wired
///    up until `launch()` has returned. A plain broadcast controller discards
///    events emitted while unlistened, which would silently swallow everything
///    printed during startup and VM-service discovery. So the stream is backed
///    by a ring buffer that is replayed to each new listener.
///  * **The producer never blocks.** Whatever feeds the stream (an OS pipe, a
///    logcat process, a VM-service event stream) must keep being drained
///    regardless of whether anyone is listening, or the app itself can stall on
///    a full pipe. Adding to the buffer is unconditional and never awaits a
///    consumer.
///
/// The buffer is bounded. When it overflows, the eviction is *reported*
/// ([dropped], and [LogPage.missed] for a specific reader) rather than papered
/// over, so a consumer can tell "there was nothing more" apart from "I fell
/// behind".
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

/// A single line of console output from a running app.
class AppLogLine {
  /// The line, without its trailing newline.
  final String text;

  /// Whether the line came from an error channel (the process's stderr, a
  /// VM-service `Stderr` event, a `console.error` call).
  final bool isError;

  /// Monotonically increasing position in the app's output. Stable across
  /// eviction: index `n` always refers to the same line, whether or not it is
  /// still buffered.
  final int index;

  const AppLogLine({
    required this.text,
    required this.isError,
    required this.index,
  });

  @override
  String toString() => '${isError ? 'stderr' : 'stdout'}[$index]: $text';
}

/// A page of lines from [AppLogStream.read], plus what the reader needs to
/// keep polling without gaps or overlap.
class LogPage {
  final List<AppLogLine> lines;

  /// Pass this back as the next `cursor` to continue where this page ended.
  final int nextCursor;

  /// How many lines fell between the requested cursor and the first line
  /// returned — i.e. lines that were evicted before this reader asked for
  /// them. Zero means the page is contiguous with the previous one.
  ///
  /// Always zero for a tail read: a caller asking for "the last N lines" did
  /// not ask for anything earlier, so nothing was missed.
  final int missed;

  const LogPage({
    required this.lines,
    required this.nextCursor,
    required this.missed,
  });
}

/// Default number of lines retained. Roughly a screen's worth of scrollback
/// several times over; enough that a consumer polling every few seconds never
/// falls behind, small enough to be irrelevant to memory.
const _defaultCapacity = 2000;

/// The largest page [AppLogStream.read] will return regardless of the
/// requested limit, so a naive `cursor: 0` on a long-running app can't produce
/// an unbounded response.
const _maxPageSize = 1000;

/// Fans a running app's console output out to zero or more listeners.
///
/// See the library docs for why this exists rather than a bare
/// `StreamController.broadcast()`.
class AppLogStream {
  final int capacity;
  final ListQueue<AppLogLine> _buffer = ListQueue<AppLogLine>();
  final StreamController<AppLogLine> _controller =
      StreamController<AppLogLine>.broadcast();

  int _nextCursor = 0;
  int _dropped = 0;
  int _producers = 0;
  bool _closed = false;

  AppLogStream({this.capacity = _defaultCapacity})
      : assert(capacity > 0, 'capacity must be positive');

  /// Register a source that feeds this stream.
  ///
  /// The stream closes once every registered producer has called
  /// [producerDone] — not when the first one does. A stream can have several
  /// producers with different lifetimes: a physical iOS device is fed both by
  /// the `devicectl --console` process, which exits when the app terminates,
  /// and by lldb, which stays attached and is where the crash report comes
  /// from. Closing on the first to finish silently discarded everything the
  /// longer-lived source had left to say.
  ///
  /// A no-op once the stream is closed: nothing can arrive on it any more, so
  /// registering against one cannot revive it.
  void addProducer() {
    if (_closed) return;
    _producers++;
  }

  /// Report that a producer registered with [addProducer] has ended.
  ///
  /// Closes the stream when the last one does, so a reader waiting on it
  /// learns immediately that no more output is coming rather than sitting out
  /// a timeout. Calling this more often than [addProducer] is harmless.
  void producerDone() {
    if (_closed) return;
    if (_producers > 0) _producers--;
    if (_producers == 0) unawaited(close());
  }

  /// Append a line. Never blocks, and is a no-op once [close] has been called.
  void add(String text, {bool isError = false}) {
    if (_closed) return;
    final line = AppLogLine(
      text: text,
      isError: isError,
      index: _nextCursor++,
    );
    _buffer.addLast(line);
    while (_buffer.length > capacity) {
      _buffer.removeFirst();
      _dropped++;
    }
    _controller.add(line);
  }

  /// Every line, buffered ones first and then live ones as they arrive.
  ///
  /// Each listener gets its own replay of whatever is currently buffered, so a
  /// consumer that attaches late still sees the app's startup output.
  Stream<AppLogLine> get lines {
    late StreamController<AppLogLine> out;
    StreamSubscription<AppLogLine>? live;

    out = StreamController<AppLogLine>(
      onListen: () {
        // Snapshot before subscribing: any line added between the snapshot and
        // the subscription would otherwise be delivered twice.
        final replay = List<AppLogLine>.of(_buffer);
        final replayedThrough = _nextCursor;
        for (final line in replay) {
          out.add(line);
        }
        if (_closed) {
          out.close();
          return;
        }
        live = _controller.stream.listen(
          (line) {
            if (line.index >= replayedThrough) out.add(line);
          },
          onDone: out.close,
          onError: out.addError,
        );
      },
      onCancel: () async {
        await live?.cancel();
        live = null;
      },
    );

    return out.stream;
  }

  /// Read a page of lines.
  ///
  /// [cursor] selects the starting point:
  ///
  ///  * `0` — from the oldest line still buffered.
  ///  * `n > 0` — resume at index `n` (pass back a previous
  ///    [LogPage.nextCursor]).
  ///  * `n < 0` — *tail*: the last `-n` lines. `read(-100)` means "the most
  ///    recent 100 lines", which is what a consumer with no prior cursor
  ///    almost always wants.
  ///
  /// A cursor older than the retained window clamps to the oldest retained
  /// line and reports the gap in [LogPage.missed]; it is never silently
  /// treated as if it had been contiguous.
  LogPage read(int cursor, {int limit = _maxPageSize}) {
    final effectiveLimit = limit <= 0 ? 0 : (limit > _maxPageSize ? _maxPageSize : limit);
    if (_buffer.isEmpty || effectiveLimit == 0) {
      return LogPage(lines: const [], nextCursor: _nextCursor, missed: 0);
    }

    final oldest = _buffer.first.index;

    if (cursor < 0) {
      // Tail: take from the end, so a limit smaller than the requested window
      // keeps the *newest* lines rather than the oldest of that window.
      final want = -cursor;
      final take = want < effectiveLimit ? want : effectiveLimit;
      final all = _buffer.toList(growable: false);
      final from = all.length > take ? all.length - take : 0;
      return LogPage(
        lines: all.sublist(from),
        nextCursor: _nextCursor,
        missed: 0,
      );
    }

    final missed = cursor < oldest ? oldest - cursor : 0;
    final start = cursor < oldest ? oldest : cursor;
    final selected = <AppLogLine>[];
    for (final line in _buffer) {
      if (line.index < start) continue;
      if (selected.length >= effectiveLimit) break;
      selected.add(line);
    }

    return LogPage(
      lines: selected,
      nextCursor: selected.isEmpty ? _nextCursor : selected.last.index + 1,
      missed: missed,
    );
  }

  /// The index the next added line will get — i.e. one past the newest line.
  int get nextCursor => _nextCursor;

  /// The lowest index still retained, or [nextCursor] when nothing is
  /// buffered.
  int get oldestCursor => _buffer.isEmpty ? _nextCursor : _buffer.first.index;

  /// Total lines evicted since the stream was created.
  int get dropped => _dropped;

  /// Whether [close] has been called.
  bool get isClosed => _closed;

  /// Stop accepting lines and complete every listener. Idempotent.
  ///
  /// The buffer is retained so a consumer can still [read] an exited app's
  /// final output — a crash's last lines are the ones that matter most.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _controller.close();
  }
}

/// A running forwarder from some source into an [AppLogStream].
class AppLogPump {
  final List<StreamSubscription<String>> _subscriptions;

  AppLogPump(this._subscriptions);

  /// Stop forwarding. The [AppLogStream] itself is unaffected.
  Future<void> dispose() async {
    await Future.wait(_subscriptions.map((s) => s.cancel()));
    _subscriptions.clear();
  }
}

/// Wire a process's stdout and stderr into [out] for the process's lifetime.
///
/// This deliberately never stops on a content match. Discovery of things like
/// the VM-service URI is a *reader* of [AppLogStream], not an owner of these
/// subscriptions — an earlier version cancelled here once the URI was found,
/// which silently killed all subsequent app output and left the OS pipes
/// unread.
///
/// [transform] filters and rewrites lines: return null to drop a line (used by
/// sources like `adb logcat` that carry unrelated system logging).
///
/// The process is registered as a producer of [out] (see
/// [AppLogStream.addProducer]), and reported done when both of its output
/// streams end. With a single producer that closes [out] outright: no further
/// output can ever arrive, and saying so promptly is what lets a caller
/// waiting on the stream (VM-service discovery) give up the moment the app
/// dies instead of sitting out its timeout. Where [out] has other producers —
/// the iOS device's lldb forwarder — it stays open until they finish too. The
/// buffered lines survive the close, so an app's final output is still
/// readable, usually the output that explains why it exited.
AppLogPump pumpProcessLines(
  Process process,
  AppLogStream out, {
  bool stderrIsError = true,
  String? Function(String line)? transform,
}) {
  void handle(String line, {required bool isError}) {
    final mapped = transform == null ? line : transform(line);
    if (mapped == null) return;
    out.add(mapped, isError: isError);
  }

  Stream<String> linesOf(Stream<List<int>> raw) => raw
      // Device logs occasionally carry invalid UTF-8; a decoding error must
      // not tear down forwarding for the rest of the run.
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter());

  out.addProducer();
  var remaining = 2;
  void onStreamDone() {
    if (--remaining == 0) out.producerDone();
  }

  return AppLogPump([
    linesOf(process.stdout)
        .listen((l) => handle(l, isError: false), onDone: onStreamDone),
    linesOf(process.stderr)
        .listen((l) => handle(l, isError: stderrIsError), onDone: onStreamDone),
  ]);
}
