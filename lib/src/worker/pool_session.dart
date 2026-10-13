/// One session per checkout: a Python session on a worker the pool has
/// dedicated to it, driven through its single [WorkerLease].
///
/// The interface becomes the public `MontySession` at the cutover; until
/// then it takes host functions in an internal map and its settings as
/// internal records.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';

import 'package:dart_monty_core/src/platform/monty_error.dart';
import 'package:dart_monty_core/src/platform/monty_exception.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/default_print.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';

/// A Python session on a worker dedicated to it until [close].
///
/// Every call is async. One call at a time: a second [feedRun] while one
/// runs, or one made from inside a print callback, throws [StateError].
///
/// A Python exception throws [MontyScriptError] and the session stays
/// usable. A dead worker throws [MontyCrashedError]; so does a turn that
/// outlives the pool's `requestTimeout` or a duration backstop, whose worker
/// is killed. A worker that exceeds its memory limit throws
/// [MontyScriptError] with `excType` `MemoryError`. After either of the last
/// two the session is finished: its slot is free, and every later call
/// throws [StateError].
abstract interface class PoolSession {
  /// Runs [code] to completion and returns its value: the last expression's,
  /// or [MontyNone].
  ///
  /// [inputs] are bound as global names first. A call to a name in
  /// [externals] runs that function, outside the turn: it may take as long
  /// as it likes, and `requestTimeout` does not count it. [os] answers OS
  /// calls; without it they are declined.
  ///
  /// [printCallback] receives each run of printed text, in order, and its
  /// future is awaited before the next event is read. Without one, the text
  /// goes to the process's stdout and stderr on native and to the console
  /// in a browser.
  ///
  /// A `time.sleep` is waited by the session, cut to the OS policy's
  /// system-sleep maximum (10 s by default). On a type-checking session a
  /// snippet the check rejects throws [MontyTypeCheckError] without running;
  /// [skipTypeCheck] skips the check for this snippet. Past the session's
  /// `maxSuspensions` host calls the feed is aborted with an in-sandbox
  /// `RuntimeError`.
  Future<MontyValue> feedRun(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, ProtoExternalFunction>? externals,
    ProtoPrintCallback? printCallback,
    ProtoOsCallHandler? os,
    bool skipTypeCheck = false,
  });

  /// Ends the session and gives its slot back, exactly once.
  ///
  /// With no protocol turn in flight (idle, or a host callback running) it
  /// sends `Reset` and returns the worker to the pool; a drive suspended on
  /// a host callback then fails as finished when the callback returns, and
  /// the callback's result is dropped. With a turn in flight it kills the
  /// worker, and that call fails with [MontyCrashedError]
  /// ([CrashCause.killed]). Never throws. Idempotent.
  Future<void> close();
}

/// A session's resource limits, sent to the worker in `Configure`; null
/// leaves the worker's default.
///
/// An internal record until the cutover, when C3's `ResourceLimits`
/// replaces it.
final class SessionLimits {
  /// The limits; see each field.
  const SessionLimits({
    this.maxMemoryBytes,
    this.maxRecursionDepth,
    this.maxFeedDuration,
    this.maxTurnDuration,
    this.maxSuspensions,
  });

  /// The interpreter's heap limit.
  final int? maxMemoryBytes;

  /// The interpreter's recursion limit.
  final int? maxRecursionDepth;

  /// The longest one feed may execute.
  final Duration? maxFeedDuration;

  /// The longest one turn may execute; each answer to a host call starts a
  /// new turn.
  final Duration? maxTurnDuration;

  /// How many times the session may suspend for the host before the parent
  /// aborts its feed; null is upstream's default, 1000.
  final int? maxSuspensions;
}

/// Configures a session on [lease]'s worker; on failure the worker is
/// killed and its slot freed before the error is rethrown.
Future<PoolSession> openPoolSession(
  WorkerLease lease,
  PoolOptions options,
  SessionConfig config,
) async {
  final hold = _Hold(lease);
  final channel = _SessionChannel(hold, options, config);
  try {
    return _LeasedSession(
      hold,
      channel,
      await ProtoSession.open(channel, config),
      config.systemSleepMax,
    );
    // A dead worker is an outcome to map here, as upstream maps it.
    // ignore: avoid_catching_errors
  } on MontyCrashedError catch (error, stack) {
    Error.throwWithStackTrace(hold.end(error), stack);
  } on Object {
    lease.kill();
    rethrow;
  }
}

