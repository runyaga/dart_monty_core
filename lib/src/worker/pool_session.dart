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
import 'dart:collection';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/default_print.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/raised_record.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';

/// A Python session on a worker dedicated to it until [close].
///
/// Every call is async. Protocol turns are serialized, as upstream's are: a
/// [feedRun] made while another feed's turn is in flight waits for that
/// turn, then runs if the other feed has finished, or throws [StateError]
/// if it is suspended on a host call (upstream's "feed called while a
/// suspension is awaiting an answer"), or if the session closed meanwhile.
/// A [feedRun] made from inside one of its own session's print callbacks
/// throws [StateError] at once: that callback runs inside the turn.
///
/// A Python exception throws [MontyRuntimeError] (or [MontySyntaxError])
/// and the session stays usable. A dead worker throws [MontyCrashedError];
/// so does a turn that outlives the pool's `requestTimeout` or a duration
/// backstop, whose worker is killed (`timedOut`), and a worker that answers
/// against the protocol, which is discarded. A worker that exceeds its
/// memory limit throws [MontyRuntimeError] with a `MemoryError`. After any
/// of the last four the session is finished: its slot is free, and every
/// later call throws [StateError].
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
  /// system-sleep maximum (10 s by default). An `asyncio.sleep` is answered
  /// through the futures protocol, which this driver does not run yet; until
  /// it does, such a sleep is declined and raises in the sandbox.
  ///
  /// On a type-checking session a snippet the check rejects throws
  /// [MontyTypingError] without running; [skipTypeCheck] skips the check
  /// for this snippet. Past the session's
  /// `maxSuspensions` host calls the feed is aborted with an in-sandbox
  /// `RuntimeError`; a system sleep that would take the session's sleeps
  /// past `maxTotalSleep` aborts it with an in-sandbox `TimeoutError`.
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

  /// The turn in flight, if any: what [abandon] fails.
  Completer<pb.ChildEvent>? turn;

  /// Whether no call can run any more: closed, or the worker gone.
  bool get isFinished => closed || lease.isReleased;

  /// Kills the worker during a turn and fails that turn at once, so a close
  /// need not wait for a turn stuck in a print callback.
  void abandon() {
    lease.kill();
    final current = turn;
    if (current == null || current.isCompleted) return;
    current.completeError(
      crashedError(
        CrashCause.killed,
        detail: 'the session was closed during a turn',
      ),
      StackTrace.current,
    );
  }

  /// The worker is gone: free its slot (once), and report [crash] as the
  /// call's error, a memory-limit exit as upstream's `MemoryError`.
  MontyError end(MontyCrashedError crash) {
    lease.kill();
    if (crash.cause != CrashCause.outOfMemory) return crash;

    return recordError(
      const RaisedRecord(
        'MemoryError',
        'the worker exceeded its memory limit and was terminated',
        [],
      ),
    );
  }
}

final class _LeasedSession implements PoolSession {
  _LeasedSession(this._hold, this._channel, this._proto, this._sleepMax) {
    _channel.onSuspended = _handOff;
  }

  final _Hold _hold;
  final _SessionChannel _channel;
  final ProtoSession _proto;
  final Duration _sleepMax;
  Future<void>? _closing;

  /// The feed running now, if any.
  Future<MontyValue>? _active;

  /// Feeds waiting for the turn, oldest first (upstream's turn lock is
  /// first come, first served).
  final Queue<Completer<void>> _waiters = Queue();

  /// Whether the oldest waiter was just handed the turn and has not yet
  /// taken it: a new feed must queue behind it.
  bool _reserved = false;

