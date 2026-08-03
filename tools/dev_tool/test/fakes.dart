/// Shared test doubles for dev tool tests.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_bazel_dev_tool/hot_reload/app_instance.dart';
import 'package:flutter_bazel_dev_tool/hot_reload/compiler.dart';
import 'package:flutter_bazel_dev_tool/mdns_vm_service_discovery.dart';
import 'package:multicast_dns/multicast_dns.dart';
import 'package:vm_service/vm_service.dart';

/// An [IOSink] that captures output to a [StringBuffer].
class BufferSink implements IOSink {
  final StringBuffer buffer = StringBuffer();

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) => buffer.write(encoding.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future close() async {}

  @override
  Future get done => Future.value();

  @override
  Future flush() => Future.value();

  @override
  void write(Object? object) => buffer.write(object);

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => buffer.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) => buffer.writeln(object);

  @override
  String toString() => buffer.toString();

  /// Lines written (splits on newline, drops trailing empty).
  List<String> get lines {
    final s = buffer.toString();
    if (s.isEmpty) return [];
    final l = s.split('\n');
    if (l.last.isEmpty) l.removeLast();
    return l;
  }
}

/// Decode the single machine-protocol message written to [sink].
///
/// The protocol wraps every message in a `[...]` array, so unwrapping is
/// two steps; doing it here keeps the assertion in the test about the
/// message rather than the envelope.
Map<String, dynamic> decodeSingleEvent(BufferSink sink) {
  final lines = sink.lines;
  if (lines.length != 1) {
    throw StateError('expected exactly one protocol line, got ${lines.length}: '
        '$lines');
  }
  return (json.decode(lines.single) as List).single as Map<String, dynamic>;
}

/// A controllable fake [Process] for testing.
class FakeProcess implements Process {
  final Completer<void> _stdoutAttached = Completer<void>();
  final Completer<void> _stderrAttached = Completer<void>();

  late final StreamController<List<int>> _stdoutController =
      StreamController<List<int>>.broadcast(onListen: () {
    if (!_stdoutAttached.isCompleted) _stdoutAttached.complete();
  });
  late final StreamController<List<int>> _stderrController =
      StreamController<List<int>>.broadcast(onListen: () {
    if (!_stderrAttached.isCompleted) _stderrAttached.complete();
  });

  /// Whether something is currently reading this process's stdout / stderr.
  ///
  /// A real process blocks on write once an unread pipe fills, so "is anyone
  /// still draining this?" is the property a test needs to assert; a fake's
  /// in-memory controller would happily absorb output forever.
  bool get stdoutHasListener => _stdoutController.hasListener;
  bool get stderrHasListener => _stderrController.hasListener;

  /// Completes once the code under test is listening to both output streams.
  ///
  /// These are broadcast controllers, so anything emitted before a listener
  /// attaches is dropped. Await this instead of pumping the event queue a
  /// fixed number of times: a launch that does real I/O before subscribing
  /// (creating temp dirs, awaiting an install) takes an unpredictable number
  /// of turns to get there, which makes a pump-based barrier flaky.
  Future<void> get outputAttached =>
      Future.wait([_stdoutAttached.future, _stderrAttached.future]);
  final StringBuffer stdinBuffer = StringBuffer();
  final StreamController<String> _stdinLines =
      StreamController<String>.broadcast();
  final Completer<int> _exitCompleter = Completer<int>();

  /// Lines written to this process's stdin, as they are written.
  ///
  /// Lets a test script a request/response protocol — e.g. replying to the
  /// lldb commands the iOS device launch issues — rather than only asserting
  /// on [stdinBuffer] afterwards.
  Stream<String> get stdinLines => _stdinLines.stream;

  @override
  Stream<List<int>> get stdout => _stdoutController.stream;

  @override
  Stream<List<int>> get stderr => _stderrController.stream;

