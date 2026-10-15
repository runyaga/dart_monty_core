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
import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/collect_streams.dart';
import 'package:dart_monty_core/src/worker/host_answers.dart';
import 'package:dart_monty_core/src/worker/host_objects.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/os_policy.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/raised_record.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';

export 'package:dart_monty_core/src/worker/host_answers.dart'
    show OsHandler, ProtoExternalFunction, coroutine;

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

  /// The host objects sent into this session, by id: the registry its
  /// inputs, answers and results resolve through. A load empties it.
  final HostObjects objects = HostObjects();

  final MontyChannel _channel;
  final SessionConfig _config;
  bool _busy = false;

  /// Whether the worker's working directory has been established: a feed
  /// reached it and was not refused by the type check. Until then each feed
  /// carries [defaultCwd]; afterwards none does, and the worker keeps its
  /// directory, `os.chdir` included (upstream's `Checkout.cwd_set`).
  bool _cwdSet = false;

  /// Configures a session on [channel].
  ///
  /// Throws [ArgumentError] for a setting upstream refuses, before anything
  /// is sent. A refusal from the worker is raised as any error is (a
  /// [MontyRuntimeError], say), and the worker is killed.
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
  /// [inputs] are bound as global names before the code runs: each a
  /// [MontyValue] or a host object's wrapper, which registers in [objects].
  /// A call to a
  /// name in [externals] runs that function and answers with its value, or,
  /// for a function marked with [coroutine], settles it through the futures
  /// protocol ([HostAnswers]). [onOsCall] answers OS calls, which are
  /// declined without it. [onPrint] sees each run of printed text as it
  /// arrives, and its future is awaited before the next one; the result
  /// also lists them all, unless [FeedOptions.collectPrints] is false.
  ///
  /// A failing [onPrint] follows upstream's binding: later prints are not
  /// delivered, the turn is still read to its end, and then the failure is
  /// thrown in place of the turn's outcome. The session survives a turn that
  /// completed or raised; one that ended suspended kills the worker.
  ///
  /// [options] adjust the feed (see [FeedOptions]). A snippet a
  /// type-checking session's check rejects throws [MontyTypingError].
  Future<FeedResult> feed(
    String code, {
    Map<String, Object> inputs = const {},
    Map<String, ProtoExternalFunction> externals = const {},
    OsHandler? onOsCall,
    ProtoPrintCallback? onPrint,
    FeedOptions options = const FeedOptions(),
  }) => drive(
    code,
    HostAnswers(
      externals: externals,
      os: onOsCall,
      systemSleepMax: options.systemSleepMax,
      objects: objects,
    ),
    inputs: inputs,
    onPrint: onPrint,
    options: options,
  );

  /// Runs [code] as [feed] does, its suspensions answered by [host], which
  /// is disposed when the feed ends. [FeedOptions.systemSleepMax] is
  /// [host]'s, not [options]'.
  Future<FeedResult> drive(
    String code,
    HostAnswers host, {
    Map<String, Object> inputs = const {},
    ProtoPrintCallback? onPrint,
    FeedOptions options = const FeedOptions(),
  }) => _guard(() async {
    final sink = _PrintSink(
      onPrint,
      collect: options.collectPrints,
      abandoned: options.abandoned,
    );
    var request = feedRequest(
      code,
      inputs,
      skipTypeCheck: options.skipTypeCheck,
      objects: objects,
    );
    try {
      for (;;) {
        final event = _turnEnd(await _feedTurn(request, sink));
        if (event.whichKind() == pb.ChildEvent_Kind.complete) {
          return FeedResult(
            valueOf(event.complete),
            List.unmodifiable(sink.prints),
          );
        }
        // A ResolveFutures with no coroutine started is out of step with
        // this driver (upstream discards the checkout).
        request =
            await host.answer(event) ??
            _violation('unexpected event: ${event.whichKind().name}');
      }
    } finally {
      host.dispose();
    }
  });

  /// Sends [request] as one turn and returns how it ended: `Complete` or a
  /// suspension. A Python exception throws as [feed]'s do; prints go to
  /// [onPrint] as [feed]'s do. For step-by-step driving.
  Future<pb.ChildEvent> step(
    pb.ParentRequest request, {
    ProtoPrintCallback? onPrint,
    bool Function()? abandoned,
  }) => _guard(() async {
    final sink = _PrintSink(onPrint, collect: false, abandoned: abandoned);

    return _turnEnd(await _feedTurn(request, sink));
  });

  /// The value [complete] carries, its host objects found through [hosts]
  /// (default: this session's); one that does not decode is a protocol
  /// violation (upstream's "invalid payload from worker").
  MontyValue valueOf(pb.Complete complete, {HostObjectLookup? hosts}) {
    try {
      return ArenaReader(
        complete.values,
        hosts: hosts ?? objects.lookup,
      )[complete.value];
    } on FormatException catch (e) {
      _violation('invalid payload from worker: ${e.message}');
    }
  }

  /// Drops all session state, then configures a fresh session on the same
  /// worker.
  Future<void> reset() => _guard(() async {
    final event = await _channel.turn(pb.ParentRequest(reset: pb.Reset()));
    if (event.whichKind() != pb.ChildEvent_Kind.ok) _desync('Reset', event);
    // A new session, as upstream's next checkout of the worker is.
    _cwdSet = false;
    objects.clear();
    await _configure();
  });

  /// Ends the worker. Idempotent.
  Future<void> close() => _channel.close();

  /// One turn of a feed, its prints to [sink]. A print failure is thrown in
  /// place of the turn's outcome, a crash included; a suspension the failed
  /// feed leaves is never answered, so the worker is killed rather than
  /// left waiting.
  ///
  /// A `Feed` without a `cwd` is given [defaultCwd] while the session's
  /// working directory is not yet established, as upstream's pool does.
  Future<pb.ChildEvent> _feedTurn(
    pb.ParentRequest request,
    _PrintSink sink,
  ) async {
    final feed = request.whichKind() == pb.ParentRequest_Kind.feed;
    if (feed && !_cwdSet && request.feed.cwd.isEmpty) {
      request.feed.cwd = defaultCwd;
    }
    final pb.ChildEvent event;
    try {
      event = await _channel.turn(request, onPrint: sink.add);
    } on Object {
      sink.rethrowFailure();
      rethrow;
    }
    // The worker adopts the directory after its type check and before it
    // runs the code, so every reply but a typing rejection means it took
    // effect. A request never sent (oversized) threw above.
    if (feed && event.whichKind() != pb.ChildEvent_Kind.typingError) {
      _cwdSet = true;
    }
    if (sink.failed && isSuspension(event)) _channel.kill();
    sink.rethrowFailure();

    return event;
  }

  Future<void> _configure() async {
    final request = pb.ParentRequest(configure: _config._toProto());
    final event = await _channel.turn(request);
    final kind = event.whichKind();
    if (kind == pb.ChildEvent_Kind.ok) return;
    if (kind != pb.ChildEvent_Kind.error) _desync('Configure', event);
    // Raised as any error is (upstream's PoolError::Runtime); the failed
    // checkout discards the worker, as upstream's drop does.
    _channel.kill();
    _throwRaised(event.error);
  }

  /// [event] when it ends a feed's turn (`Complete` or a suspension);
  /// throws the error it reports otherwise.
  pb.ChildEvent _turnEnd(pb.ChildEvent event) => switch (event.whichKind()) {
    pb.ChildEvent_Kind.complete ||
    pb.ChildEvent_Kind.nameLookup ||
    pb.ChildEvent_Kind.functionCall ||
    pb.ChildEvent_Kind.osCall ||
    pb.ChildEvent_Kind.resolveFutures => event,
    pb.ChildEvent_Kind.error => _throwRaised(event.error),
    // Whatever the session's type check, as upstream classifies it.
    pb.ChildEvent_Kind.typingError => throw typingError(
      event.typingError.diagnostics,
    ),
    // Never sent without the request that asks for it (dumps), or not
    // a feed's answer at all.
    _ => _violation('unexpected event: ${event.whichKind().name}'),
  };

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