  @override
  Future<MontyValue> feedRun(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, ProtoExternalFunction>? externals,
    ProtoPrintCallback? printCallback,
    ProtoOsCallHandler? os,
    bool skipTypeCheck = false,
  }) async {
    if (_inPrintCallback(this)) {
      throw StateError(
        'a print callback cannot call its own session: it runs inside the '
        'turn',
      );
    }
    if (_hold.isFinished) throw _finishedError();
    final queueFree = _waiters.isEmpty && !_reserved;
    if (_active != null || !queueFree) {
      // With nobody ahead and the running feed suspended on a host call,
      // upstream's turn lock is free and this feed would take it, then
      // refuse.
      if (queueFree && _suspended) throw _pendingError();
      await _waitForTurn();
      // From here to the drive's start is one synchronous step: the turn
      // stays reserved until this feed holds it, so no new feed can slip
      // in between.
      _reserved = false;
      if (_hold.isFinished || _active != null) _refuse();
    }
    final drive = _drive(
      code,
      inputs: inputs,
      externals: externals,
      printCallback: printCallback,
      os: os,
      skipTypeCheck: skipTypeCheck,
    );
    _active = drive;
    try {
      return await drive;
    } finally {
      _active = null;
      _handOff();
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    final lease = _hold.lease;
    _hold.closed = true;
    // Queued feeds fail as finished, one after another.
    _handOff();
    if (lease.isReleased) return;
    if (_channel.inTurn) return _hold.abandon();
    try {
      await lease.release();
    } on Object catch (_) {
      // The Reset failed and the lease killed the worker; the slot is free,
      // which is all a close promises (upstream swallows this too).
    }
  }

  /// Queues for the turn and waits to be handed it.
  Future<void> _waitForTurn() {
    final turn = Completer<void>();
    _waiters.add(turn);

    return turn.future;
  }

  /// Woken by a close, or by the running feed suspending: this feed cannot
  /// run, and the next waiter learns the same.
  Never _refuse() {
    _handOff();
    if (_hold.isFinished) throw _finishedError();
    throw _pendingError();
  }

  /// Whether the running feed is suspended on a host call.
  bool get _suspended =>
      _active != null && !_channel.inTurn && _channel.pendingSuspension;

  /// Hands the turn to the oldest waiting feed, which then starts, or
  /// fails and hands it on.
  void _handOff() {
    if (_waiters.isEmpty) return;
    _reserved = true;
    _waiters.removeFirst().complete();
  }

  Future<MontyValue> _drive(
    String code, {
    required Map<String, MontyValue>? inputs,
    required Map<String, ProtoExternalFunction>? externals,
    required ProtoPrintCallback? printCallback,
    required ProtoOsCallHandler? os,
    required bool skipTypeCheck,
  }) async {
    final print = printCallback ?? defaultPrint;
    try {
      final result = await _proto.feed(
        code,
        inputs: inputs ?? const {},
        externals: externals ?? const {},
        onOsCall: os,
        // Marked, so a call back into this session from inside it is
        // refused rather than left waiting on the turn it is part of.
        onPrint: (stream, text) => runZoned(
          () => print(stream, text),
          zoneValues: {
            _printZone: {..._printingSessions(), this},
          },
        ),
        options: FeedOptions(
          collectPrints: false,
          systemSleepMax: _sleepMax,
          skipTypeCheck: skipTypeCheck,
          abandoned: () => _hold.isFinished,
        ),
      );

      return result.value;
      // A dead worker ends the session; the error is mapped, not swallowed.
    } on MontyCrashedError catch (error, stack) {
      Error.throwWithStackTrace(_hold.end(error), stack);
    }
  }
}

StateError _finishedError() => StateError('the session is finished');

/// The zone key under which print callbacks record the sessions whose
/// turns they run inside: every enclosing one, so nesting keeps them all.
final Object _printZone = Object();

Set<Object> _printingSessions() =>
    (Zone.current[_printZone] as Set<Object>?) ?? const {};

bool _inPrintCallback(Object session) => _printingSessions().contains(session);

StateError _pendingError() =>
    StateError('feed called while a suspension is awaiting an answer');