/// A session's hold on its worker: the lease, and whether the session was
/// closed. Shared by the session and its channel.
final class _Hold {
  _Hold(this.lease);

  final WorkerLease lease;

  /// Whether [_LeasedSession.close] ran.
  bool closed = false;

  final _abandoned = Completer<pb.ChildEvent>();

  /// Whether no call can run any more: closed, or the worker gone.
  bool get isFinished => closed || lease.isReleased;

  /// Fails, never completes normally, once [abandon] runs: the turn in
  /// flight races it, so a close need not wait for a turn stuck in a print
  /// callback.
  Future<pb.ChildEvent> get abandoned => _abandoned.future;

  /// Kills the worker during a turn and fails that turn at once.
  void abandon() {
    lease.kill();
    if (_abandoned.isCompleted) return;
    // Nobody may be listening if the turn ended meanwhile.
    _abandoned.future.ignore();
    _abandoned.completeError(
      MontyCrashedError(
        CrashCause.killed,
        message: 'the session was closed during a turn',
      ),
      StackTrace.current,
    );
  }

  /// The worker is gone: free its slot (once), and report [crash] as the
  /// call's error, a memory-limit exit as upstream's `MemoryError`.
  Object end(MontyCrashedError crash) {
    lease.kill();
    if (crash.cause != CrashCause.outOfMemory) return crash;
    const message = 'the worker exceeded its memory limit and was terminated';

    return const MontyScriptError(
      message,
      excType: 'MemoryError',
      exception: MontyException(message: message, excType: 'MemoryError'),
    );
  }
}

final class _LeasedSession implements PoolSession {
  _LeasedSession(this._hold, this._channel, this._proto, this._sleepMax);

  final _Hold _hold;
  final _SessionChannel _channel;
  final ProtoSession _proto;
  final Duration _sleepMax;
  Future<void>? _closing;

  @override
  Future<MontyValue> feedRun(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, ProtoExternalFunction>? externals,
    ProtoPrintCallback? printCallback,
    ProtoOsCallHandler? os,
    bool skipTypeCheck = false,
  }) async {
    if (_hold.isFinished) throw _finishedError();
    try {
      final result = await _proto.feed(
        code,
        inputs: inputs ?? const {},
        externals: externals ?? const {},
        onOsCall: os,
        onPrint: printCallback ?? defaultPrint,
        options: FeedOptions(
          collectPrints: false,
          systemSleepMax: _sleepMax,
          skipTypeCheck: skipTypeCheck,
        ),
      );

      return result.value;
      // A dead worker ends the session; the error is mapped, not swallowed.
      // ignore: avoid_catching_errors
    } on MontyCrashedError catch (error, stack) {
      Error.throwWithStackTrace(_hold.end(error), stack);
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    final lease = _hold.lease;
    _hold.closed = true;
    if (lease.isReleased) return;
    if (_channel.inTurn) return _hold.abandon();
    try {
      await lease.release();
    } on Object catch (_) {
      // The Reset failed and the lease killed the worker; the slot is free,
      // which is all a close promises (upstream swallows this too).
    }
  }
}

StateError _finishedError() => StateError('the session is finished');

/// The session's view of its worker: the lease's channel, with each turn
/// refused once the session is finished and bounded by its deadline.
///
/// It also keeps upstream's suspension budget: the session's suspensions are
/// counted, and one past `maxSuspensions` (default 1000) is not handed to
/// the driver. The feed is aborted in its place with an in-sandbox
/// `RuntimeError`, which the driver then sees as the turn's answer.
///
/// A turn's deadline is the pool's `requestTimeout`; an execution turn's is
/// also bounded by what the feed budget has left and by the turn budget,
/// each plus its grace (upstream's duration backstops). Past it the worker
/// is killed and the turn fails with [MontyCrashedError]. Time spent in
/// host callbacks is never counted: it falls between turns.
final class _SessionChannel implements MontyChannel {
  _SessionChannel(this._hold, this._options, this._config);

  /// Whether a protocol turn is in flight.
  bool inTurn = false;

  final _Hold _hold;
  final PoolOptions _options;
  final SessionConfig _config;

  /// Execution time the running feed has used, as the worker reported it:
  /// never lowered within a feed, so a worker cannot loosen its own
  /// backstop.
  Duration _feedUsed = Duration.zero;

  /// Suspensions this session has received.
  int _suspensions = 0;