/// Moving a session between workers: [dump] and [load], upstream's `Dump`
/// and `Load`.
extension ProtoSessionTransfer on ProtoSession {
  /// The session, idle or suspended, as the worker's opaque bytes
  /// (upstream's `Dump`); a pending suspension stays pending.
  ///
  /// Not one of the session's requests: a pool session's dump runs between
  /// the turns of a feed, as upstream's does, and the caller keeps it off a
  /// turn in flight. An error the worker reports in place of the bytes is
  /// thrown, and the session runs on.
  Future<Uint8List> dump() async {
    final event = await _channel.turn(pb.ParentRequest(dump: pb.Dump()));

    return switch (event.whichKind()) {
      pb.ChildEvent_Kind.dumpResult => Uint8List.fromList(
        event.dumpResult.state,
      ),
      pb.ChildEvent_Kind.error => _throwRaised(event.error),
      _ => _desync('Dump', event),
    };
  }

  /// Restores [state], a dump, into this fresh session (upstream's `Load`):
  /// the re-announced suspension, or null for a dump taken between feeds,
  /// with the dump's script name when the worker reports it.
  ///
  /// The dump carries the session's working directory. An error the worker
  /// reports in place of the load (bytes it cannot read) is thrown, and the
  /// session runs on as it was.
  Future<(pb.ChildEvent?, String?)> load(List<int> state) => _guard(() async {
    // Host objects are never part of a dump: a loaded session starts with
    // none (upstream's instance store starts empty).
    objects.clear();
    final event = await _channel.turn(
      pb.ParentRequest(load: pb.Load(state: state)),
    );
    final kind = event.whichKind();
    if (kind == pb.ChildEvent_Kind.error) _throwRaised(event.error);
    if (kind != pb.ChildEvent_Kind.ok && !isSuspension(event)) {
      _desync('Load', event);
    }
    // The adopted dump carries the working directory (checkout.rs
    // `restore`, only once the load succeeded).
    _cwdSet = true;

    return (
      kind == pb.ChildEvent_Kind.ok ? null : event,
      event.hasRestoredScriptName() ? event.restoredScriptName : null,
    );
  });
}