/// The session's view of its worker: the lease's channel, with each turn
/// refused once the session is finished and bounded by its deadline.
///
/// It also keeps upstream's suspension budget: the session's suspensions are
/// counted, and one past `maxSuspensions` (default 1000) is not handed to
/// the driver. The feed is aborted in its place with an in-sandbox
/// `RuntimeError`, which the driver then sees as the turn's answer. Its
/// system sleeps are charged against `maxTotalSleep` the same way, before
/// they are waited: the one that would pass it aborts the feed with an
/// in-sandbox `TimeoutError`.
///
/// A turn's deadline is the pool's `requestTimeout`; an execution turn's is
/// also bounded by what the feed budget has left and by the turn budget,
/// each plus its grace (upstream's duration backstops). Past it the worker
/// is killed and the turn fails with [MontyCrashedError]. Time spent in
/// host callbacks is never counted: it falls between turns.
final class _SessionChannel implements MontyChannel {
  _SessionChannel(this._hold, this._options, this._config)
    : _sleepLimit = switch (_config.limits?.maxTotalSleep) {
        final limit? => nanosOf(limit),
        null => null,
      };

  /// Whether a protocol turn is in flight.
  bool inTurn = false;

  /// Whether the last turn ended in a suspension still awaiting the host's
  /// answer (upstream's `pending`).
  bool pendingSuspension = false;

  /// Called when a turn ends in a suspension: the turn is free while the
  /// host answers.
  void Function()? onSuspended;

  final _Hold _hold;
  final PoolOptions _options;
  final SessionConfig _config;

  /// Execution time the running feed has used, as the worker reported it:
  /// never lowered within a feed, so a worker cannot loosen its own
  /// backstop.
  Duration _feedUsed = Duration.zero;

  /// Suspensions this session has received.
  int _suspensions = 0;

  /// The system sleep this session has been charged, in nanoseconds as
  /// upstream's `Duration`; capped sleeps at their cap.
  BigInt _slept = BigInt.zero;

  /// The sleep budget in force, in nanoseconds: `maxTotalSleep`, tightened
  /// by any smaller limit a worker reply reports (upstream's
  /// `update_from`); null while there is none.
  BigInt? _sleepLimit;

  @override
  bool get isAlive => !_hold.isFinished && _hold.lease.channel.isAlive;

  @override
  Future<pb.ChildEvent> turn(
    pb.ParentRequest request, {
    PrintHandler? onPrint,
  }) async {
    if (_hold.isFinished) throw _finishedError();
    inTurn = true;
    pendingSuspension = false;
    try {
      // One deadline for the whole turn: print delivery, and an abort the
      // suspension budget sends in its place, as upstream's request_turn.
      // The turn ends at the first of: its own end, the deadline, a close.
      // The timer is cancelled however it ends, so a turn left waiting on
      // a print callback holds no timer.
      final limit = _deadline(request);
      final done = _hold.turn = Completer<pb.ChildEvent>();
      final timer = limit == null
          ? null
          : Timer(limit, () => _expire(done, limit));
      unawaited(_settle(done, _turnWithBudget(request, onPrint)));
      try {
        final event = await done.future;
        pendingSuspension = _isSuspension(event);

        return event;
      } finally {
        timer?.cancel();
        _hold.turn = null;
      }
    } finally {
      inTurn = false;
      if (pendingSuspension) onSuspended?.call();
    }
  }

  /// The session's close owns the worker's end; the driver never closes.
  @override
  Future<void> close() async => kill();

  @override
  void kill() => _hold.lease.kill();

  /// [request]'s turn-ending event; a suspension past the budget, or a
  /// system sleep past the sleep budget, is replaced by the reply to the
  /// `AbortFeed` sent in its place.
  Future<pb.ChildEvent> _turnWithBudget(
    pb.ParentRequest request,
    PrintHandler? onPrint,
  ) async {
    final channel = _hold.lease.channel;
    final event = await channel.turn(request, onPrint: onPrint);
    final used = Duration(microseconds: event.feedExecutionMicros.toInt());
    if (used > _feedUsed) _feedUsed = used;
    _adoptSleepLimit(event);
    if (!_isSuspension(event)) return event;
    final limits = _config.limits;
    final limit = limits?.maxSuspensions ?? defaultMaxSuspensions;
    final exceeded = ++_suspensions > limit
        ? _raised('RuntimeError', 'suspension limit $limit exceeded')
        : _chargeSleep(event);
    if (exceeded == null) return event;
    final reply = await channel.turn(
      pb.ParentRequest(abortFeed: pb.AbortFeed(exception: exceeded)),
      onPrint: onPrint,
    );
    final kind = reply.whichKind();
    if (kind == pb.ChildEvent_Kind.error) return reply;
    kill();
    throw protocolError(
      'worker answered AbortFeed with something other than an Error',
    );
  }

