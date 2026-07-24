/// Where a running app's console output goes.
///
/// [AppLogStream] is the single source of an app's output; this file is the
/// other end — the two destinations the dev tool can write it to, and the
/// rule for choosing between them.
///
/// The distinction is load-bearing rather than cosmetic. In `--machine` mode
/// stdout belongs to the JSON-RPC protocol an IDE is parsing, so app output
/// must travel as `app.log` events; writing it raw (as an earlier version did
/// during VM-service discovery) interleaves non-JSON text into that stream.
import 'dart:io';

import 'app_log.dart';
import 'machine_protocol.dart';

/// Receives each line of an app's console output.
typedef AppLogSink = void Function(AppLogLine line);

/// Writes app output to the terminal, the way `flutter run` does.
///
/// Normal output goes to stdout and error output to stderr, so redirection and
/// piping behave as expected. [prefix], when set, tags each line with the
/// device name — `flutter run -d all` does the same, and without it a
/// multi-device run is an unreadable interleave.
AppLogSink TerminalAppLogSink({
  required IOSink out,
  required IOSink err,
  String? prefix,
}) {
  final tag = prefix == null ? '' : '[$prefix] ';
  return (line) {
    (line.isError ? err : out).writeln('$tag${line.text}');
  };
}

/// Emits app output as `app.log` machine-protocol events.
AppLogSink MachineAppLogSink(MachineProtocol protocol, String appId) {
  return (line) {
    protocol.appLog(appId, line.text, error: line.isError);
  };
}

/// Pick the sink for a session.
///
/// [multiDevice] only affects the terminal sink: in machine mode each event
/// already carries its `appId`, so prefixing the payload would corrupt the
/// log text a client displays.
AppLogSink appLogSinkFor({
  required MachineProtocol protocol,
  required String appId,
  required String deviceName,
  required bool multiDevice,
  IOSink? out,
  IOSink? err,
}) {
  if (protocol.enabled) return MachineAppLogSink(protocol, appId);
  return TerminalAppLogSink(
    out: out ?? stdout,
    err: err ?? stderr,
    prefix: multiDevice ? deviceName : null,
  );
}
