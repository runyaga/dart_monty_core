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
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/host_answers.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/os_policy.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
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
    Map<String, MontyValue> inputs = const {},
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
    Map<String, MontyValue> inputs = const {},
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

  /// The value [complete] carries; one that does not decode is a protocol
  /// violation (upstream's "invalid payload from worker").
  MontyValue valueOf(pb.Complete complete) {
    try {
      return ArenaReader(complete.values)[complete.value];
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
    // The worker refused a setting: one only it can check (an IANA zone
    // name, against its zone database), so the caller's argument.
    _channel.kill();
    throw ArgumentError(event.error.exception.message);
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
    // Only a type-checking session's feed may end this way.
    pb.ChildEvent_Kind.typingError when _config.typeCheck => throw typingError(
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

/// Collects a feed's prints and passes each to the caller's callback,
/// awaiting it before the next.
///
/// A throwing callback must not escape into the channel mid-turn. As in
/// upstream's binding, the first failure is recorded and later prints are
/// dropped; the turn runs to its end, and the driver then throws the
/// failure.
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
  (Object, StackTrace)? _failure;

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
        await onPrint(stream, segment.text);
      } on Object catch (error, stack) {
        // A failure from a callback that ended after the feed was abandoned
        // is ignored, like any late result: the abandonment is the outcome.
        if (!_isAbandoned) _failure = (error, stack);

        return;
      }
    }
  }

  /// Whether the caller has given up on the feed.
  bool get _isAbandoned => _abandoned?.call() ?? false;

  /// Whether the callback failed.
  bool get failed => _failure != null;

  /// Throws the callback's failure, if there was one.
  void rethrowFailure() {
    if (_failure case (final error, final stack)) {
      Error.throwWithStackTrace(error, stack);
    }
  }
}

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

/// The `Feed` request running [code] with [inputs] bound first.
///
/// Encoded as upstream's pool encodes it: the arena always present (empty
/// without inputs) and proto3 defaults left out, as prost leaves them out.
/// The `cwd` is the session's to add (see [ProtoSession]).
pb.ParentRequest feedRequest(
  String code,
  Map<String, MontyValue> inputs, {
  bool skipTypeCheck = false,
}) {
  final feed = pb.Feed();
  if (code.isNotEmpty) feed.code = code;
  if (skipTypeCheck) feed.skipTypeCheck = true;
  final writer = ArenaWriter();
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
