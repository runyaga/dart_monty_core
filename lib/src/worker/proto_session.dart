/// The minimal driver: one Python session on one worker, over any
/// [MontyChannel].
///
/// Configure, feed (answering name lookups, external function calls and OS
/// calls until the snippet ends), reset and close. Pure Dart and identical on
/// every backend: only the channel underneath differs.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';

import 'package:collection/collection.dart';

import 'package:dart_monty_core/src/platform/monty_error.dart';
import 'package:dart_monty_core/src/platform/monty_exception.dart';
import 'package:dart_monty_core/src/platform/monty_stack_frame.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_exception.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';

/// The monty-proto schema version this driver speaks: upstream's
/// `PROTOCOL_VERSION` at the pinned tag.
const int protocolVersion = 5;

/// What the driver reports as its version in `Configure`. Informational
/// only; the worker never checks it.
const String _driverVersion = 'dart_monty_core';

/// One Python session on one worker.
///
/// A Python exception in fed code throws [MontyScriptError] (or
/// [MontySyntaxError]) carrying the traceback, and the session stays usable.
/// A dead worker throws [MontyCrashedError], and the session is over: open a
/// new one on a new channel.
///
/// [close] must be called: it is what ends the worker.
final class ProtoSession {
  ProtoSession._(this._channel, this._config);

  final MontyChannel _channel;
  final SessionConfig _config;
  bool _busy = false;

  /// Configures a session on [channel].
  static Future<ProtoSession> open(
    MontyChannel channel, [
    SessionConfig config = const SessionConfig(),
  ]) async {
    final session = ProtoSession._(channel, config);
    await session._guard(session._configure);

    return session;
  }

  /// Runs [code] and completes with its value.
  ///
  /// [inputs] are bound as global names before the code runs. A call to a
  /// name in [externals] runs that function; [onOsCall] answers OS calls,
  /// which are declined without it. [onPrint] sees each run of printed text
  /// as it arrives, and its future is awaited before the next one; the
  /// result also lists them all, unless [collectPrints] is false.
  Future<FeedResult> feed(
    String code, {
    Map<String, MontyValue> inputs = const {},
    Map<String, ProtoExternalFunction> externals = const {},
    ProtoOsCallHandler? onOsCall,
    ProtoPrintCallback? onPrint,
    bool collectPrints = true,
  }) => _guard(() async {
    final sink = _PrintSink(onPrint, _channel.kill, collect: collectPrints);
    var request = pb.ParentRequest(feed: _feedRequest(code, inputs));
    for (;;) {
      final pb.ChildEvent event;
      try {
        event = await _channel.turn(request, onPrint: sink.add);
      } on Object {
        sink.rethrowFailure();
        rethrow;
      }
      sink.rethrowFailure();
      if (event.whichKind() == pb.ChildEvent_Kind.complete) {
        final complete = event.complete;

        return FeedResult(
          ArenaReader(complete.values)[complete.value],
          List.unmodifiable(sink.prints),
        );
      }
      request = await _answer(event, externals, onOsCall);
    }
  });

  /// Drops all session state, then configures a fresh session on the same
  /// worker.
  Future<void> reset() => _guard(() async {
    final event = await _channel.turn(pb.ParentRequest(reset: pb.Reset()));
    if (event.whichKind() != pb.ChildEvent_Kind.ok) _desync('Reset', event);
    await _configure();
  });

  /// Ends the worker. Idempotent.
  Future<void> close() => _channel.close();

  Future<void> _configure() async {
    final request = pb.ParentRequest(configure: _config._toProto());
    final event = await _channel.turn(request);
    if (event.whichKind() != pb.ChildEvent_Kind.ok) {
      _desync('Configure', event);
    }
  }

  /// The request that answers a suspension [event] during a feed.
  Future<pb.ParentRequest> _answer(
    pb.ChildEvent event,
    Map<String, ProtoExternalFunction> externals,
    ProtoOsCallHandler? onOsCall,
  ) async => switch (event.whichKind()) {
    pb.ChildEvent_Kind.error => _throwRaised(event.error.exception),
    pb.ChildEvent_Kind.nameLookup => _answerNameLookup(
      event.nameLookup.name,
      externals,
    ),
    pb.ChildEvent_Kind.functionCall => await _answerCall(
      event.functionCall,
      externals,
    ),
    pb.ChildEvent_Kind.osCall => await _answerOsCall(event.osCall, onOsCall),
    // Never sent without the request that asks for it (futures, type
    // checking, dumps), or not a feed's answer at all.
    _ => _desync('Feed', event),
  };