  /// Charges [event], if it is a system sleep, against the sleep budget
  /// (upstream's `charge_sleep`): the delay as the session will wait it, cut
  /// to the system-sleep maximum, a delay that is not a valid duration
  /// counting as that maximum. A sleep that would pass the budget is not
  /// charged; the exception to abort the feed with is returned instead.
  pb.RaisedException? _chargeSleep(pb.ChildEvent event) {
    if (event.whichKind() != pb.ChildEvent_Kind.osCall ||
        event.osCall.whichCall() != pb.OsCall_Call.systemSleep) {
      return null;
    }
    final cap = _config.systemSleepCapNanos;
    final requested = nanosFromSeconds(event.osCall.systemSleep.seconds) ?? cap;
    final delay = requested < cap ? requested : cap;
    final sum = _slept + delay;
    // Saturating, as Rust's Duration::saturating_add.
    final total = sum > durationMaxNanos ? durationMaxNanos : sum;
    final limit = _sleepLimit;
    if (limit != null && total > limit) {
      return _raised(
        'TimeoutError',
        'sleep limit exceeded: ${rustDurationNanos(total)} > '
            '${rustDurationNanos(limit)}',
      );
    }
    _slept = total;

    return null;
  }

  /// Tightens the sleep budget to the one [event] reports, if smaller: a
  /// reply can only lower it.
  void _adoptSleepLimit(pb.ChildEvent event) {
    if (!event.hasMaxTotalSleepMicros()) return;
    final reported =
        BigInt.parse(event.maxTotalSleepMicros.toStringUnsigned()) *
        BigInt.from(1000);
    final current = _sleepLimit;
    if (current == null || reported < current) _sleepLimit = reported;
  }

  /// The deadline passed: kill the worker and fail [done].
  void _expire(Completer<pb.ChildEvent> done, Duration limit) {
    kill();
    if (done.isCompleted) return;
    done.completeError(
      crashedError(
        CrashCause.killed,
        detail:
            'monty worker killed after exceeding request timeout of '
            '${rustDuration(limit)}',
        timedOut: true,
      ),
      StackTrace.current,
    );
  }

  Duration? _deadline(pb.ParentRequest request) {
    final timeout = _options.requestTimeout;
    if (!_isExecution(request)) return timeout;
    if (request.whichKind() == pb.ParentRequest_Kind.feed) {
      _feedUsed = Duration.zero;
    }
    final feed = _backstop(
      _config.limits?.maxFeedDuration,
      _feedUsed,
      _options.feedDurationLimitGrace,
    );
    final turn = _backstop(
      _config.limits?.maxTurnDuration,
      Duration.zero,
      _options.turnDurationLimitGrace,
    );

    return _earliest(_earliest(timeout, feed), turn);
  }
}

/// Turn-ending events that wait for a host answer.
bool _isSuspension(pb.ChildEvent event) => switch (event.whichKind()) {
  pb.ChildEvent_Kind.functionCall ||
  pb.ChildEvent_Kind.osCall ||
  pb.ChildEvent_Kind.nameLookup ||
  pb.ChildEvent_Kind.resolveFutures => true,
  _ => false,
};

/// The exception a feed is aborted with.
pb.RaisedException _raised(String type, String message) =>
    pb.RaisedException(excType: type, message: message);

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

/// Completes [done] with [work]'s outcome, unless it already ended; a
/// later outcome is dropped.
Future<void> _settle(
  Completer<pb.ChildEvent> done,
  Future<pb.ChildEvent> work,
) async {
  try {
    final event = await work;
    if (done.isCompleted) return;
    done.complete(event);
  } on Object catch (error, stack) {
    if (!done.isCompleted) done.completeError(error, stack);
  }
}