  @override
  IOSink get stdin => _FakeStdin(stdinBuffer, _stdinLines);

  @override
  int get pid => 12345;

  @override
  Future<int> get exitCode => _exitCompleter.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(-1);
    return true;
  }

  /// Emit a line on stdout (appends a newline automatically).
  void emitStdout(String line) {
    _stdoutController.add(utf8.encode('$line\n'));
  }

  /// Emit raw data on stdout without appending a newline.
  void emitStdoutRaw(String data) {
    _stdoutController.add(utf8.encode(data));
  }

  /// Emit data on stderr.
  void emitStderr(String data) {
    _stderrController.add(utf8.encode(data));
  }

  /// Complete the process with the given exit code.
  void complete(int exitCode) {
    if (!_exitCompleter.isCompleted) _exitCompleter.complete(exitCode);
    _stdoutController.close();
    _stderrController.close();
  }

  /// End stdout only, leaving stderr open — the shape of a process that is
  /// still complaining after its normal output has finished.
  Future<void> closeStdout() => _stdoutController.close();
}

class _FakeStdin implements IOSink {
  final StringBuffer _buffer;
  final StreamController<String>? _lines;

  _FakeStdin(this._buffer, [this._lines]);

  @override
  Encoding encoding = utf8;

  @override
  void add(List<int> data) => _buffer.write(encoding.decode(data));

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  Future addStream(Stream<List<int>> stream) async {
    await for (final data in stream) {
      add(data);
    }
  }

  @override
  Future close() async {}

  @override
  Future get done => Future.value();

  @override
  Future flush() => Future.value();

  @override
  void write(Object? object) => _buffer.write(object);

  @override
  void writeAll(Iterable objects, [String separator = '']) =>
      _buffer.writeAll(objects, separator);

  @override
  void writeCharCode(int charCode) => _buffer.writeCharCode(charCode);

  @override
  void writeln([Object? object = '']) {
    _buffer.writeln(object);
    if (_lines != null && !_lines!.isClosed) _lines!.add('$object');
  }
}

/// A fake [VmService] for testing hot reload/restart.
class FakeVmService implements VmService {
  final List<IsolateRef> isolates;
  bool reloadSourcesCalled = false;
  bool callServiceExtensionCalled = false;
  String? lastExtensionMethod;
  String? lastIsolateId;
  bool reloadSuccess;
  bool throwOnReload;
  bool disposed = false;
  bool _killed = false;

  /// Base64 PNG data to return for `_flutter.screenshot` calls.
  String? screenshotData;

  /// If non-null, [reloadSources] awaits this gate before returning. Lets
  /// tests deterministically simulate a hung VM-service RPC.
  Completer<void>? reloadSourcesGate;

  /// If non-null, every [callServiceExtension] awaits this gate before
  /// returning.
  Completer<void>? callServiceExtensionGate;

  /// When true, [reloadSources] posts a `Flutter.Error` extension event —
  /// mirroring the framework reporting a build failure during the
  /// reassemble triggered by a reload/restart.
  bool emitFlutterErrorOnReload;

  /// The `renderedErrorText` carried by the simulated `Flutter.Error`.
  String flutterErrorText;

  /// The name a `hotRestart` [callMethod] was issued under — bare, or the
  /// DDS-namespaced alias. Null until one is called. What proves the alias
  /// resolved off the `ServiceRegistered` event rather than being hardcoded.
  String? hotRestartMethod;

  /// If non-null, a `hotRestart` call throws this instead of succeeding.
  RPCError? hotRestartError;

  /// If non-null, a `hotRestart` call awaits this gate before returning. Lets
  /// a test drive DWDS's unbounded `waitForIsolateStarted` deterministically.
  Completer<void>? hotRestartGate;

  final StreamController<Event> _extController =
      StreamController<Event>.broadcast();
  final StreamController<Event> _stdoutController =
      StreamController<Event>.broadcast();
  final StreamController<Event> _stderrController =
      StreamController<Event>.broadcast();
  final StreamController<Event> _serviceController =
      StreamController<Event>.broadcast();