  /// Runs [body] as the one request in flight.
  Future<T> _guard<T>(Future<T> Function() body) async {
    if (_busy) {
      throw StateError(
        'a ProtoSession runs one request at a time; await the previous one',
      );
    }
    _busy = true;
    try {
      return await body();
    } finally {
      _busy = false;
    }
  }

  /// The worker answered [request] with an event that cannot follow it, so
  /// its state is unknown: kill it rather than guess.
  Never _desync(String request, pb.ChildEvent event) {
    _channel.kill();
    throw MontyCrashedError(
      CrashCause.killed,
      message:
          'protocol desync: $request was answered with '
          '${event.whichKind().name}',
    );
  }
}

/// Collects a feed's prints and passes each to the caller's callback,
/// awaiting it before the next.
///
/// A throwing callback must not escape into the channel mid-turn, and the
/// feed cannot carry on without it: the worker may be suspended on a call
/// nobody will answer, or never end the turn at all. So the first failure
/// kills the worker at once, later prints are dropped, and the driver
/// rethrows the failure when the turn returns.
final class _PrintSink {
  _PrintSink(this._onPrint, this._kill, {required bool collect})
    : _collect = collect;

  final List<(String, String)> prints = [];
  final ProtoPrintCallback? _onPrint;
  final void Function() _kill;
  final bool _collect;
  (Object, StackTrace)? _failure;

  Future<void> add(pb.Print print) async {
    for (final segment in print.segments) {
      if (_failure != null) return;
      final stream = segment.stream == pb.PrintStream.PRINT_STREAM_STDERR
          ? 'stderr'
          : 'stdout';
      if (_collect) prints.add((stream, segment.text));
      final onPrint = _onPrint;
      if (onPrint == null) continue;
      try {
        await onPrint(stream, segment.text);
      } on Object catch (error, stack) {
        _failure = (error, stack);
        _kill();

        return;
      }
    }
  }

  /// Throws the callback's failure, if there was one.
  void rethrowFailure() {
    if (_failure case (final error, final stack)) {
      Error.throwWithStackTrace(error, stack);
    }
  }
}

/// Session settings, sent to the worker in `Configure`.
final class SessionConfig {
  /// Creates the settings. A null limit leaves the worker's default.
  const SessionConfig({
    this.scriptName = 'main.py',
    this.maxMemoryBytes,
    this.maxRecursionDepth,
    this.maxFeedDuration,
    this.maxTurnDuration,
    this.assertMessageAnnotations,
    this.printFlushInterval,
  });

  /// The file name tracebacks report for fed code.
  final String scriptName;

  /// The interpreter's heap limit. Exceeding it raises `MemoryError` in
  /// Python; the session survives.
  final int? maxMemoryBytes;

  /// The interpreter's recursion limit.
  final int? maxRecursionDepth;

  /// The longest one feed may run, enforced by the worker.
  final Duration? maxFeedDuration;

  /// The longest one turn of a feed may run (each resume starts a new
  /// turn), enforced by the worker.
  final Duration? maxTurnDuration;

  /// How many bytes of each operand an `assert` failure message shows; 0
  /// turns the annotations off, null keeps the worker's default (120).
  final int? assertMessageAnnotations;

  /// How long the worker may hold printed text before it sends it; zero
  /// sends each line as it ends, null keeps the worker's default.
  final Duration? printFlushInterval;

  pb.Configure _toProto() {
    final memory = maxMemoryBytes;
    final recursion = maxRecursionDepth;
    final feed = maxFeedDuration;
    final turn = maxTurnDuration;
    final hasLimits =
        memory != null || recursion != null || feed != null || turn != null;
    final flush = printFlushInterval;

    return pb.Configure(
      scriptName: scriptName,
      protocolVersion: protocolVersion,
      montyVersion: _driverVersion,
      limits: hasLimits
          ? pb.ResourceLimits(
              maxMemoryBytes: memory == null ? null : Int64(memory),
              maxRecursionDepth: recursion == null ? null : Int64(recursion),
              maxFeedDurationMicros: feed == null
                  ? null
                  : Int64(feed.inMicroseconds),
              maxTurnDurationMicros: turn == null
                  ? null
                  : Int64(turn.inMicroseconds),
            )
          : null,
      assertMessageAnnotations: assertMessageAnnotations,
      printFlushIntervalMs: flush?.inMilliseconds,
    );
  }
}