/// Collects a feed's prints and passes each to the caller's callback,
/// awaiting it before the next.
///
/// A throwing callback must not escape into the channel mid-turn. As in
/// upstream's binding, the first failure is recorded and later prints are
/// dropped; the turn runs to its end, and the driver then throws the
/// failure, converted by [printFailure] when it was thrown, as upstream's
/// print target converts it at once.
///
/// Nothing more is delivered once the feed is abandoned (its worker killed
/// by a deadline or a close while a callback ran): a callback that finally
/// returns does not lead to the next one, and one that finally throws is
/// not recorded.
final class _PrintSink {
  _PrintSink(
    this._onPrint, {
    required bool collect,
    bool Function()? abandoned,
  }) : _collect = collect,
       _abandoned = abandoned;

  final List<(String, String)> prints = [];
  final ProtoPrintCallback? _onPrint;
  final bool Function()? _abandoned;
  final bool _collect;
  (MontyError, StackTrace)? _failure;

  /// Names this feed's print delivery ([deliverPrint]). A token of its own,
  /// so an overflow marked with it does not keep the sink alive.
  final Object _delivery = Object();

  Future<void> add(pb.Print print) async {
    for (final segment in print.segments) {
      if (_failure != null || _isAbandoned) return;
      final stream = segment.stream == pb.PrintStream.PRINT_STREAM_STDERR
          ? 'stderr'
          : 'stdout';
      if (_collect) prints.add((stream, segment.text));
      final onPrint = _onPrint;
      if (onPrint == null) continue;
      try {
        await deliverPrint(_delivery, () => onPrint(stream, segment.text));
      } on Object catch (error, stack) {
        // A failure from a callback that ended after the feed was abandoned
        // is ignored, like any late result: the abandonment is the outcome.
        if (!_isAbandoned) _failure = (printFailure(error, _delivery), stack);

        return;
      }
    }
  }

  /// Whether the caller has given up on the feed.
  bool get _isAbandoned => _abandoned?.call() ?? false;

  /// Whether the callback failed.
  bool get failed => _failure != null;

  /// Throws the callback's failure, if there was one, with the callback's
  /// stack.
  void rethrowFailure() {
    if (_failure case (final error, final stack)) {
      Error.throwWithStackTrace(error, stack);
    }
  }
}

/// The error a print callback's throw [error] is raised as, in place of the
/// feed's outcome, as upstream's binding raises a print failure
/// (`finalize_turn`): a [MontyError] built from the Python exception
/// upstream's `exc_py_to_monty` would classify it as.
///
/// - An overflow a collector threw during [delivery], this feed's print
///   delivery ([isCollectorOverflow]), is raised as it is: the
///   `MemoryError` upstream's collectors raise.
/// - Any other throw is classified as a host function's is ([raisedFrom]):
///   an `ExternalException` raises its type and message, anything else
///   `Exception` with its `toString()`. A `SyntaxError` is
///   [MontySyntaxError], as upstream's `MontyError::new_err` raises it, and
///   every other type [MontyRuntimeError]. Neither has a traceback. The
///   record never crosses the wire, so its data is kept as the host gave it
///   ([RaisedRecord.fromHost]).
MontyError printFailure(Object error, Object delivery) =>
    isCollectorOverflow(error, delivery)
    ? error as MontyError
    : recordError(RaisedRecord.fromHost(raisedFrom(error)));

/// Whether [event] ends a turn in a suspension that waits for the host's
/// answer (upstream's `left_suspended`).
bool isSuspension(pb.ChildEvent event) => switch (event.whichKind()) {
  pb.ChildEvent_Kind.functionCall ||
  pb.ChildEvent_Kind.osCall ||
  pb.ChildEvent_Kind.nameLookup ||
  pb.ChildEvent_Kind.resolveFutures => true,
  _ => false,
};

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

/// The working directory a session's first feed switches to: upstream's
/// default with no mounts, which a worker session never has.
const String defaultCwd = '/';

/// The `Feed` request running [code] with [inputs] bound first; a host
/// object's wrapper among them registers in [objects].
///
/// Encoded as upstream's pool encodes it: the arena always present (empty
/// without inputs) and proto3 defaults left out, as prost leaves them out.
/// The `cwd` is the session's to add (see [ProtoSession]).
pb.ParentRequest feedRequest(
  String code,
  Map<String, Object> inputs, {
  bool skipTypeCheck = false,
  HostObjects? objects,
}) {
  final feed = pb.Feed();
  if (code.isNotEmpty) feed.code = code;
  if (skipTypeCheck) feed.skipTypeCheck = true;
  final writer = ArenaWriter(objects: objects);
  for (final MapEntry(:key, :value) in inputs.entries) {
    final index = encodingInput(() => writer.add(value));
    feed.inputs.add(
      pb.NamedRef(
        name: key.isEmpty ? null : key,
        value: index == 0 ? null : index,
      ),
    );
  }
  feed.values = writer.arena;

  return pb.ParentRequest(feed: feed);
}

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