  /// Stream IDs passed to [streamListen], in call order.
  final List<String> streamListens = [];

  /// Stream IDs for which [streamListen] should report
  /// `kStreamAlreadySubscribed` — what a real VM service does on re-subscribe.
  final Set<String> alreadySubscribedStreams = {};

  /// Stream IDs for which [streamListen] should fail with an unrelated error.
  final Set<String> failingStreams = {};

  FakeVmService({
    this.isolates = const [],
    this.reloadSuccess = true,
    this.throwOnReload = false,
    this.screenshotData,
    this.reloadSourcesGate,
    this.callServiceExtensionGate,
    this.emitFlutterErrorOnReload = false,
    this.flutterErrorText = 'fake _CompileTimeError building MyApp',
  });

  @override
  Future<Success> streamListen(String streamId) async {
    _checkAlive('streamListen');
    streamListens.add(streamId);
    if (alreadySubscribedStreams.contains(streamId)) {
      throw RPCError('streamListen', 103, 'Stream already subscribed');
    }
    if (failingStreams.contains(streamId)) {
      throw RPCError('streamListen', 104, 'Stream cannot be subscribed');
    }
    return Success();
  }

  @override
  Future<Success> streamCancel(String streamId) async => Success();

  @override
  Stream<Event> get onExtensionEvent => _extController.stream;

  @override
  Stream<Event> get onServiceEvent => _serviceController.stream;

  /// Emit the `ServiceRegistered` event DDS sends when a client registers a
  /// service, carrying the namespaced [method] the caller must actually use
  /// (dds `stream_manager.dart:49-60`).
  void emitServiceRegistered(String service, String method) {
    _serviceController.add(Event(
      kind: EventKind.kServiceRegistered,
      service: service,
      method: method,
      timestamp: 0,
    ));
  }

  /// Emit the matching `ServiceUnregistered`.
  void emitServiceUnregistered(String service, String method) {
    _serviceController.add(Event(
      kind: EventKind.kServiceUnregistered,
      service: service,
      method: method,
      timestamp: 0,
    ));
  }

  @override
  Stream<Event> get onStdoutEvent => _stdoutController.stream;

  @override
  Stream<Event> get onStderrEvent => _stderrController.stream;

  /// Emit a `Stdout` event carrying [text], encoded the way the VM does.
  void emitStdoutEvent(String text) {
    _stdoutController.add(_logEvent(EventKind.kWriteEvent, text));
  }

  /// Emit a `Stderr` event carrying [text].
  void emitStderrEvent(String text) {
    _stderrController.add(_logEvent(EventKind.kWriteEvent, text));
  }

  Event _logEvent(String kind, String text) => Event(
        kind: kind,
        timestamp: 0,
      )..bytes = base64.encode(utf8.encode(text));

  /// Simulate the underlying WebSocket dying.
  ///
  /// Mirrors what `package:vm_service` does to a real `VmService` after its
  /// `streamClosed` future completes — every subsequent RPC throws
  /// `RPCError(-32000, 'Service connection disposed')`.
  ///
  /// Named `simulateDisposed` to avoid colliding with `VmService.kill(...)`,
  /// which is an unrelated isolate-management RPC.
  void simulateDisposed() {
    _killed = true;
  }

  void _checkAlive(String method) {
    if (_killed) {
      throw RPCError(method, -32000, 'Service connection disposed');
    }
  }

  @override
  Future<VM> getVM() async {
    _checkAlive('getVM');
    return VM(
      isolates: isolates,
      name: 'fake_vm',
      architectureBits: 64,
      hostCPU: 'fake',
      operatingSystem: 'fake',
      targetCPU: 'fake',
      version: '3.0.0',
      pid: 12345,
      startTime: 0,
    );
  }