/// A host function Python can call by name.
///
/// Throw [OsCallException] to raise a chosen Python exception class; any
/// other throw raises `RuntimeError` with its text.
typedef ProtoExternalFunction =
    FutureOr<MontyValue> Function(
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    );

/// Answers an OS call such as `Path.read_text`.
///
/// [name] is upstream's dotted name and [args] its arguments (a
/// [MontyPath] for the `Path` methods). Return null, or throw
/// [OsCallNotHandledException], to decline: Python then sees the call's own
/// no-handler error. Throw [OsCallException] to raise a chosen exception;
/// any other throw raises `RuntimeError` with its text.
typedef ProtoOsCallHandler =
    FutureOr<MontyValue?> Function(
      String name,
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    );

/// Receives one run of printed text, as it arrives; a returned future is
/// awaited before the next run is delivered.
typedef ProtoPrintCallback =
    FutureOr<void> Function(String stream, String text);

/// What a feed produced.
final class FeedResult {
  /// Creates a result.
  const FeedResult(this.value, this.prints);

  /// The value of the snippet's last expression; [MontyNone] for a
  /// statement.
  final MontyValue value;

  /// Everything printed during the feed, in order, as (stream, text) where
  /// stream is `stdout` or `stderr`.
  final List<(String, String)> prints;
}

pb.Feed _feedRequest(String code, Map<String, MontyValue> inputs) {
  final feed = pb.Feed(code: code);
  if (inputs.isEmpty) return feed;
  final writer = ArenaWriter();
  for (final MapEntry(:key, :value) in inputs.entries) {
    feed.inputs.add(pb.NamedRef(name: key, value: writer.add(value)));
  }

  return feed..values = writer.arena;
}

pb.ParentRequest _answerNameLookup(
  String name,
  Map<String, ProtoExternalFunction> externals,
) {
  if (!externals.containsKey(name)) {
    return pb.ParentRequest(
      resumeNameLookup: pb.ResumeNameLookup(undefined: pb.Unit()),
    );
  }
  // The name resolves to a function the child calls back through
  // FunctionCall, so the host keeps the implementation.
  final arena = pb.Arena(nodeCount: 1, nodes: [functionNode(name)]);

  return pb.ParentRequest(
    resumeNameLookup: pb.ResumeNameLookup(values: arena, value: 0),
  );
}

Future<pb.ParentRequest> _answerCall(
  pb.FunctionCall call,
  Map<String, ProtoExternalFunction> externals,
) async {
  final function = externals[call.functionName];
  if (function == null) {
    return _resume(
      call.callId,
      pb.ExtFunctionResult(notFound: call.functionName),
    );
  }

  // Decoding the arguments is inside the guarded body too: an argument this
  // driver cannot carry fails the call in Python, and the worker, suspended
  // on it, still gets its answer.
  return _resumeWith(call.callId, () {
    final reader = ArenaReader(call.values);
    final args = [for (final a in call.args) reader[a]];

    return function(args, _kwargs(reader, call.kwargs));
  });
}

Future<pb.ParentRequest> _answerOsCall(
  pb.OsCall call,
  ProtoOsCallHandler? handler,
) async {
  final named = _osCallName(call);
  final notHandled = _resume(
    call.callId,
    pb.ExtFunctionResult(notHandled: pb.Unit()),
  );
  if (handler == null || named == null) return notHandled;
  final (name, path) = named;
  try {
    final value = await handler(name, [MontyPath(path)], const {});
    if (value == null) return notHandled;

    return _resumeValue(call.callId, value);
  } on OsCallNotHandledException {
    return notHandled;
  } on Object catch (error) {
    return _resume(
      call.callId,
      pb.ExtFunctionResult(error: _raisedFrom(error)),
    );
  }
}

/// Upstream's name and the path for the OS calls whose only argument is a
/// path; null for the rest, which this driver declines.
(String, String)? _osCallName(pb.OsCall call) {
  final entry = _pathCalls[call.whichCall()];
  if (entry == null) return null;
  final (name, path) = entry;

  return (name, path(call));
}

