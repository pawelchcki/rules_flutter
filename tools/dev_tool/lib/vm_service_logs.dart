/// Forwarding an app's console output over the VM service.
///
/// The Dart VM publishes `print()` and stderr writes as `Stdout`/`Stderr`
/// stream events. This is the right source in exactly two situations:
///
///   * **Web (DDC dev mode)** — a browser page has no process pipes to read,
///     but DWDS exposes a real VM service whose `Stdout` events carry the
///     app's output.
///   * **`attach` mode** — the dev tool didn't spawn the app, so there is no
///     process log source at all; the VM service is all there is.
///
/// It is *not* the right source on native devices, where the same `print()`
/// also reaches the process's stdout: subscribing to both prints every line
/// twice. See the one-source-per-platform note in `device.dart`.
import 'dart:async';
import 'dart:convert';

import 'package:vm_service/vm_service.dart';

import 'app_log.dart';

/// Decode a `Stdout`/`Stderr` event's payload, or null when the event carries
/// none at all.
///
/// The VM base64-encodes the bytes and terminates each write with a newline.
/// The terminator is kept rather than stripped, because stripping loses the
/// one payload that consists of nothing else: an app's `print('')` arrives as
/// exactly `"\n"`, and that is a blank line, not an absence of output. Callers
/// split on line terminators, which consumes the trailing newline without
/// inventing a blank line after every print — the same end result flutter_tools
/// gets by stripping in `processVmServiceMessage` and re-printing the message
/// whole.
String? decodeVmServiceLogEvent(Event event) {
  final bytes = event.bytes;
  if (bytes == null) return null;
  return utf8.decode(base64.decode(bytes), allowMalformed: true);
}

/// A running forwarder from a VM service's output streams into an
/// [AppLogStream].
class VmServiceLogForwarder {
  final List<StreamSubscription<Event>> _subscriptions;

  VmServiceLogForwarder(this._subscriptions);

  Future<void> dispose() async {
    await Future.wait(_subscriptions.map((s) => s.cancel()));
    _subscriptions.clear();
  }
}

/// Subscribe [service]'s `Stdout` and `Stderr` streams into [logs].
///
/// Already-subscribed errors (`kStreamAlreadySubscribed`) are ignored so this
/// is safe to call again after a reconnect — a web hot restart re-attaches to
/// a fresh VM service on the same DWDS connection.
Future<VmServiceLogForwarder> forwardVmServiceLogs(
  VmService service,
  AppLogStream logs,
) async {
  void emit(Event event, {required bool isError}) {
    final text = decodeVmServiceLogEvent(event);
    if (text == null) return;
    for (final line in const LineSplitter().convert(text)) {
      logs.add(line, isError: isError);
    }
  }

  final subscriptions = <StreamSubscription<Event>>[
    service.onStdoutEvent.listen((e) => emit(e, isError: false)),
    service.onStderrEvent.listen((e) => emit(e, isError: true)),
  ];

  for (final stream in [EventStreams.kStdout, EventStreams.kStderr]) {
    try {
      await service.streamListen(stream);
    } on RPCError catch (e) {
      // 103 = kStreamAlreadySubscribed. Anything else is a real failure.
      if (e.code != 103) {
        for (final s in subscriptions) {
          await s.cancel();
        }
        rethrow;
      }
    }
  }

  return VmServiceLogForwarder(subscriptions);
}