  @override
  Future<ReloadReport> reloadSources(
    String isolateId, {
    bool? force,
    bool? pause,
    String? rootLibUri,
    String? packagesUri,
  }) async {
    _checkAlive('reloadSources');
    reloadSourcesCalled = true;
    lastIsolateId = isolateId;
    if (reloadSourcesGate != null) await reloadSourcesGate!.future;
    _checkAlive('reloadSources'); // gate may have outlived the connection
    if (throwOnReload) {
      throw RPCError('reloadSources', 100, 'Reload failed');
    }
    if (emitFlutterErrorOnReload) {
      // Real Flutter reports a build failure during the reassemble-driven
      // rebuild, before that frame's Flutter.Frame. Emitting here keeps
      // that ordering (Error before the reassemble-scheduled Frame).
      _extController.add(Event(
        kind: EventKind.kExtension,
        extensionKind: 'Flutter.Error',
        extensionData:
            ExtensionData.parse({'renderedErrorText': flutterErrorText}),
        timestamp: 0,
      ));
    }
    return ReloadReport(success: reloadSuccess);
  }

  /// Track extension call args.
  Map<String, dynamic>? lastExtensionArgs;

  /// Simulated toggle state per extension method.
  final Map<String, bool> _toggleState = {};

  @override
  Future<Response> callServiceExtension(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    _checkAlive(method);
    callServiceExtensionCalled = true;
    lastExtensionMethod = method;
    lastIsolateId = isolateId;
    lastExtensionArgs = args;
    if (callServiceExtensionGate != null) {
      await callServiceExtensionGate!.future;
      _checkAlive(method);
    }

    // Mirror real Flutter: reassemble triggers a rebuilt frame whose
    // `Flutter.Frame` timing event is posted *after* the reassemble RPC
    // response (i.e. a later turn here), so it lands after the client's
    // apply() returns — the success terminator for `_applyAndVerify`.
    if (method == 'ext.flutter.reassemble') {
      Future<void>(() {
        if (!_extController.isClosed) {
          _extController.add(Event(
            kind: EventKind.kExtension,
            extensionKind: 'Flutter.Frame',
            extensionData: ExtensionData.parse({'number': 1}),
            timestamp: 0,
          ));
        }
      });
    }

    // Return screenshot data if available.
    if (method == '_flutter.screenshot' && screenshotData != null) {
      return Response()..json = {'screenshot': screenshotData};
    }

    // Simulate toggle behavior: if args has 'enabled', update state.
    if (args != null && args.containsKey('enabled')) {
      _toggleState[method] = args['enabled'] == 'true';
    }

    // Return current state for toggle reads.
    final enabled = _toggleState[method] ?? false;
    final response = Response()
      ..json = {'enabled': enabled.toString()};
    return response;
  }

  /// True once `_flutter.runInView` (hot restart's main re-run) was called.
  bool runInViewCalled = false;

  @override
  Future<Isolate> getIsolate(String isolateId) async {
    _checkAlive('getIsolate');
    // Report the isolate as running (not paused) so hotRestart proceeds
    // straight to runInView without resuming.
    return Isolate(
      id: isolateId,
      pauseEvent: Event(kind: EventKind.kResume, timestamp: 0),
    );
  }