  @override
  bool get isAlive => !_hold.isFinished && _hold.lease.channel.isAlive;

  @override
  Future<pb.ChildEvent> turn(
    pb.ParentRequest request, {
    PrintHandler? onPrint,
  }) async {
    if (_hold.isFinished) throw _finishedError();
    inTurn = true;
    try {
      // One deadline for the whole turn: print delivery, and an abort the
      // suspension budget sends in its place, as upstream's request_turn.
      final limit = _deadline(request);
      final work = _turnWithBudget(request, onPrint);
      final bounded = limit == null
          ? work
          : work.timeout(limit, onTimeout: () => _expire(limit));

      return await Future.any([bounded, _hold.abandoned]);
    } finally {
      inTurn = false;
    }
  }

  /// The session's close owns the worker's end; the driver never closes.
  @override
  Future<void> close() async => kill();

  @override
  void kill() => _hold.lease.kill();

  /// [request]'s turn-ending event; a suspension past the budget is
  /// replaced by the reply to the `AbortFeed` sent in its place.
  Future<pb.ChildEvent> _turnWithBudget(
    pb.ParentRequest request,
    PrintHandler? onPrint,
  ) async {
    final channel = _hold.lease.channel;
    final event = await channel.turn(request, onPrint: onPrint);
    final used = Duration(microseconds: event.feedExecutionMicros.toInt());
    if (used > _feedUsed) _feedUsed = used;
    if (!_isSuspension(event)) return event;
    final limit = _config.maxSuspensions ?? defaultMaxSuspensions;
    if (++_suspensions <= limit) return event;
    final reply = await channel.turn(_abort(limit), onPrint: onPrint);
    final kind = reply.whichKind();
    if (kind == pb.ChildEvent_Kind.error) return reply;
    kill();
    throw MontyCrashedError(
      CrashCause.killed,
      message: 'protocol desync: AbortFeed was answered with ${kind.name}',
    );
  }

  Never _expire(Duration limit) {
    kill();
    throw MontyCrashedError(
      CrashCause.killed,
      message: 'no reply within $limit; the worker was killed',
    );
  }

  Duration? _deadline(pb.ParentRequest request) {
    final timeout = _options.requestTimeout;
    if (!_isExecution(request)) return timeout;
    if (request.whichKind() == pb.ParentRequest_Kind.feed) {
      _feedUsed = Duration.zero;
    }
    final feed = _backstop(
      _config.maxFeedDuration,
      _feedUsed,
      _options.feedDurationLimitGrace,
    );
    final turn = _backstop(
      _config.maxTurnDuration,
      Duration.zero,
      _options.turnDurationLimitGrace,
    );

    return _earliest(_earliest(timeout, feed), turn);
  }
}

/// Upstream's `DEFAULT_MAX_SUSPENSIONS`.
const int defaultMaxSuspensions = 1000;

/// Turn-ending events that wait for a host answer.
bool _isSuspension(pb.ChildEvent event) => switch (event.whichKind()) {
  pb.ChildEvent_Kind.functionCall ||
  pb.ChildEvent_Kind.osCall ||
  pb.ChildEvent_Kind.nameLookup ||
  pb.ChildEvent_Kind.resolveFutures => true,
  _ => false,
};

/// Aborts the running feed past [limit] suspensions, with upstream's
/// exception.
pb.ParentRequest _abort(int limit) => pb.ParentRequest(
  abortFeed: pb.AbortFeed(
    exception: pb.RaisedException(
      excType: 'RuntimeError',
      message: 'suspension limit $limit exceeded',
    ),
  ),
);

/// Requests that run sandbox code, which the duration backstops bound.
bool _isExecution(pb.ParentRequest request) => switch (request.whichKind()) {
  pb.ParentRequest_Kind.feed ||
  pb.ParentRequest_Kind.resumeCall ||
  pb.ParentRequest_Kind.resumeNameLookup ||
  pb.ParentRequest_Kind.resumeFutures => true,
  _ => false,
};

/// What [budget] has left after [used], plus [grace]; null when either the
/// budget or its grace is unset.
Duration? _backstop(Duration? budget, Duration used, Duration? grace) {
  if (budget == null || grace == null) return null;
  final left = budget - used;

  return (left.isNegative ? Duration.zero : left) + grace;
}

Duration? _earliest(Duration? a, Duration? b) {
  if (a == null) return b;
  if (b == null) return a;

  return a < b ? a : b;
}
