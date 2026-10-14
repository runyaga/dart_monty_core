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

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_exception.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/os_policy.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/resource_limits.dart';

/// The monty-proto schema version this driver speaks: upstream's
/// `PROTOCOL_VERSION` at the pinned tag.
const int protocolVersion = 5;

/// What the driver reports as its version in `Configure`. Informational
/// only; the worker never checks it.
const String _driverVersion = 'dart_monty_core';

/// One Python session on one worker.
///
/// A Python exception in fed code throws [MontyRuntimeError] (or
/// [MontySyntaxError]) carrying the traceback, and the session stays usable.
/// A worker that answers against the protocol is killed, and the call
/// throws [MontyCrashedError] with upstream's `monty worker protocol error`
/// message.
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
  ///
  /// Throws [ArgumentError] for a setting upstream refuses, before anything
  /// is sent, and for one the worker refuses (an IANA zone name it does not
  /// know), killing the worker.
  static Future<ProtoSession> open(
    MontyChannel channel, [
    SessionConfig config = const SessionConfig(),
  ]) async {
    config.validate();
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
  /// result also lists them all, unless [FeedOptions.collectPrints] is false.
  ///
  /// [options] adjust the feed (see [FeedOptions]). A snippet a
  /// type-checking session's check rejects throws [MontyTypingError].
  Future<FeedResult> feed(
    String code, {
    Map<String, MontyValue> inputs = const {},
    Map<String, ProtoExternalFunction> externals = const {},
    ProtoOsCallHandler? onOsCall,
    ProtoPrintCallback? onPrint,
    FeedOptions options = const FeedOptions(),
  }) => _guard(() async {
    final sink = _PrintSink(
      onPrint,
      _channel.kill,
      collect: options.collectPrints,
      abandoned: options.abandoned,
    );
    final feed = _feedRequest(code, inputs);
    if (options.skipTypeCheck) feed.skipTypeCheck = true;
    final systemSleepMax = options.systemSleepMax;
    var request = pb.ParentRequest(feed: feed);
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
        return FeedResult(
          _value(event.complete),
          List.unmodifiable(sink.prints),
        );
      }
      request = await _answer(event, externals, onOsCall, systemSleepMax);
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
    final kind = event.whichKind();
    if (kind == pb.ChildEvent_Kind.ok) return;
    if (kind != pb.ChildEvent_Kind.error) _desync('Configure', event);
    // The worker refused a setting: one only it can check (an IANA zone
    // name, against its zone database), so the caller's argument.
    _channel.kill();
    throw ArgumentError(event.error.exception.message);
  }

  /// The request that answers a suspension [event] during a feed.
  Future<pb.ParentRequest> _answer(
    pb.ChildEvent event,
    Map<String, ProtoExternalFunction> externals,
    ProtoOsCallHandler? onOsCall,
    Duration? systemSleepMax,
  ) async => switch (event.whichKind()) {
    pb.ChildEvent_Kind.error => _throwRaised(event.error),
    // Only a type-checking session's feed may end this way.
    pb.ChildEvent_Kind.typingError when _config.typeCheck => throw typingError(
      event.typingError.diagnostics,
    ),
    pb.ChildEvent_Kind.nameLookup => _answerNameLookup(
      event.nameLookup.name,
      externals,
    ),
    pb.ChildEvent_Kind.functionCall => await _answerCall(
      event.functionCall,
      externals,
    ),
    pb.ChildEvent_Kind.osCall
        when systemSleepMax != null &&
            event.osCall.whichCall() == pb.OsCall_Call.systemSleep =>
      await _sleep(event.osCall, systemSleepMax),
    pb.ChildEvent_Kind.osCall => await _answerOsCall(event.osCall, onOsCall),
    // Never sent without the request that asks for it (futures, type
    // checking, dumps), or not a feed's answer at all.
    _ => _violation('unexpected event: ${event.whichKind().name}'),
  };

  /// The value [complete] carries; one that does not decode is a protocol
  /// violation (upstream's "invalid payload from worker").
  MontyValue _value(pb.Complete complete) {
    try {
      return ArenaReader(complete.values)[complete.value];
    } on FormatException catch (e) {
      _violation('invalid payload from worker: ${e.message}');
    }
  }

  /// Throws the error an `Error` event is. One whose exception fails
  /// upstream's checks is a protocol violation, and the worker is killed.
  Never _throwRaised(pb.Error event) {
    if (!event.hasException()) _violation('error event with no exception');
    final error = raisedError(event.exception);
    if (error is MontyCrashedError) _channel.kill();
    throw error;
  }

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

  /// The worker answered [request] with an event that cannot follow it.
  Never _desync(String request, pb.ChildEvent event) =>
      _violation('unexpected reply to $request: ${event.whichKind().name}');

  /// The worker answered against the protocol, so its state is unknown:
  /// kill it rather than guess (upstream's `protocol_violation`).
  Never _violation(String detail) {
    _channel.kill();
    throw protocolError(detail);
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
///
/// Nothing more is delivered once the feed is abandoned (its worker killed
/// by a deadline or a close while a callback ran): a callback that finally
/// returns does not lead to the next one.
final class _PrintSink {
  _PrintSink(
    this._onPrint,
    this._kill, {
    required bool collect,
    bool Function()? abandoned,
  }) : _collect = collect,
       _abandoned = abandoned;

  final List<(String, String)> prints = [];
  final ProtoPrintCallback? _onPrint;
  final void Function() _kill;
  final bool Function()? _abandoned;
  final bool _collect;
  (Object, StackTrace)? _failure;

  Future<void> add(pb.Print print) async {
    for (final segment in print.segments) {
      if (_failure != null || (_abandoned?.call() ?? false)) return;
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

/// How one [ProtoSession.feed] runs.
final class FeedOptions {
  /// The options; see each field.
  const FeedOptions({
    this.collectPrints = true,
    this.systemSleepMax,
    this.skipTypeCheck = false,
    this.abandoned,
  });

  /// Whether [FeedResult.prints] lists everything printed.
  final bool collectPrints;

  /// When set, a `time.sleep` the worker hands to the parent is waited by
  /// the driver, cut to this length, and answered with `None` (upstream's
  /// automatic driver); when null the sleep is declined.
  final Duration? systemSleepMax;

  /// Whether a type-checking session skips the check for this snippet.
  final bool skipTypeCheck;

  /// Whether the caller has given up on the feed; once true, no further
  /// print is delivered.
  final bool Function()? abandoned;
}

/// Waits a system sleep, cut to [max], and answers it with `None`.
Future<pb.ParentRequest> _sleep(pb.OsCall call, Duration max) async {
  final seconds = call.systemSleep.seconds;
  // A delay that is not a finite, non-negative number waits the ceiling,
  // as upstream counts an invalid worker delay.
  final micros = seconds.isFinite && seconds >= 0
      ? seconds * Duration.microsecondsPerSecond
      : double.infinity;
  final wait = micros >= max.inMicroseconds
      ? max
      : Duration(microseconds: micros.round());
  await Future<void>.delayed(wait);

  return _resumeValue(call.callId, const MontyNone());
}

/// Session settings, sent to the worker in `Configure`: the parameters of
/// upstream's `checkout`, as one record until the cutover.
final class SessionConfig {
  /// Creates the settings. A null setting keeps upstream's default.
  const SessionConfig({
    this.scriptName = 'main.py',
    this.limits,
    this.typeCheck = false,
    this.typeCheckStubs,
    this.typeCheckFormat,
    this.typeCheckColor = false,
    this.assertMessageAnnotations,
    this.printFlushInterval,
    this.osPolicy,
  });

  /// The file name tracebacks report for fed code.
  final String scriptName;

  /// The session's resource limits; null leaves every one off, the
  /// recursion depth and suspensions at 1000.
  final ResourceLimits? limits;

  /// Whether each fed snippet is type-checked before it runs.
  final bool typeCheck;

  /// Stub file contents for the type check.
  final String? typeCheckStubs;

  /// How the type check renders its diagnostics: one of [typeCheckFormats],
  /// ASCII case ignored; null is `full`.
  final String? typeCheckFormat;

  /// Whether the `full` and `concise` diagnostics carry ANSI colour.
  final bool typeCheckColor;

  /// How many bytes of each operand an `assert` failure message shows; 0
  /// turns the annotations off (upstream's `False`), null keeps the
  /// worker's default (120, upstream's `True`).
  final int? assertMessageAnnotations;

  /// How long the worker may hold printed text before it sends it; zero
  /// sends each line as it ends, null keeps the worker's default.
  final Duration? printFlushInterval;

  /// The clock, zone, sleep and randomness the session gets; null is
  /// upstream's default policy.
  final OsPolicy? osPolicy;

  /// The longest one `time.sleep` the parent waits for this session: the
  /// policy's system-sleep maximum, else upstream's 10 s.
  Duration get systemSleepMax =>
      osPolicy?.systemSleepMax ?? const OsPolicy().systemSleepMax;

  /// The longest one system sleep is charged, in nanoseconds (see
  /// [OsPolicy.systemSleepCapNanos]).
  BigInt get systemSleepCapNanos =>
      (osPolicy ?? const OsPolicy()).systemSleepCapNanos;

  /// Throws [ArgumentError] for a setting upstream refuses, with upstream's
  /// message, before any frame is sent.
  void validate() {
    limits?.validate();
    final format = typeCheckFormat;
    if (format != null) parseTypeCheckFormat(format);
    validateAssertMessageAnnotations(assertMessageAnnotations);
    validatePrintFlushInterval(printFlushInterval);
    osPolicy?.validate();
  }

  pb.Configure _toProto() {
    final flush = printFlushInterval;
    final format = typeCheckFormat;

    return pb.Configure(
      scriptName: scriptName,
      protocolVersion: protocolVersion,
      montyVersion: _driverVersion,
      limits: limits?.toProto(),
      assertMessageAnnotations: assertMessageAnnotations,
      printFlushIntervalMs: flush == null ? null : printFlushIntervalMs(flush),
      typeCheck: typeCheck ? true : null,
      typeCheckStubs: typeCheckStubs,
      typeCheckFormat: format == null ? null : parseTypeCheckFormat(format),
      typeCheckColor: typeCheckColor ? true : null,
      osPolicy: osPolicy?.toProto(),
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

/// Throws [ArgumentError] for a negative print flush interval, with
/// upstream's message.
void validatePrintFlushInterval(Duration? interval) {
  final refusal = interval == null ? null : durationRefusal(interval);
  if (refusal != null) {
    throw ArgumentError.value(
      interval,
      'printFlushInterval',
      'invalid print_flush_interval: $refusal',
    );
  }
}

/// The wire's flush interval in milliseconds: 0 for zero, else at least 1
/// and at most `u32::MAX` (upstream's `flush_interval_ms`).
int printFlushIntervalMs(Duration interval) {
  if (interval == Duration.zero) return 0;
  final ms = interval.inMilliseconds;
  if (ms < 1) return 1;

  return ms > _u32Max ? _u32Max : ms;
}

const int _u32Max = 0xffffffff;

/// Throws [ArgumentError] unless [value] is in 0..2^32 - 1, with upstream's
/// message. (Upstream spells 0 `False`, which this `int?` takes as 0.)
void validateAssertMessageAnnotations(int? value) {
  if (value != null && (value < 0 || value > _u32Max)) {
    throw ArgumentError.value(
      value,
      'assertMessageAnnotations',
      'assert_message_annotations int value must be between 1 and 2**32 - 1',
    );
  }
}

/// The diagnostic formats `typeCheckFormat` takes, as upstream names them.
const Map<String, pb.TypeCheckFormat> typeCheckFormats = {
  'full': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_FULL,
  'concise': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_CONCISE,
  'azure': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_AZURE,
  'json': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_JSON,
  'jsonlines': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_JSON_LINES,
  'rdjson': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_RDJSON,
  'pylint': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_PYLINT,
  'gitlab': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_GITLAB,
  'github': pb.TypeCheckFormat.TYPE_CHECK_FORMAT_GITHUB,
};

/// The format [name] names, matched as upstream matches it (ASCII case
/// ignored, `json-lines` also accepted); throws [ArgumentError] with
/// upstream's message for any other name.
pb.TypeCheckFormat parseTypeCheckFormat(String name) {
  final key = _asciiLower(name);

  return typeCheckFormats[key == 'json-lines' ? 'jsonlines' : key] ??
      (throw ArgumentError.value(
        name,
        'typeCheckFormat',
        "unknown type check format '$name', expected one of: "
            '${typeCheckFormats.keys.join(', ')}',
      ));
}

String _asciiLower(String s) => String.fromCharCodes(
  s.codeUnits.map((c) => c >= 0x41 && c <= 0x5a ? c + 0x20 : c),
);
