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
import 'package:dart_monty_core/src/worker/arena_nodes.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/default_print.dart';
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/host_answers.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
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
  /// in a browser. A callback that throws gets no more text; the turn runs
  /// to its end, and then its error is thrown, whatever the turn's outcome.
  /// The session runs on if the turn completed or raised, and is finished if
  /// it ended suspended on a host call. A callback that never completes is
  /// ended by `requestTimeout` or [close], as any turn is.
  ///
  /// A request over the frame limit (256 MiB) is refused before it is sent,
  /// with [MontyRuntimeError] (`RuntimeError`). For [inputs] the session runs
  /// on. For a host function's answer the suspension stays pending: every
  /// later feed throws [StateError], and only [close] recovers the worker.
  ///
  /// A host function marked with [coroutine] is a coroutine, as an
  /// `async def` host function is upstream: a call the sandbox awaits with
  /// nothing else to run is awaited in place, any other gets a pending
  /// future the sandbox awaits later, settled when its Dart future
  /// completes.
  ///
  /// A `time.sleep` is waited by the session, cut to the OS policy's
  /// system-sleep maximum (10 s by default). An `asyncio.sleep` is waited
  /// the same way through the futures protocol, so sibling tasks run
  /// meanwhile.
  ///
  /// On a type-checking session a snippet the check rejects throws
  /// [MontyTypingError] without running; [skipTypeCheck] skips the check
  /// for this snippet. Past the session's
  /// `maxSuspensions` host calls the feed is aborted with an in-sandbox
  /// `RuntimeError`; a system sleep, either kind, that would take the
  /// session's sleeps past `maxTotalSleep` aborts it with an in-sandbox
  /// `TimeoutError`.
  Future<MontyValue> feedRun(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, ProtoExternalFunction>? externals,
    ProtoPrintCallback? printCallback,
    ProtoOsCallHandler? os,
    bool skipTypeCheck = false,
  });

  /// Starts [code] and returns at its first suspension, or its end: each
  /// host function call, OS call (system sleeps included), name lookup and
  /// wait on pending futures is a [MontySnapshot] for the caller to answer
  /// (upstream's `feed_start`). The parameters are [feedRun]'s; [externals]
  /// and [os] are kept for the snapshots' `resumeAuto`, never consulted
  /// otherwise.
  ///
  /// While a suspension is unanswered the session refuses a new feed with
  /// [StateError] ("feed called while a suspension is awaiting an
  /// answer"). The budgets, the deadlines and [close] apply to each resume
  /// as to a feed's turns.
  Future<MontySnapshot> feedStart(
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
  /// sends `Reset` and returns the worker to the pool. A call waiting on a
  /// host callback fails as finished at once; the callback is not
  /// interrupted, and its result is dropped when it comes. With a turn in
  /// flight it kills the worker, and that call fails with
  /// [MontyCrashedError] ([CrashCause.killed]). Never throws. Idempotent.
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
      config,
    );
    // A dead worker was mapped by the channel; any failure frees the slot.
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
  _LeasedSession(this._hold, this._channel, this._proto, this._config) {
    _channel.onSuspended = _handOff;
  }

  final _Hold _hold;
  final _SessionChannel _channel;
  final ProtoSession _proto;
  final SessionConfig _config;
  Future<void>? _closing;

  /// The feed or resume running now, if any.
  Future<Object?>? _active;

  /// The running call's outcome, which a close may fail before its drive
  /// ends.
  Completer<Object?>? _outcome;

  /// The running `feedRun`'s host side, whose sleeps a close ends.
  HostAnswers? _feedHost;

  /// The latest `feedStart`'s drive, whose sleeps a close ends.
  _FeedDrive? _snapshots;

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
  }) => _withTurn(
    () => _drive(
      code,
      inputs: inputs,
      host: _host(externals, os),
      printCallback: printCallback,
      skipTypeCheck: skipTypeCheck,
    ),
    feed: true,
  );

  @override
  Future<MontySnapshot> feedStart(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, ProtoExternalFunction>? externals,
    ProtoPrintCallback? printCallback,
    ProtoOsCallHandler? os,
    bool skipTypeCheck = false,
  }) {
    final drive = _FeedDrive(
      this,
      _host(externals, os),
      printCallback ?? defaultPrint,
    );
    _snapshots = drive;

    return _withTurn(
      () => drive.step(
        feedRequest(code, inputs ?? const {}, skipTypeCheck: skipTypeCheck),
      ),
      feed: true,
    );
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _hold.closed = true;
    // Sleeps end now: no timer outlives the session, and a drive waiting on
    // one goes on to fail as finished.
    _feedHost?.dispose();
    _snapshots?._host.dispose();
    // Queued feeds fail as finished, one after another.
    _handOff();
    // A host callback is running (no turn in flight): its call fails now,
    // and the callback's result, when it comes, is dropped.
    final pending = _outcome;
    if (!_channel.inTurn && pending != null && !pending.isCompleted) {
      pending.completeError(_finishedError(), StackTrace.current);
    }
    final lease = _hold.lease;
    if (lease.isReleased) return;
    if (_channel.inTurn) return _hold.abandon();
    try {
      await lease.release();
    } on Object catch (_) {
      // The Reset failed and the lease killed the worker; the slot is free,
      // which is all a close promises (upstream swallows this too).
    }
  }

  /// Runs [body] holding the turn, after any running drive or resume and
  /// any feed queued before it. A feed ([feed]) is refused while a
  /// suspension awaits an answer.
  Future<T> _withTurn<T>(
    Future<T> Function() body, {
    required bool feed,
  }) async {
    if (_inPrintCallback(this)) {
      throw StateError(
        'a print callback cannot call its own session: it runs inside the '
        'turn',
      );
    }
    if (_hold.isFinished) throw _finishedError();
    // Null when the turn is free now: no await, so the body below starts
    // in this same synchronous step and no other call can slip in.
    final wait = _turnWait(feed: feed);
    if (wait != null) {
      await wait;
      // From here to the body's start is one synchronous step: the turn
      // stays reserved until this call holds it, so no new feed can slip
      // in between.
      _reserved = false;
      if (_hold.isFinished || _active != null || (feed && _suspended)) {
        _refuse();
      }
    }
    // A body that throws before its first await (an input the writer
    // refuses) still releases the turn below.
    final run = Future.sync(body);
    // The call's own outcome: the body's, unless a close while a host
    // callback runs fails it first (the body then ends unwatched).
    final outcome = _outcome = Completer<Object?>();
    unawaited(_settle(outcome, run));
    _active = outcome.future;
    try {
      return await outcome.future as T;
    } finally {
      _active = null;
      _outcome = null;
      _handOff();
    }
  }

  /// What this call must wait on to hold the turn, or null when the turn
  /// is free now.
  ///
  /// With nobody ahead and the worker suspended (on a host call, or on an
  /// answer that was too large to send), upstream's turn lock is free and
  /// a [feed] would take it, then refuse: so it throws at once.
  Future<void>? _turnWait({required bool feed}) {
    final queueFree = _waiters.isEmpty && !_reserved;
    if (feed && queueFree && _suspended) throw _pendingError();

    return _active != null || !queueFree ? _waitForTurn() : null;
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

  /// Whether the worker waits for an answer to a suspension: the running
  /// feed's host call, or an answer that was refused as too large to send,
  /// which leaves the suspension pending after its feed failed.
  bool get _suspended => !_channel.inTurn && _channel.pendingSuspension;

  /// Hands the turn to the oldest waiting feed, which then starts, or
  /// fails and hands it on.
  void _handOff() {
    if (_waiters.isEmpty) return;
    _reserved = true;
    _waiters.removeFirst().complete();
  }

  /// The host side of one feed: [externals] and [os], and system sleeps
  /// waited up to the session's maximum.
  HostAnswers _host(
    Map<String, ProtoExternalFunction>? externals,
    ProtoOsCallHandler? os,
  ) => HostAnswers(
    externals: externals ?? const {},
    os: os,
    systemSleepMax: _config.systemSleepMax,
  );

  /// [print] marked, so a call back into this session from inside it is
  /// refused rather than left waiting on the turn it is part of.
  ProtoPrintCallback _printing(ProtoPrintCallback print) =>
      (stream, text) => runZoned(
        () => print(stream, text),
        zoneValues: {
          _printZone: {..._printingSessions(), this},
        },
      );

  Future<MontyValue> _drive(
    String code, {
    required Map<String, MontyValue>? inputs,
    required HostAnswers host,
    required ProtoPrintCallback? printCallback,
    required bool skipTypeCheck,
  }) async {
    _feedHost = host;
    try {
      // A dead worker is mapped and its slot freed by the session channel,
      // at the transport. A MontyCrashedError that reaches here unmapped was
      // thrown by a host callback, or by the driver after it killed the
      // worker; either passes through as is.
      final result = await _proto.drive(
        code,
        host,
        inputs: inputs ?? const {},
        onPrint: _printing(printCallback ?? defaultPrint),
        options: FeedOptions(
          collectPrints: false,
          skipTypeCheck: skipTypeCheck,
          abandoned: () => _hold.isFinished,
        ),
      );

      return result.value;
    } finally {
      if (identical(_feedHost, host)) _feedHost = null;
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

/// One `feedStart`'s drive: the session it runs on, the answers its
/// snapshots' `resumeAuto` gives (with the coroutines they started), and
/// where its prints go. It resumes the snapshots it hands out.
final class _FeedDrive implements SnapshotDriver {
  _FeedDrive(this._session, this._host, this._print);

  final _LeasedSession _session;
  final HostAnswers _host;
  final ProtoPrintCallback _print;

  /// The suspension the drive's unspent snapshot stands for. A resume spends
  /// its snapshot before the next one exists, so only the latest snapshot
  /// can be unspent.
  pb.ChildEvent _suspended = pb.ChildEvent();

  @override
  Future<MontySnapshot> resumeCall(
    FunctionSnapshot snapshot,
    ExternalResult result,
  ) {
    checkExternalResult(result);
    final callId = snapshot.callId;
    final request = switch (result) {
      ExternalReturnValue(:final value) => resumeValue(callId, value),
      ExternalException(:final excType, :final message) => resumeWith(
        callId,
        pb.ExtFunctionResult(
          error: pb.RaisedException(excType: excType, message: message),
        ),
      ),
      ExternalFuture() => resumeWith(
        callId,
        pb.ExtFunctionResult(future: callId),
      ),
    };

    return _resume(snapshot, request);
  }

  @override
  Future<MontySnapshot> resumeNotHandled(FunctionSnapshot snapshot) {
    if (!snapshot.isOsFunction) {
      throw StateError(
        'resume_not_handled() is only valid for OS function snapshots',
      );
    }

    return _resume(
      snapshot,
      resumeWith(
        snapshot.callId,
        pb.ExtFunctionResult(notHandled: pb.Unit()),
      ),
    );
  }

  @override
  Future<MontySnapshot> resumeCallAuto(FunctionSnapshot snapshot) async {
    snapshot.spend();
    // No host code for a session already finished; one that finishes while
    // it runs fails the turn below.
    if (_session._hold.isFinished) throw _finishedError();
    final event = _suspended;

    // Host code runs outside the protocol turn, as upstream's does, but
    // inside the session's call: a close meanwhile Resets the worker and
    // fails the resume at once, and the host's late answer is dropped.
    return _session._withTurn(() async {
      final request = snapshot.isOsFunction
          ? await _host.osCall(event.osCall, parentSleeps: false)
          : await _host.call(event.functionCall);

      return step(request);
    }, feed: false);
  }

  @override
  Future<MontySnapshot> resumeLookup(
    NameLookupSnapshot snapshot,
    MontyValue? value,
  ) {
    final pb.ParentRequest request;
    if (value == null) {
      request = pb.ParentRequest(
        resumeNameLookup: pb.ResumeNameLookup(undefined: pb.Unit()),
      );
    } else {
      final writer = ArenaWriter();
      final index = writer.add(value);
      request = pb.ParentRequest(
        resumeNameLookup: pb.ResumeNameLookup(
          values: writer.arena,
          value: index,
        ),
      );
    }

    return _resume(snapshot, request);
  }

  @override
  Future<MontySnapshot> resumeLookupAuto(NameLookupSnapshot snapshot) =>
      _resume(snapshot, _host.lookup(snapshot.variableName));

  @override
  Future<MontySnapshot> resumeFutures(
    FutureSnapshot snapshot,
    Map<int, ExternalSettledResult> results,
  ) {
    final answers = <(int, ExternalAnswer)>[];
    for (final MapEntry(:key, value: result) in results.entries) {
      checkExternalResult(result);
      switch (result) {
        case ExternalReturnValue(:final value):
          // Encoded alone first, so a value the writer refuses throws here,
          // before the snapshot is spent.
          ArenaWriter().add(value);
          answers.add((key, ExternalAnswer.value(value)));
        case ExternalException(:final excType, :final message):
          answers.add((
            key,
            ExternalAnswer.error(
              pb.RaisedException(excType: excType, message: message),
            ),
          ));
      }
    }

    return _resume(snapshot, futuresRequest(answers));
  }

  @override
  Future<MontySnapshot> resumeFuturesAuto(FutureSnapshot snapshot) async {
    snapshot.spend();
    if (_session._hold.isFinished) throw _finishedError();

    // The wait is inside the session's call, as resumeCallAuto's host code
    // is: a close meanwhile fails the resume at once.
    return _session._withTurn(() async {
      final pb.ParentRequest request;
      try {
        request = await _host.settle();
        // Nothing can settle the worker's wait: the session ends, as
        // upstream discards the checkout, and the error is rethrown.
        // ignore: avoid_catching_errors
      } on StateError {
        _session._hold.lease.kill();
        rethrow;
      }

      return step(request);
    }, feed: false);
  }

  /// Sends [request] as one turn and returns the snapshot of how it ended.
  /// A feed that ends, done or failed, ends its sleeps too.
  Future<MontySnapshot> step(pb.ParentRequest request) async {
    try {
      final snapshot = await _step(request);
      if (snapshot is SessionComplete) _host.dispose();

      return snapshot;
    } on Object {
      _host.dispose();
      rethrow;
    }
  }

  Future<MontySnapshot> _step(pb.ParentRequest request) async {
    final session = _session;
    // A dead worker, or a request too large to send, is mapped by the
    // session channel, at the transport.
    final event = await session._proto.step(
      request,
      onPrint: session._printing(_print),
      abandoned: () => session._hold.isFinished,
    );
    if (event.whichKind() == pb.ChildEvent_Kind.complete) {
      final complete = event.complete;

      return SessionComplete(session._proto.valueOf(complete));
    }
    _suspended = event;

    return _suspension(event);
  }

  /// Spends [snapshot] and sends [request], already built and checked.
  Future<MontySnapshot> _resume(
    SuspendedSnapshot snapshot,
    pb.ParentRequest request,
  ) {
    snapshot.spend();

    return _session._withTurn(() => step(request), feed: false);
  }

  /// The snapshot of the suspension [event].
  SuspendedSnapshot _suspension(pb.ChildEvent event) {
    final script = _session._config.scriptName;

    return switch (event.whichKind()) {
      pb.ChildEvent_Kind.functionCall => _callSnapshot(event.functionCall),
      pb.ChildEvent_Kind.osCall => _osSnapshot(event.osCall),
      pb.ChildEvent_Kind.nameLookup => NameLookupSnapshot(
        this,
        _position(event.nameLookup.position),
        script,
        variableName: event.nameLookup.name,
        objectId: event.nameLookup.hasObjectId()
            ? uuidString(event.nameLookup.objectId.data)
            : null,
      ),
      pb.ChildEvent_Kind.resolveFutures => FutureSnapshot(
        this,
        _position(event.resolveFutures.position),
        script,
        pendingCallIds: event.resolveFutures.pendingCallIds,
      ),
      // coverage:ignore-start
      // ProtoSession.step returns turn ends only, and step took Complete.
      _ => throw StateError('not a suspension: ${event.whichKind().name}'),
      // coverage:ignore-end
    };
  }

  FunctionSnapshot _callSnapshot(pb.FunctionCall call) => FunctionSnapshot(
    this,
    _position(call.position),
    _session._config.scriptName,
    functionName: call.functionName,
    callId: call.callId,
    isOsFunction: false,
    allowEagerAwait: call.allowEagerAwait,
    objectId: call.hasObjectId() ? uuidString(call.objectId.data) : null,
    arguments: () => callArgs(call),
    keywords: () => callKwargs(call),
  );

  FunctionSnapshot _osSnapshot(pb.OsCall call) {
    final (name, args, kwargs) = _osParts(call);

    return FunctionSnapshot(
      this,
      _position(call.position),
      _session._config.scriptName,
      functionName: name,
      callId: call.callId,
      isOsFunction: true,
      // A worker's eager bit on a call no future may answer is dropped, as
      // upstream drops it.
      allowEagerAwait: call.allowEagerAwait && acceptsFuture(name),
      arguments: () => args,
      keywords: () => kwargs,
    );
  }

  /// [call]'s name and arguments; a payload upstream could never produce is
  /// a protocol violation, which ends the session.
  OsCallParts _osParts(pb.OsCall call) {
    try {
      return osCallParts(call);
    } on FormatException catch (error) {
      _session._hold.lease.kill();
      throw protocolError('invalid OS call payload: ${error.message}');
    }
  }
}

/// [range] as a [SourceRange]; an unset one (a worker that predates the
/// field) is [SourceRange.unknown], as upstream reads it.
SourceRange _position(pb.SourceRange range) => range == pb.SourceRange()
    ? SourceRange.unknown
    : SourceRange(range.filename, range.start, range.end);

/// The session's view of its worker: the lease's channel, with each turn
/// refused once the session is finished and bounded by its deadline.
///
/// It also keeps upstream's suspension budget: the session's suspensions are
/// counted, and one past `maxSuspensions` (default 1000) is not handed to
/// the driver. The feed is aborted in its place with an in-sandbox
/// `RuntimeError`, which the driver then sees as the turn's answer. Its
/// system sleeps, `time.sleep` and `asyncio.sleep` alike, are charged
/// against `maxTotalSleep` the same way, before they are waited: the one
/// that would pass it aborts the feed with an in-sandbox `TimeoutError`. A
/// worker reply can only tighten either limit.
///
/// A turn's deadline is the pool's `requestTimeout`; an execution turn's is
/// also bounded by what the feed budget has left and by the turn budget,
/// each plus its grace (upstream's duration backstops). Past it the worker
/// is killed and the turn fails with [MontyCrashedError]. Time spent in
/// host callbacks is never counted: it falls between turns.
final class _SessionChannel implements MontyChannel {
  _SessionChannel(this._hold, this._options, this._config)
    : _suspensionLimit =
          _config.limits?.maxSuspensions ?? defaultMaxSuspensions,
      _sleepLimit = switch (_config.limits?.maxTotalSleep) {
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

  /// The suspension budget in force: `maxSuspensions`, tightened by any
  /// smaller limit a worker reply reports (upstream's `update_from`).
  int _suspensionLimit;

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
    final wasPending = pendingSuspension;
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
        pendingSuspension = isSuspension(event);

        return event;
      } on FrameTooLargeException catch (error, stack) {
        // Refused before a byte was written: the worker never saw it and
        // waits where it was, suspended or not (upstream's send_request).
        pendingSuspension = wasPending;
        Error.throwWithStackTrace(_oversized(error), stack);
        // The worker is gone: its slot is freed here, at the transport, so a
        // print failure the driver throws in its place cannot hold the slot,
        // and a host callback's own MontyCrashedError is never taken for it.
      } on MontyCrashedError catch (error, stack) {
        Error.throwWithStackTrace(_hold.end(error), stack);
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
    if (event.hasMaxSuspensions()) {
      final reported = event.maxSuspensions.toInt();
      if (reported < _suspensionLimit) _suspensionLimit = reported;
    }
    if (!isSuspension(event)) return event;
    final limit = _suspensionLimit;
    final exceeded = ++_suspensions > limit
        ? _raised('RuntimeError', 'suspension limit $limit exceeded')
        : _chargeSleep(event);
    if (exceeded == null) return event;
    final pb.ChildEvent reply;
    try {
      reply = await channel.turn(
        pb.ParentRequest(abortFeed: pb.AbortFeed(exception: exceeded)),
        onPrint: onPrint,
      );
    } on MontyCrashedError catch (crash) {
      // Lost while the abort was written: upstream's context says so.
      if (crash.context != sendingRequest) rethrow;
      throw inContext(crash, abortingFeed);
    }
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
    final seconds = _systemSleepSeconds(event);
    if (seconds == null) return null;
    final cap = _config.systemSleepCapNanos;
    final requested = nanosFromSeconds(seconds) ?? cap;
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

/// The delay of [event]'s system sleep, `time.sleep` or `asyncio.sleep`
/// (upstream charges both); null for any other event.
double? _systemSleepSeconds(pb.ChildEvent event) {
  if (event.whichKind() != pb.ChildEvent_Kind.osCall) return null;
  final call = event.osCall;

  return switch (call.whichCall()) {
    pb.OsCall_Call.systemSleep => call.systemSleep.seconds,
    pb.OsCall_Call.asyncSystemSleep => call.asyncSystemSleep.delay,
    _ => null,
  };
}

/// An oversized request, as upstream reports it: a `RuntimeError` the
/// caller can catch, the session still usable.
MontyError _oversized(FrameTooLargeException error) => recordError(
  RaisedRecord(
    'RuntimeError',
    'request frame of ${error.length} bytes exceeds the maximum of '
        '${error.max} bytes',
    const [],
  ),
);

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
Future<void> _settle<T>(Completer<T> done, Future<T> work) async {
  try {
    final event = await work;
    if (done.isCompleted) return;
    done.complete(event);
  } on Object catch (error, stack) {
    if (!done.isCompleted) done.completeError(error, stack);
  }
}