  @override
  Future<Response> callMethod(
    String method, {
    String? isolateId,
    Map<String, dynamic>? args,
  }) async {
    _checkAlive(method);
    // DWDS's hot restart, reachable bare or under a DDS namespace (`s0.`).
    // Without this branch the fall-through below would answer an empty
    // Response, making every restart pass while recording nothing.
    if (method == 'hotRestart' || method.endsWith('.hotRestart')) {
      hotRestartMethod = method;
      if (hotRestartGate != null) await hotRestartGate!.future;
      _checkAlive(method); // the gate may have outlived the connection
      if (hotRestartError != null) throw hotRestartError!;
      return Response()..json = Success().toJson();
    }
    if (method == '_flutter.listViews') {
      return Response()
        ..json = {
          'views': [
            {
              'type': 'FlutterView',
              'id': 'view-1',
              if (isolates.isNotEmpty) 'isolate': {'id': isolates.first.id},
            },
          ],
        };
    }
    if (method == '_flutter.runInView') {
      runInViewCalled = true;
      // Mirror real Flutter: a build failure during the restarted frame posts
      // Flutter.Error before that frame's Flutter.Frame.
      if (emitFlutterErrorOnReload) {
        _extController.add(Event(
          kind: EventKind.kExtension,
          extensionKind: 'Flutter.Error',
          extensionData:
              ExtensionData.parse({'renderedErrorText': flutterErrorText}),
          timestamp: 0,
        ));
      }
      // The restarted isolate renders a frame after runInView returns.
      Future<void>(() {
        if (!_extController.isClosed) {
          _extController.add(Event(
            kind: EventKind.kExtension,
            extensionKind: 'Flutter.Frame',
            extensionData: ExtensionData.parse({'number': 1}),
            timestamp: 0,
          ));
        }
      });
      return Response()..json = {};
    }
    return Response()..json = {};
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await _extController.close();
    await _stdoutController.close();
    await _stderrController.close();
    await _serviceController.close();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
        '${invocation.memberName} not implemented in FakeVmService');
  }
}

/// Captured arguments from a single [FakeCompiler.compileIncrement] call.
class RecompileCall {
  final String entrypoint;
  final Set<String> invalidated;
  RecompileCall(this.entrypoint, this.invalidated);
}

/// In-memory [Compiler] for orchestrator tests.
///
/// `nextOutcome` is the result of the next compile call. If `pendingResult`
/// is set, the call awaits it before returning — useful for mid-pipeline
/// race tests.
class FakeCompiler implements Compiler {
  CompileOutcome nextOutcome = const CompileSucceeded('/tmp/delta.dill');

  /// If non-null, [compileIncrement] / [compileFull] await this completer
  /// before returning [nextOutcome]. Lets tests hold a compile open.
  Completer<void>? pendingResult;

  final List<RecompileCall> recompileCalls = [];
  final List<String> fullCompileCalls = [];

  int commitCount = 0;
  int rollbackCount = 0;
  int shutdownCount = 0;

  @override
  Future<CompileOutcome> compileIncrement({
    required Set<String> invalidated,
    required String entrypoint,
  }) async {
    recompileCalls.add(RecompileCall(entrypoint, invalidated));
    if (pendingResult != null) await pendingResult!.future;
    return nextOutcome;
  }

  @override
  Future<CompileOutcome> compileFull({required String entrypoint}) async {
    fullCompileCalls.add(entrypoint);
    if (pendingResult != null) await pendingResult!.future;
    return nextOutcome;
  }

  @override
  Future<void> commit() async {
    commitCount++;
  }

  @override
  Future<void> rollback() async {
    rollbackCount++;
  }

  @override
  Future<void> shutdown() async {
    shutdownCount++;
  }
}

/// Captured arguments from a single [FakeAppInstance.applyKernel] call.
class ApplyCall {
  final String dillPath;
  final ApplyMode mode;
  ApplyCall(this.dillPath, this.mode);
}

/// In-memory [AppInstance] for orchestrator tests. Configurable per-call
/// outcome; records every call.
class FakeAppInstance implements AppInstance {
  @override
  final String id;

  /// Outcome to return from the next `applyKernel`. Defaults to [Applied].
  ApplyOutcome nextOutcome = const Applied();

  /// If non-null, [applyKernel] awaits this completer before returning.
  /// Lets tests deterministically simulate a slow/hung device.
  Completer<void>? gate;

  final List<ApplyCall> calls = [];

  FakeAppInstance({required this.id});