final Map<pb.OsCall_Call, (String, String Function(pb.OsCall))> _pathCalls = {
  pb.OsCall_Call.exists: ('Path.exists', (c) => c.exists),
  pb.OsCall_Call.isFile: ('Path.is_file', (c) => c.isFile),
  pb.OsCall_Call.isDir: ('Path.is_dir', (c) => c.isDir),
  pb.OsCall_Call.isSymlink: ('Path.is_symlink', (c) => c.isSymlink),
  pb.OsCall_Call.readText: ('Path.read_text', (c) => c.readText),
  pb.OsCall_Call.readBytes: ('Path.read_bytes', (c) => c.readBytes),
  pb.OsCall_Call.stat: ('Path.stat', (c) => c.stat),
  pb.OsCall_Call.iterdir: ('Path.iterdir', (c) => c.iterdir),
  pb.OsCall_Call.resolve: ('Path.resolve', (c) => c.resolve),
  pb.OsCall_Call.absolute: ('Path.absolute', (c) => c.absolute),
  pb.OsCall_Call.unlink: ('Path.unlink', (c) => c.unlink),
  pb.OsCall_Call.rmdir: ('Path.rmdir', (c) => c.rmdir),
};

Map<String, MontyValue> _kwargs(ArenaReader reader, List<pb.NodePair> pairs) {
  final kwargs = <String, MontyValue>{};
  for (final pair in pairs) {
    final key = reader[pair.key];
    if (key is! MontyString) {
      throw FormatException(
        'a keyword argument name must be a str; the worker sent a '
        '${key.runtimeType}',
      );
    }
    kwargs[key.value] = reader[pair.value];
  }

  return kwargs;
}

Future<pb.ParentRequest> _resumeWith(
  int callId,
  FutureOr<MontyValue> Function() body,
) async {
  try {
    return _resumeValue(callId, await body());
  } on Object catch (error) {
    return _resume(callId, pb.ExtFunctionResult(error: _raisedFrom(error)));
  }
}

pb.ParentRequest _resumeValue(int callId, MontyValue value) {
  final writer = ArenaWriter();
  final index = writer.add(value);

  return _resume(
    callId,
    pb.ExtFunctionResult(returnValue: index),
    writer.arena,
  );
}

pb.ParentRequest _resume(
  int callId,
  pb.ExtFunctionResult result, [
  pb.Arena? values,
]) => pb.ParentRequest(
  resumeCall: pb.ResumeCall(callId: callId, result: result, values: values),
);

/// The Python exception a host callback's throw becomes.
pb.RaisedException _raisedFrom(Object error) => switch (error) {
  OsCallException(:final message, :final pythonExceptionType) =>
    pb.RaisedException(
      excType: pythonExceptionType ?? 'RuntimeError',
      message: message,
    ),
  _ => pb.RaisedException(excType: 'RuntimeError', message: '$error'),
};

/// Throws the in-band error a Python exception maps to.
Never _throwRaised(pb.RaisedException raised) {
  final traceback = [for (final f in raised.traceback) _frame(f)];
  final innermost = traceback.lastOrNull;
  final message = raised.hasMessage() ? raised.message : '';
  final exception = MontyException(
    message: message,
    excType: raised.excType,
    traceback: List.unmodifiable(traceback),
    filename: innermost?.filename,
    lineNumber: innermost?.startLine,
    columnNumber: innermost?.startColumn,
    sourceCode: innermost?.previewLine,
  );
  if (raised.excType == 'SyntaxError') {
    throw MontySyntaxError(
      message,
      excType: raised.excType,
      exception: exception,
    );
  }
  throw MontyScriptError(
    message,
    excType: raised.excType,
    exception: exception,
  );
}

MontyStackFrame _frame(pb.StackFrame f) => MontyStackFrame(
  filename: f.filename,
  startLine: f.start.line,
  startColumn: f.start.column,
  endLine: f.hasEnd() ? f.end.line : null,
  endColumn: f.hasEnd() ? f.end.column : null,
  frameName: f.hasFrameName() ? f.frameName : null,
  previewLine: f.hasPreviewLine() ? f.previewLine : null,
  hideCaret: f.hideCaret,
  hideFrameName: f.hideFrameName,
);