  @override
  Future<ApplyOutcome> applyKernel(
    String dillPath, {
    required ApplyMode mode,
  }) async {
    calls.add(ApplyCall(dillPath, mode));
    if (gate != null) await gate!.future;
    return nextOutcome;
  }
}

/// Hands out [FakeMDnsClient]s and counts them.
///
/// Discovery builds a fresh client per query attempt, so "answer on the Nth
/// attempt" — the property that proves retransmission works — is a fact about
/// the factory, not about any one client. Pass [call] as the
/// `MDnsClientFactory`.
class FakeMDnsClientFactory {
  /// Records handed to each client, by `(ResourceRecordType, name)`.
  final Map<(int, String), List<ResourceRecord>> records;

  /// Thrown from [MDnsClient.start], for the denied-permission path.
  final Object? startError;

  /// Number of leading attempts that answer with nothing.
  final int silentAttempts;

  final clients = <FakeMDnsClient>[];

  FakeMDnsClientFactory({
    Map<(int, String), List<ResourceRecord>>? records,
    this.startError,
    this.silentAttempts = 0,
  }) : records = records ?? const {};

  MDnsClient call() {
    final client = FakeMDnsClient(
      records: clients.length < silentAttempts ? const {} : records,
      startError: startError,
    );
    clients.add(client);
    return client;
  }
}

/// An [MDnsClient] that answers from a canned record set.
///
/// Records are keyed the way the real client's cache is — by the query's
/// resource-record type and fully-qualified name — so a test describes an
/// advertisement the same way a responder does: one PTR under the service
/// type, and SRV/TXT/A records under the instance name.
class FakeMDnsClient implements MDnsClient {
  final Map<(int, String), List<ResourceRecord>> records;
  final Object? startError;

  bool started = false;
  bool stopped = false;

  FakeMDnsClient({
    Map<(int, String), List<ResourceRecord>>? records,
    this.startError,
  }) : records = records ?? const {};

  @override
  Future<void> start({
    InternetAddress? listenAddress,
    NetworkInterfacesFactory? interfacesFactory,
    int mDnsPort = 5353,
    InternetAddress? mDnsAddress,
    Function? onError,
  }) async {
    if (startError != null) throw startError!;
    started = true;
  }

  @override
  void stop() => stopped = true;

  @override
  Stream<T> lookup<T extends ResourceRecord>(
    ResourceRecordQuery query, {
    Duration timeout = const Duration(seconds: 5),
  }) {
    final matches =
        records[(query.resourceRecordType, query.fullyQualifiedName)] ??
            const <ResourceRecord>[];
    return Stream.fromIterable(matches.whereType<T>());
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnimplementedError(
        '${invocation.memberName} not implemented in FakeMDnsClient');
  }
}

/// A `_dartVmService._tcp` advertisement, as a responder would answer it.
///
/// Returns the record map [FakeMDnsClient] expects.
Map<(int, String), List<ResourceRecord>> dartVmServiceRecords({
  required String instance,
  required String host,
  required int port,
  String? authCode,
  List<String> addresses = const [],
}) {
  const validUntil = 1 << 40;
  final service = '$instance.$dartVmServiceMdnsName';
  return {
    (ResourceRecordType.serverPointer, dartVmServiceMdnsName): [
      PtrResourceRecord(dartVmServiceMdnsName, validUntil,
          domainName: service),
    ],
    (ResourceRecordType.service, service): [
      SrvResourceRecord(service, validUntil,
          target: host, port: port, priority: 0, weight: 0),
    ],
    if (authCode != null)
      (ResourceRecordType.text, service): [
        TxtResourceRecord(service, validUntil, text: 'authCode=$authCode'),
      ],
    if (addresses.isNotEmpty)
      (ResourceRecordType.addressIPv4, host): [
        for (final a in addresses)
          IPAddressResourceRecord(host, validUntil,
              address: InternetAddress(a)),
      ],
  };
}
