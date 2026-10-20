/// One session per checkout: a Python session on a worker the pool has
/// dedicated to it, driven through its single [WorkerLease].
///
/// [MontySession] is exported; the rest is internal to the package.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:dart_monty_core/src/mount/mount_dir.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_nodes.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart'
    show ArenaReader, HostObjectLookup;
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/default_print.dart';
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/frame_scan.dart'
    show cutSourceFilename;
import 'package:dart_monty_core/src/worker/host_answers.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/raised_record.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/telemetry_channel.dart';
import 'package:dart_monty_core/src/worker/telemetry_recorder.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:fixnum/fixnum.dart';

/// A Python session on a worker dedicated to it until [close].
///
/// Every call is async. One call holds the session's turn at a time, as
/// upstream's turn lock serializes turns; a call made while another holds
/// it queues, first come first served. Whole feeds are not serialized: a
/// feed that suspends and is resumed spans several turns, and while a
/// host call is answered it holds no turn. A queued feed runs only when
/// the calls ahead of it end. A suspension wakes the queue at once: each
/// waiting feed throws [StateError] (upstream's "feed called while
/// a suspension is awaiting an answer") instead of waiting for the
/// answer — and a feed that arrives while a suspension awaits, with
/// nobody ahead of it, throws at once rather than queues. A close wakes
/// the queue too, and each waiting feed then fails as finished. A
/// [feedRun] made from inside one of its own session's print callbacks
/// throws [StateError] at once: that callback runs inside the turn.
///
/// A Python exception throws [MontyRuntimeError] (or [MontySyntaxError])
/// and the session stays usable. A dead worker throws [MontyCrashedError];
/// so does a turn that outlives the pool's `requestTimeout` or a duration
/// backstop, whose worker is killed (`timedOut`), and a worker that answers
/// against the protocol, which is discarded. A worker whose allocator
/// refuses an allocation over its hard limit exits with upstream's
/// `OOM_EXIT_CODE` (65), and the call throws [MontyRuntimeError] with a
/// `MemoryError`. After any of the last four the session is finished: its
/// slot is free, and every later call throws [StateError].
///
/// Two limits end in that `MemoryError`, and only the allocator's ends the
/// session. The interpreter's heap limit ([ResourceLimits.maxMemory])
/// raises `MemoryError` in the sandbox, as any Python exception does: the
/// error carries the sandbox's traceback and message, and the session
/// stays usable. The allocator's `MemoryError` is the parent's own record:
/// the fixed message `the worker exceeded its memory limit and was
/// terminated`, no traceback, the session finished. (A print collector's
/// overflow is a third `MemoryError`, no traceback either; [feedRun] says
/// when the session runs on.)
///
/// A frame failure maps by direction. A request too large to frame (over
/// 256 MiB) never reaches the worker: it is refused before it is sent and
/// the call throws [MontyRuntimeError] (`RuntimeError`), the session as it
/// was — a resume it refuses leaves its suspension pending
/// ([MontySnapshot]). A reply that cannot be framed or decoded — over the
/// limit, truncated, malformed — is a worker that cannot be trusted: the
/// call throws [MontyCrashedError] and the session is finished, as any
/// dead worker's is.
///
/// A feed's `externalLookup` resolves the names the code leaves undefined,
/// lazily, when the code reads one (upstream's `external_lookup`); a name in
/// `inputs` too is served by the input. An entry is a [MontyValue]: a host
/// function ([MontyHostFunction]), whose `fn` takes the call's positional and
/// keyword arguments and returns a `FutureOr<MontyValue>`, or any other value,
/// a host object's wrapper included. A read of a host function gives a
/// function named by its key (its docstring kept), and a
/// call to that name runs the entry, outside the turn: it may take as long as
/// it likes, and `requestTimeout` does not count it. A read of a value converts
/// it then and binds it as a global, so later feeds see it without the lookup.
/// The lookup and the call are two steps, each its own suspension under
/// `feedStart` (a [NameLookupSnapshot], then a [FunctionSnapshot]): the read
/// binds the name, and only the call runs the entry.
/// A call to a name whose entry is a value raises `TypeError` ("'int' object is
/// not callable"), and an absent name raises `NameError`. A value the converter
/// refuses (a cyclic list, an unpaired surrogate) is not answered: the feed
/// throws its [MontyRuntimeError], which a sandbox `try` does not catch, and
/// the session is finished, as upstream discards the checkout.
///
/// A host function whose `fn` is marked with `coroutine` is a coroutine, as an
/// `async def` host function is upstream: a call the sandbox awaits with
/// nothing else to run is awaited in place, any other gets a pending future
/// the sandbox awaits later, settled when its Dart future completes.
///
/// A feed's `cwd` switches the sandbox's working directory before the code
/// runs: an absolute POSIX path, its trailing slashes trimmed, that
/// `os.getcwd()` reports and relative paths resolve against. It lasts across
/// feeds, `os.chdir` included, until a feed switches it; without one a feed
/// keeps the current directory. Until cwd is established, it defaults to the
/// first mount's virtual path, or `/` with no mounts. A typing rejection
/// does not establish cwd; a sent syntax/runtime error does. A successful
/// session or snapshot restore establishes the dump's cwd. A relative path or
/// one with a NUL throws [MontyRuntimeError] (`ValueError`) before the code
/// runs or a mount table is built, and the session runs on. An unpaired
/// surrogate throws [ArgumentError] (upstream's `UnicodeEncodeError`) before
/// anything else.
/// Each feed's `mount` table is tried before its OS handler. Overlay data
/// and write budgets are discarded when the feed ends. A closed mount throws
/// [StateError]; overlapping mounts throw [MontyRuntimeError].
abstract interface class MontySession {
  /// Runs [code] to completion and returns its value: the last expression's,
  /// or [MontyNone].
  ///
  /// [inputs] are bound as global names first: values, host objects'
  /// wrappers ([ClassInstance], [ClassType]) among them, whose members the
  /// session serves.
  ///
  /// [externalLookup] resolves the names the code leaves undefined, and
  /// [cwd] switches the working directory first (see the class
  /// documentation).
  ///
  /// [os] answers OS calls; without it they are declined.
  ///
  /// [printCallback] receives each run of printed text as `(stream, text)`,
  /// `stream` `'stdout'` or `'stderr'`, in order. It takes any function of
  /// type `FutureOr<void> Function(String stream, String text)`; no named
  /// type is exported for it. A callback that returns a future is awaited
  /// before the next run is delivered. Without one, the text goes to the
  /// process's stdout and stderr on native and to the console in a browser.
  /// A callback that throws gets no more text; the
  /// turn runs to its end, then its error is thrown as a [MontyError]: a
  /// collector's overflow as its `MemoryError` ([MontyRuntimeError]), an
  /// [ExternalException] as its Python type (as `Exception` when upstream
  /// knows no such type), any other throw as `Exception` with its text — a
  /// [MontySyntaxError] for a `SyntaxError`, a [MontyRuntimeError]
  /// otherwise. None of them carries a traceback. The session runs on if the
  /// turn completed or raised, and is finished if it ended suspended on a
  /// host call. A callback that never completes is ended as a turn is: by
  /// the turn's deadline — `requestTimeout` or a duration backstop,
  /// whichever is earliest — or by [close]; each kills the worker.
  ///
  /// A request over the frame limit (256 MiB) is refused before it is sent,
  /// with [MontyRuntimeError] (`RuntimeError`). For [inputs] the session runs
  /// on. For a host function's answer the suspension stays pending: every
  /// later feed throws [StateError], and only [close] recovers the worker.
  ///
  /// A system sleep is waited by the session, cut to the OS policy's
  /// system-sleep maximum (10 s by default). The two system-sleep calls
  /// are `system.sleep` and `system.async_sleep`; the async one is waited
  /// through the futures protocol, so sibling tasks run meanwhile, as an
  /// `asyncio.sleep` is.
  ///
  /// On a type-checking session a snippet the check rejects throws
  /// [MontyTypingError] without running; [skipTypeCheck] skips the check
  /// for this snippet. Past the session's
  /// `maxSuspensions` host calls the feed is aborted with an in-sandbox
  /// `RuntimeError`; a system sleep, either kind, that would take the
  /// session's sleeps past `maxTotalSleep` aborts it with an in-sandbox
  /// `TimeoutError`. The parent counts both budgets, cumulatively over
  /// the whole checkout — every feed and resume included, never per feed
  /// — with 1000 suspensions by default and no sleep budget unless one is
  /// set. Neither abort is catchable in the sandbox; each arrives as
  /// [MontyRuntimeError], and the session runs on.
  Future<MontyValue> feedRun(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, MontyValue>? externalLookup,
    ProtoPrintCallback? printCallback,
    List<MountDir>? mount,
    String? cwd,
    OsHandler? os,
    bool skipTypeCheck = false,
  });

  /// Starts [code] and returns at its first suspension, or its end: each
  /// host function call, OS call (system sleeps included), name lookup and
  /// wait on pending futures is a [MontySnapshot] for the caller to answer
  /// (upstream's `feed_start`). The parameters are [feedRun]'s; [cwd] holds
  /// for the whole feed, and [externalLookup] and [os] are kept for the
  /// snapshots' `resumeAuto`, never consulted otherwise. The feed's mount
  /// table, overlay and budgets last across its resumes too, and unlike
  /// [feedRun] a `resumeAuto` does not wait a system sleep itself but sends
  /// it to the mounts and `os`, named `system.sleep` or `system.async_sleep`.
  ///
  /// While a suspension is unanswered the session refuses a new feed with
  /// [StateError] ("feed called while a suspension is awaiting an
  /// answer"). The budgets, the deadlines and [close] apply to each resume
  /// as to a feed's turns.
  Future<MontySnapshot> feedStart(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, MontyValue>? externalLookup,
    ProtoPrintCallback? printCallback,
    List<MountDir>? mount,
    String? cwd,
    OsHandler? os,
    bool skipTypeCheck = false,
  });

  /// Restores [state], a dump taken between feeds, into this session
  /// (upstream's `load_session`). The dump brings its own globals, script
  /// name, type check and working directory; this session's settings for
  /// them no longer apply. Of its limits, the feed and turn durations
  /// replace this checkout's, while this checkout's `maxSuspensions` and
  /// `maxTotalSleep` stay as ceilings the dump's own limits only tighten;
  /// both budgets restart from zero.
  ///
  /// Only for a fresh session: once it has been fed or loaded, a load
  /// throws [StateError]. A dump taken mid-feed throws [StateError] too, and
  /// the session is then finished. Bytes the worker cannot load throw
  /// [MontyRuntimeError], and the session runs on, still unloaded.
  ///
  /// The bytes are trusted: load only an unmodified dump from a compatible
  /// producer whose provenance the caller has checked. Loading does not
  /// validate them, and an invalid dump has no guarantee of correctness or
  /// availability.
  Future<void> loadSession(Uint8List state);

  /// Restores [state], a dump taken mid-feed (by [dump] while a suspension
  /// waited, or by a snapshot's `dump`), and returns the suspension it
  /// re-announces (upstream's `load_snapshot`). [mount] supplies fresh tables:
  /// dumps carry neither mounts nor overlay data, nor host objects — the
  /// caller re-registers any the restored suspension names. [externalLookup],
  /// [os] and [printCallback] are [feedStart]'s, kept for the snapshots'
  /// `resumeAuto` (the dump carries its working directory);
  /// a restored [FutureSnapshot]'s coroutines are gone, so its `resumeAuto`
  /// fails: settle it through `resume`.
  ///
  /// As [loadSession]: only for a fresh session, the same trust contract,
  /// and a dump taken between feeds throws [StateError] and finishes the
  /// session. The re-announced suspension counts against the dump's
  /// suspension budget, under this session's limit as a ceiling: with a
  /// limit of 0 it aborts the load with an in-sandbox `RuntimeError`.
  Future<MontySnapshot> loadSnapshot(
    Uint8List state, {
    List<MountDir>? mount,
    Map<String, MontyValue>? externalLookup,
    ProtoPrintCallback? printCallback,
    OsHandler? os,
  });

  /// The session, idle or suspended, as opaque bytes that [loadSession] or
  /// [loadSnapshot] restores, in this worker or another (upstream's
  /// `dump`). The session runs on as it was.
  ///
  /// It runs between protocol turns, so a host function may dump its own
  /// session while its call waits; from inside a print callback it throws
  /// [StateError]. An error the worker reports instead (a dump too large to
  /// send) is thrown as [MontyRuntimeError], and the session is unchanged.
  Future<Uint8List> dump();

  /// Installs [requirements], PEP 508 strings, for the session's later feeds
  /// (upstream's `install_dependencies`).
  ///
  /// An empty list succeeds. Core's worker is the pure-Monty sandbox, which
  /// has no host interpreter to install for, so any other list throws
  /// [MontyRuntimeError] (`RuntimeError`: "dependency installation is only
  /// supported by the CPython worker") and the session runs on. Each
  /// requirement is checked first, in order, as upstream's pool checks it: a
  /// blank one, or one starting with `-` after trimming (uv would read an
  /// option), throws [MontyRuntimeError] (`ValueError`) with upstream's
  /// text; one with an unpaired surrogate throws [ArgumentError]
  /// (upstream's `UnicodeEncodeError`) before any is checked.
  ///
  /// While a suspension is unanswered it throws [StateError]
  /// ("install_dependencies called while a suspension is awaiting an
  /// answer"); a finished session throws [StateError] too.
  Future<void> installDependencies(List<String> requirements);

  /// The worker's process id: diagnostics and tests. Null on the web, once
  /// the session is finished, and while a protocol turn is in flight.
  int? get workerPid;

  /// Ends the session and gives its slot back, exactly once.
  ///
  /// With no protocol turn in flight (idle, or a host callback running) it
  /// sends `Reset` and returns the worker to the pool, waiting for the
  /// reply up to the pool's `requestTimeout` — without one, as long as the
  /// worker takes. A closed pool keeps no idle worker: with no checkout
  /// waiting, the worker is killed at once, without a `Reset`; with one
  /// waiting, it is reset and handed to that checkout. A call waiting on a
  /// host callback fails as finished at once; the callback is not
  /// interrupted, and its result is dropped when it comes. With a turn in
  /// flight — a dump made from host code included — it kills the worker,
  /// and that call fails with a [MontyCrashedError] whose message is
  /// 'monty worker killed: the session was closed during a turn'. Never
  /// throws. Idempotent.
  ///
  /// A session collected without a close has its worker killed and its
  /// slot freed by a finalizer. That is a backstop only: a finalizer may
  /// never run, so every session must still be closed.
  Future<void> close();
}

/// Configures a session on [lease]'s worker; on failure the worker is
/// killed and its slot freed before the error is rethrown.
Future<MontySession> openPoolSession(
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
    lease.kill(reason: 'discarded', outcome: 'error');
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

  /// Whether the session has been fed or loaded: a load is only for a fresh
  /// session (upstream's `used`).
  bool used = false;

  /// The turn in flight, if any: what [abandon] fails.
  Completer<pb.ChildEvent>? turn;

  /// Whether no call can run any more: closed, or the worker gone.
  bool get isFinished => closed || lease.isReleased;

  /// Claims the session for a load, which only a fresh one takes.
  void claimFresh() {
    if (used) {
      throw StateError(
        'load_session / load_snapshot is only valid on a fresh session, '
        'before any feed_run / feed_start / load_session / load_snapshot',
      );
    }
    used = true;
  }

  /// Kills the worker during a turn and fails that turn at once, so a close
  /// need not wait for a turn stuck in a print callback.
  void abandon() {
    lease.kill();
    final current = turn;
    if (current == null || current.isCompleted) return;
    current.completeError(
      crashedError(
        CrashCause.killed,
        detail: 'monty worker killed: the session was closed during a turn',
      ),
      StackTrace.current,
    );
  }

  /// The worker is gone: free its slot (once), and report [crash] as the
  /// call's error, a memory-limit exit as upstream's `MemoryError`.
  MontyError end(MontyCrashedError crash) {
    lease.kill(reason: 'discarded', outcome: 'error');
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

/// Kills the worker of a session collected without [MontySession.close] and
/// frees its slot (q2). Its token is the session's lease, not the session,
/// so it takes the lease's one exactly-once release. Best effort: a
/// finalizer may never run, so a session must still be closed.
final Finalizer<WorkerLease> _dropped = Finalizer((lease) => lease.kill());

final class _LeasedSession implements MontySession {
  _LeasedSession(this._hold, this._channel, this._proto, this._config) {
    _channel.onSuspended = _handOff;
    // A live snapshot holds its drive, and so this session: a suspended
    // run is never collected.
    _dropped.attach(this, _hold.lease, detach: _hold);
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
  int? get workerPid =>
      _hold.isFinished || _channel.inTurn ? null : _hold.lease.pid;

  @override
  Future<MontyValue> feedRun(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, MontyValue>? externalLookup,
    ProtoPrintCallback? printCallback,
    List<MountDir>? mount,
    String? cwd,
    OsHandler? os,
    bool skipTypeCheck = false,
  }) => Future.sync(() {
    checkCwdText(cwd);
    _hold.used = true;

    return _withTurn(
      () {
        // Prepare inputs and cwd before opening a feed's mount table.
        final request = _proto.prepareFeed(
          code,
          inputs ?? const {},
          cwd: cwd,
          firstMount: mount?.firstOrNull?.virtualPath,
          skipTypeCheck: skipTypeCheck,
        );

        return _drive(
          request,
          host: _hostFor(_proto, _config, externalLookup, os, mount),
          printCallback: printCallback,
        );
      },
      feed: true,
    );
  });

  @override
  Future<MontySnapshot> feedStart(
    String code, {
    Map<String, MontyValue>? inputs,
    Map<String, MontyValue>? externalLookup,
    ProtoPrintCallback? printCallback,
    List<MountDir>? mount,
    String? cwd,
    OsHandler? os,
    bool skipTypeCheck = false,
  }) => Future.sync(() {
    checkCwdText(cwd);
    _hold.used = true;

    return _withTurn(
      () {
        final request = _proto.prepareFeed(
          code,
          inputs ?? const {},
          cwd: cwd,
          firstMount: mount?.firstOrNull?.virtualPath,
          skipTypeCheck: skipTypeCheck,
        );
        final drive = _FeedDrive(
          this,
          _hostFor(_proto, _config, externalLookup, os, mount),
          printCallback ?? defaultPrint,
        );
        _snapshots = drive;

        return drive.step(request);
      },
      feed: true,
    );
  });

  @override
  Future<void> loadSession(Uint8List state) async {
    _hold.claimFresh();
    final (event, _) = await _withTurn(() => _proto.load(state), feed: false);
    if (event != null) {
      // A worker restored to the wrong kind of dump cannot be trusted: the
      // session ends, as upstream discards it.
      _hold.lease.kill(reason: 'discarded', outcome: 'error');
      throw StateError(
        'this dump is a suspended snapshot — use load_snapshot() to resume it',
      );
    }
  }

  @override
  Future<MontySnapshot> loadSnapshot(
    Uint8List state, {
    List<MountDir>? mount,
    Map<String, MontyValue>? externalLookup,
    ProtoPrintCallback? printCallback,
    OsHandler? os,
  }) => _withTurn(() {
    // A refused mount must not consume the fresh session's restore slot.
    final host = _hostFor(_proto, _config, externalLookup, os, mount);
    try {
      _hold.claimFresh();
    } on Object {
      host.dispose();
      rethrow;
    }
    final drive = _FeedDrive(this, host, printCallback ?? defaultPrint);
    _snapshots = drive;

    return drive.restore(state);
  }, feed: false);

  @override
  Future<Uint8List> dump() async {
    _refuseInPrint(this);
    if (_hold.isFinished) throw _finishedError();

    // The channel holds it until any turn in flight is over.
    return _proto.dump();
  }

  @override
  Future<void> installDependencies(List<String> requirements) =>
      Future.sync(() {
        // Read when called, as the binding reads its argument: the list the
        // caller holds may change before the turn is free.
        final taken = [...requirements];
        checkRequirementsText(taken);

        // Refused as a feed is while a suspension waits, in its own words.
        return _withTurn(
          () async {
            // A dump runs outside the turns, on the channel: wait for it, as
            // upstream's checkout lock does, and look again.
            if (_channel.inTurn) {
              while (_channel.inTurn) {
                await _channel.turnOver;
              }
              if (_hold.isFinished) throw _finishedError();
            }
            // Installing nothing trivially succeeds, the sandbox worker too.
            if (taken.isEmpty) return;
            checkRequirements(taken);
            await _proto.installDependencies(taken);
          },
          feed: true,
          pending: _pendingInstallError,
        );
      });

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _hold.closed = true;
    _dropped.detach(_hold);
    // Sleeps end now: no timer outlives the session, and a drive waiting on
    // one goes on to fail as finished.
    _feedHost?.dispose();
    _snapshots?._host.dispose();
    // Queued feeds fail as finished, one after another.
    _handOff();
    // A host callback is running (no turn of its own in flight: none, or a
    // dump's): its call fails now, and the callback's result, when it
    // comes, is dropped.
    final pending = _outcome;
    final ownTurn = _channel.inTurn && !_channel.dumping;
    if (!ownTurn && pending != null && !pending.isCompleted) {
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
    StateError Function() pending = _pendingError,
  }) async {
    _refuseInPrint(this);
    if (_hold.isFinished) throw _finishedError();
    // Null when the turn is free now: no await, so the body below starts
    // in this same synchronous step and no other call can slip in.
    final wait = _turnWait(feed: feed, pending: pending);
    if (wait != null) {
      await wait;
      // From here to the body's start is one synchronous step: the turn
      // stays reserved until this call holds it, so no new feed can slip
      // in between.
      _reserved = false;
      if (_hold.isFinished || _active != null || (feed && _suspended)) {
        // Woken by a close, or by the running feed suspending: this call
        // cannot run, and the next waiter learns the same.
        _handOff();
        _refused(finished: _hold.isFinished, pending: pending);
      }
    }
    // The call's own outcome: the body's, unless a close while a host
    // callback runs fails it first (the body then ends unwatched). It is in
    // place before the body starts, so host code that closes the session
    // before its first await fails it too.
    final outcome = _outcome = Completer<Object?>();
    _active = outcome.future;
    // A body that throws before its first await (an input the writer
    // refuses) still releases the turn below.
    unawaited(_settle(outcome, Future.sync(body)));
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
  Future<void>? _turnWait({
    required bool feed,
    required StateError Function() pending,
  }) {
    final queueFree = _waiters.isEmpty && !_reserved;
    if (feed && queueFree && _suspended) throw pending();

    if (_active == null && queueFree) return null;
    // Queued, to be handed the turn.
    final turn = Completer<void>();
    _waiters.add(turn);

    return turn.future;
  }

  /// Whether the worker waits for an answer to a suspension: the running
  /// feed's host call, or an answer that was refused as too large to send,
  /// which leaves the suspension pending after its feed failed.
  ///
  /// A dump in flight leaves it so while no call's turn waits behind it: a
  /// feed made from host code meanwhile is refused at once, rather than
  /// queued behind the call that suspended. Behind a waiting turn (a
  /// resume) the feed queues, to be checked once that call is over, as
  /// upstream checks under its lock.
  bool get _suspended =>
      _channel.pendingSuspension &&
      (!_channel.inTurn || (_channel.dumping && _channel.waitingCalls == 0));

  /// Hands the turn to the oldest waiting feed, which then starts, or
  /// fails and hands it on.
  void _handOff() {
    if (_waiters.isEmpty) return;
    _reserved = true;
    _waiters.removeFirst().complete();
  }

  Future<MontyValue> _drive(
    pb.ParentRequest request, {
    required HostAnswers host,
    required ProtoPrintCallback? printCallback,
  }) async {
    _feedHost = host;
    try {
      // A dead worker is mapped and its slot freed by the session channel,
      // at the transport. A MontyCrashedError that reaches here unmapped was
      // thrown by a host callback, or by the driver after it killed the
      // worker; either passes through as is.
      final result = await _proto.drive(
        request,
        host,
        onPrint: _printingIn(this, printCallback ?? defaultPrint),
        options: FeedOptions(
          collectPrints: false,
          abandoned: () => _hold.isFinished,
        ),
      );

      return result.value;
    } finally {
      // Also covers rejection before ProtoSession enters its drive loop.
      host.dispose();
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

/// Throws [StateError] inside one of [session]'s print callbacks: they run
/// inside the turn, so a call back into it would wait on itself.
void _refuseInPrint(Object session) {
  if (_inPrintCallback(session)) {
    throw StateError(
      'a print callback cannot call its own session: it runs inside the '
      'turn',
    );
  }
}

/// [print] marked as [session]'s, so a call back into that session from
/// inside it is refused rather than left waiting on the turn it is part of.
ProtoPrintCallback _printingIn(Object session, ProtoPrintCallback print) =>
    (stream, text) => runZoned(
      () => print(stream, text),
      zoneValues: {
        _printZone: {..._printingSessions(), session},
      },
    );

/// The host side of one feed of a session with [config]: [externalLookup]
/// and [os], and system sleeps waited up to the session's maximum.
HostAnswers _hostFor(
  ProtoSession session,
  SessionConfig config,
  Map<String, MontyValue>? externalLookup,
  OsHandler? os,
  List<MountDir>? mount,
) => HostAnswers(
  externalLookup: externalLookup ?? const {},
  os: os,
  mount: mount,
  systemSleepMax: config.systemSleepMax,
  objects: session.objects,
  recorder: session.recorder,
);

/// Throws what a call refused its turn learns: the session is finished,
/// or a suspension waits ([pending] words it).
Never _refused({
  required bool finished,
  required StateError Function() pending,
}) => throw finished ? _finishedError() : pending();

StateError _pendingInstallError() => StateError(
  'install_dependencies called while a suspension is awaiting an answer',
);

StateError _pendingError() =>
    StateError('feed called while a suspension is awaiting an answer');

/// One `feedStart`'s drive: the session it runs on, the answers its
/// snapshots' `resumeAuto` gives (with the coroutines they started), and
/// where its prints go. It resumes the snapshots it hands out.
final class _FeedDrive implements SnapshotDriver {
  _FeedDrive(this._session, this._host, this._print)
    : _scriptName = _session._config.scriptName,
      _traceEntry = _session._proto.recorder?.bridge.currentContext();

  final _LeasedSession _session;
  final HostAnswers _host;
  final ProtoPrintCallback _print;
  final Object? _traceEntry;

  /// The script name the drive's snapshots report: the session's, or a
  /// restored dump's.
  String _scriptName;

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
      ExternalReturnValue(:final value) => encodingInput(
        () => resumeValue(callId, value, objects: _host.objects),
      ),
      ExternalException(:final excType, :final message, :final attributes) =>
        resumeWith(
          callId,
          pb.ExtFunctionResult(
            error: raisedException(excType, message, attributes),
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

  /// Answers [snapshot] through the feed's host side, as `feedRun` answers
  /// it. An OS call goes to [HostAnswers.osCall] with `parentSleeps`
  /// false, so a system sleep (`system.sleep`, `system.async_sleep`)
  /// reaches the mounts and the OS handler instead of being waited here,
  /// as `feedRun` waits it; a method call ([FunctionSnapshot.objectId] set)
  /// is dispatched to the host object registered under that id, and a
  /// plain call to the feed's host functions.
  ///
  /// The snapshot is spent before the host side runs: what the host side
  /// rethrows finishes the session (the worker is discarded), while a host
  /// throw is raised in the sandbox and the session runs on
  /// ([MontySnapshot]).
  @override
  Future<MontySnapshot> resumeCallAuto(FunctionSnapshot snapshot) async {
    snapshot.spend();
    // No host code for a session already finished; one that finishes while
    // it runs fails the turn below.
    if (_session._hold.isFinished) throw _finishedError();
    // The payload passed upstream's checks when the snapshot was made
    // (_callSnapshot, _osSnapshot), so the host answer cannot reject it.
    final event = _suspended;

    // Host code runs outside the protocol turn, as upstream's does, but
    // inside the session's call: a close meanwhile Resets the worker and
    // fails the resume at once, and the host's late answer is dropped.
    return _session._withTurn(() async {
      final pb.ParentRequest request;
      try {
        request = snapshot.isOsFunction
            ? await _host.osCall(event.osCall, parentSleeps: false)
            : await _host.call(event.functionCall);
      } on Object {
        // The worker is left waiting on an answer that never comes:
        // upstream discards the checkout. No step() follows to end the feed.
        _host.dispose();
        _session._hold.lease.kill(reason: 'discarded', outcome: 'error');
        rethrow;
      }

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
      final writer = ArenaWriter(objects: _host.objects);
      final index = encodingInput(() => writer.add(value));
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
  Future<MontySnapshot> resumeLookupAuto(NameLookupSnapshot snapshot) async {
    snapshot.spend();
    // No host code for a session already finished, as resumeCallAuto.
    if (_session._hold.isFinished) throw _finishedError();

    return _session._withTurn(() {
      final pb.ParentRequest request;
      try {
        request = _host.lookup(
          snapshot.variableName,
          objectId: snapshot.objectId,
        );
      } on Object {
        // A value the writer refuses is never answered: upstream discards
        // the checkout. No step() follows to release this feed's resources.
        _host.dispose();
        _session._hold.lease.kill(reason: 'discarded', outcome: 'error');
        rethrow;
      }

      return step(request);
    }, feed: false);
  }

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
          answers.add((key, ExternalAnswer.value(value)));
        case ExternalException(
          :final excType,
          :final message,
          :final attributes,
        ):
          answers.add((
            key,
            ExternalAnswer.error(raisedException(excType, message, attributes)),
          ));
      }
    }

    // A value the writer refuses throws here, before the snapshot is spent.
    return _resume(
      snapshot,
      encodingInput(
        () => futuresRequest(answers, objects: _host.objects, strict: true),
      ),
    );
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
      } on Object {
        // Nothing can settle the worker's wait, or the results cannot be
        // prepared: the session ends, as upstream discards the checkout, and
        // the error is rethrown. No step() follows, so end the feed here.
        _host.dispose();
        _session._hold.lease.kill(reason: 'discarded', outcome: 'error');
        rethrow;
      }

      return step(request);
    }, feed: false);
  }

  @override
  Future<Uint8List> dumpSnapshot(SuspendedSnapshot snapshot) async {
    final session = _session;
    _refuseInPrint(session);
    final channel = session._channel;
    // Checked with the channel free, in the same synchronous step as the
    // Dump is sent, as upstream checks under the lock: a resume in flight
    // has spent the snapshot.
    while (channel.inTurn) {
      await channel.turnOver;
    }
    if (snapshot.isSpent) {
      throw StateError('cannot dump a snapshot that has already been resumed');
    }
    if (session._hold.isFinished) throw _finishedError();

    return session._proto.dump();
  }

  /// Loads [state] and returns the snapshot of the suspension it
  /// re-announces, under the dump's script name. An idle dump finishes the
  /// session.
  Future<MontySnapshot> restore(Uint8List state) async {
    try {
      final (event, scriptName) = await _session._proto.load(state);
      if (event == null) {
        // The wrong kind of dump: the session ends, as upstream discards it.
        _session._hold.lease.kill(reason: 'discarded', outcome: 'error');
        throw StateError(
          'this dump is an idle session — use load_session() to restore it',
        );
      }
      // The dump's own, unless the worker did not say.
      _scriptName = scriptName ?? _scriptName;
      _suspended = event;

      return _suspension(event);
    } on Object {
      _host.dispose();
      rethrow;
    }
  }

  /// Sends [request] as one turn and returns the snapshot of how it ended.
  /// A feed that ends, done or failed, ends its sleeps too.
  Future<MontySnapshot> step(pb.ParentRequest request) async {
    try {
      final snapshot = await _step(request);
      if (snapshot is MontyComplete) _host.dispose();

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
      onPrint: _printingIn(session, _print),
      abandoned: () => session._hold.isFinished,
    );
    if (event.whichKind() == pb.ChildEvent_Kind.complete) {
      return _completion(session._proto, event.complete);
    }
    _suspended = event;

    return _suspension(event);
  }

  /// Spends [snapshot] and sends [request], already built and checked.
  ///
  /// The spend comes first, so the transport's refusal of an oversized
  /// request (nothing written, the worker waiting where it was) lands after
  /// it: the resume throws its `MontyRuntimeError` with the snapshot spent
  /// and the suspension still pending, and only closing the session
  /// recovers the worker.
  Future<MontySnapshot> _resume(
    SuspendedSnapshot snapshot,
    pb.ParentRequest request,
  ) {
    snapshot.spend();

    return _session._withTurn(() => step(request), feed: false);
  }

  /// The snapshot of the suspension [event].
  SuspendedSnapshot _suspension(pb.ChildEvent event) {
    final script = _scriptName;

    final snapshot = switch (event.whichKind()) {
      pb.ChildEvent_Kind.functionCall => _callSnapshot(
        this,
        script,
        event.functionCall,
        _session._hold.lease,
        _host.objects.lookup,
      ),
      pb.ChildEvent_Kind.osCall => _osSnapshot(
        this,
        script,
        event.osCall,
        _session._hold.lease,
        _host.objects.lookup,
      ),
      pb.ChildEvent_Kind.nameLookup => Snapshots.nameLookup(
        this,
        _position(event.nameLookup.position),
        script,
        variableName: event.nameLookup.name,
        objectId: event.nameLookup.hasObjectId()
            ? uuidString(event.nameLookup.objectId.data)
            : null,
      ),
      pb.ChildEvent_Kind.resolveFutures => Snapshots.futures(
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

    return snapshot
      ..capturedTraceContext = _session._proto.recorder?.context(_traceEntry);
  }
}

/// The completion [complete] of a feed on [proto]: its structure is checked
/// now, so an arena upstream rejects is a protocol violation of this turn,
/// and the value is built on each read of its output, as upstream converts
/// it per access. A value that fails to convert throws from the read and
/// leaves the session as it was.
///
/// It keeps the host-object lookup, not the session, so a completion held
/// on to does not keep an abandoned session from its finalizer.
MontyComplete _completion(ProtoSession proto, pb.Complete complete) {
  proto.completeReader(complete);
  final hosts = proto.objects.lookup;

  return Snapshots.complete(
    () => ArenaReader(complete.values, hosts: hosts)[complete.value],
  );
}

/// The snapshot of a host function [call], for [driver] under [script].
///
/// Its arguments arena and roots are checked now, as upstream's
/// `into_call_args` checks them when the frame arrives: one it rejects is a
/// protocol violation, which ends the session ([lease] is killed). Their
/// values are built on each read.
FunctionSnapshot _callSnapshot(
  SnapshotDriver driver,
  String script,
  pb.FunctionCall call,
  WorkerLease lease,
  HostObjectLookup hosts,
) {
  try {
    checkCallArgs(call, hosts);
  } on MontyCrashedError {
    lease.kill(reason: 'discarded', outcome: 'error');
    rethrow;
  }

  return Snapshots.function(
    driver,
    _position(call.position),
    script,
    (
      functionName: call.functionName,
      callId: call.callId,
      isOsFunction: false,
      allowEagerAwait: call.allowEagerAwait,
      objectId: call.hasObjectId() ? uuidString(call.objectId.data) : null,
      arguments: () => callArgs(call, hosts: hosts),
      keywords: () => callKwargs(call, hosts: hosts),
    ),
  );
}

/// The snapshot of an OS [call], for [driver] under [script]. A payload
/// upstream could never produce is a protocol violation, which ends the
/// session: [lease] is killed.
FunctionSnapshot _osSnapshot(
  SnapshotDriver driver,
  String script,
  pb.OsCall call,
  WorkerLease lease,
  HostObjectLookup hosts,
) {
  final OsCallParts parts;
  try {
    parts = osCallParts(call, hosts: hosts);
  } on FormatException catch (error) {
    lease.kill(reason: 'discarded', outcome: 'error');
    throw protocolError('invalid OS call payload: ${error.message}');
  }
  final (name, args, kwargs) = parts;

  return Snapshots.function(
    driver,
    _position(call.position),
    script,
    (
      functionName: name,
      callId: call.callId,
      isOsFunction: true,
      // A worker's eager bit on a call no future may answer is dropped, as
      // upstream drops it.
      allowEagerAwait: call.allowEagerAwait && acceptsFuture(name),
      objectId: null,
      arguments: () => args,
      keywords: () => kwargs,
    ),
  );
}

/// [range] as a [SourceRange], its file name cut to 256 UTF-8 bytes as
/// upstream's `SourceRange::new` cuts every suspension's position; an unset
/// one (a worker that predates the field) is [unknownSourceRange], as
/// upstream reads it.
SourceRange _position(pb.SourceRange range) => range == pb.SourceRange()
    ? unknownSourceRange
    : SourceRange(
        filename: cutSourceFilename(range.filename),
        start: range.start,
        end: range.end,
      );

/// The suspension and sleep budgets of one checkout: the limits in force
/// and what the session has used of them.
///
/// The count is per checkout, not per feed: every turn-ending event goes
/// through [admit], which counts a suspension, charges a system sleep, and
/// says when the feed must be aborted instead. A worker reply can only
/// tighten a limit.
///
/// It also holds the feed and turn duration budgets the parent backstops.
/// A reply sets either only where there is none: ordinary replies echo the
/// session's, a `Load` reply reports the dump's.
///
/// The reported feed execution belongs to this budget too: it is monotonic
/// within one feed, resets when the next feed starts, and a load saves or
/// replaces it along with the rest of the budget.
///
/// Loading a dump follows upstream (`checkout.rs` `begin_load`, `forget`,
/// `end_load`): [beginLoad] keeps the two limits as ceilings and restarts
/// both counts, and forgets both duration budgets, so a dump keeps its own
/// (O9); the `Load` reply, when it is `Ok` or a suspension, adopts the dump
/// on those terms, and a re-announced suspension is counted and charged
/// again as it arrives. Any other reply, or none ([endLoad]), puts the
/// budget back as it was before the load.
final class SessionBudget {
  /// A fresh budget for [config]: its limits, nothing used.
  SessionBudget(SessionConfig config)
    : _feedBudget = config.limits?.maxFeedDuration,
      _turnBudget = config.limits?.maxTurnDuration,
      _suspensionLimit = config.limits?.maxSuspensions ?? defaultMaxSuspensions,
      _sleepLimit = switch (config.limits?.maxTotalSleep) {
        final limit? => nanosOf(limit),
        null => null,
      },
      _systemSleepCap = config.systemSleepCapNanos;

  /// The feed's duration budget, which the parent backstops: the session's
  /// `maxFeedDuration`, or a loaded dump's; null while there is none.
  Duration? get feedBudget => _feedBudget;
  Duration? _feedBudget;

  /// Each execution turn's duration budget, which the parent backstops:
  /// the session's `maxTurnDuration`, or a loaded dump's; null while there
  /// is none.
  Duration? get turnBudget => _turnBudget;
  Duration? _turnBudget;

  /// The feed execution the worker most recently reported, without allowing
  /// a later reply in the same feed to lower the parent's backstop.
  Duration get reportedFeedExecution => _reportedFeedExecution;
  Duration _reportedFeedExecution = Duration.zero;

  /// How many suspensions the session may make before the next one aborts
  /// its feed: `maxSuspensions`, or a smaller limit a reply reported.
  int get suspensionLimit => _suspensionLimit;
  int _suspensionLimit;

  /// The most the session's system sleeps may add up to, in nanoseconds as
  /// upstream's `Duration`: `maxTotalSleep`, or a smaller limit a reply
  /// reported; null while there is none.
  BigInt? get sleepLimit => _sleepLimit;
  BigInt? _sleepLimit;

  /// Suspensions counted so far, the one that passed the limit included.
  int get suspensions => _suspensions;
  int _suspensions = 0;

  /// System sleep charged so far, in nanoseconds; capped sleeps at their
  /// cap.
  BigInt get slept => _slept;
  BigInt _slept = BigInt.zero;

  /// The longest one system sleep is charged, in nanoseconds.
  final BigInt _systemSleepCap;

  /// The budget as it was before a load whose reply has not yet decided
  /// it (upstream's `pending_load_budget`).
  _Saved? _beforeLoad;

  /// Starts a feed: only a feed request may reset the worker-reported clock.
  void beginFeed() {
    _reportedFeedExecution = Duration.zero;
  }

  /// Starts loading a dump: the budget is saved, then both counts restart
  /// while both limits stay, as ceilings on the dump's, and both duration
  /// budgets and the feed clock are forgotten, to be the dump's (upstream's
  /// `begin_load` and `forget`).
  void beginLoad() {
    _beforeLoad = (
      feed: _feedBudget,
      turn: _turnBudget,
      reportedFeedExecution: _reportedFeedExecution,
      suspensionLimit: _suspensionLimit,
      sleepLimit: _sleepLimit,
      suspensions: _suspensions,
      slept: _slept,
    );
    _feedBudget = null;
    _turnBudget = null;
    _reportedFeedExecution = Duration.zero;
    _suspensions = 0;
    _slept = BigInt.zero;
  }

  /// Ends a load: if no reply decided it (the request was refused before it
  /// was sent, or the worker died first), the budget saved by [beginLoad]
  /// comes back (upstream's `end_load`).
  void endLoad() {
    if (_beforeLoad case final saved?) _restore(saved);
    _beforeLoad = null;
  }

  /// Records the turn-ending [event] (upstream's `update_from`, then its
  /// checks): records feed execution, adopts any smaller limit it reports,
  /// counts it if it is a suspension and charges it if it is a system sleep.
  ///
  /// Returns the exception to abort the feed with in its place, or null: a
  /// suspension past [suspensionLimit] is a `RuntimeError`; a system sleep
  /// that would pass [sleepLimit] is a `TimeoutError` and is not charged.
  ///
  /// The first event after [beginLoad] settles the load: `Ok` or a
  /// suspension adopts the dump; anything else restores the budget saved
  /// before the load, then is recorded on it.
  pb.RaisedException? admit(pb.ChildEvent event) {
    if (_beforeLoad case final saved?) {
      _beforeLoad = null;
      if (event.whichKind() != pb.ChildEvent_Kind.ok && !isSuspension(event)) {
        _restore(saved);
      }
    }
    final reported = _durationOfMicros(event.feedExecutionMicros);
    if (reported > _reportedFeedExecution) {
      _reportedFeedExecution = reported;
    }
    _adoptLimits(event);
    if (!isSuspension(event)) return null;
    final limit = _suspensionLimit;
    if (++_suspensions > limit) {
      return _raised('RuntimeError', 'suspension limit $limit exceeded');
    }

    return _chargeSleep(event);
  }

  void _restore(_Saved saved) {
    _feedBudget = saved.feed;
    _turnBudget = saved.turn;
    _reportedFeedExecution = saved.reportedFeedExecution;
    _suspensionLimit = saved.suspensionLimit;
    _sleepLimit = saved.sleepLimit;
    _suspensions = saved.suspensions;
    _slept = saved.slept;
  }

  /// Sets either duration budget [event] reports where there is none, and
  /// tightens either limit to the one it reports, if smaller (upstream's
  /// `update_from`). The limits arrive as u64s and are compared exactly,
  /// unsigned: a dart2js `int` may hold a limit of 2^63 or more, which
  /// `Int64` would read as negative.
  void _adoptLimits(pb.ChildEvent event) {
    if (_feedBudget == null && event.hasMaxFeedDurationMicros()) {
      _feedBudget = _durationOfMicros(event.maxFeedDurationMicros);
    }
    if (_turnBudget == null && event.hasMaxTurnDurationMicros()) {
      _turnBudget = _durationOfMicros(event.maxTurnDurationMicros);
    }
    if (event.hasMaxTotalSleepMicros()) {
      final reported =
          BigInt.parse(event.maxTotalSleepMicros.toStringUnsigned()) *
          BigInt.from(1000);
      final current = _sleepLimit;
      if (current == null || reported < current) _sleepLimit = reported;
    }
    if (event.hasMaxSuspensions()) {
      final reported = BigInt.parse(event.maxSuspensions.toStringUnsigned());
      if (reported < BigInt.from(_suspensionLimit)) {
        _suspensionLimit = reported.toInt();
      }
    }
  }

  /// Charges [event], if it is a system sleep, against the sleep budget
  /// (upstream's `charge_sleep`): the delay as the session will wait it, cut
  /// to the system-sleep maximum, a delay that is not a valid duration
  /// counting as that maximum. A sleep that would pass the budget is not
  /// charged; the exception to abort the feed with is returned instead.
  pb.RaisedException? _chargeSleep(pb.ChildEvent event) {
    final seconds = _systemSleepSeconds(event);
    if (seconds == null) return null;
    final cap = _systemSleepCap;
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
}

/// A [SessionBudget] as [SessionBudget.beginLoad] saves it.
typedef _Saved = ({
  Duration? feed,
  Duration? turn,
  Duration reportedFeedExecution,
  int suspensionLimit,
  BigInt? sleepLimit,
  int suspensions,
  BigInt slept,
});

/// The most microseconds a reported duration budget is taken as: 2^53 - 1,
/// which every backend's `int` holds exactly (285 years; upstream's u64
/// goes further, past any deadline that could ever fire).
const int _maxBudgetMicros = 0x1fffffffffffff;

/// [micros], a u64, as a [Duration], saturating at [_maxBudgetMicros].
Duration _durationOfMicros(Int64 micros) {
  final value = BigInt.parse(micros.toStringUnsigned());

  return Duration(
    microseconds: value > BigInt.from(_maxBudgetMicros)
        ? _maxBudgetMicros
        : value.toInt(),
  );
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

/// The exception a feed is aborted with.
pb.RaisedException _raised(String type, String message) =>
    pb.RaisedException(excType: type, message: message);

/// The session's view of its worker: the lease's channel, with each turn
/// refused once the session is finished and bounded by its deadline.
///
/// It also keeps upstream's suspension and sleep budgets ([SessionBudget]):
/// the checkout's suspensions are counted, and one past `maxSuspensions`
/// (default 1000) is not handed to the driver. The feed is aborted in its
/// place with an in-sandbox `RuntimeError`, which the driver then sees as
/// the turn's answer. Its system sleeps, `time.sleep` and `asyncio.sleep`
/// alike, are charged against `maxTotalSleep` the same way, before they are
/// waited: the one that would pass it aborts the feed with an in-sandbox
/// `TimeoutError`. A worker reply can only tighten either limit.
///
/// A turn's deadline is the pool's `requestTimeout`; an execution turn's
/// is the earliest of three — that timeout, what the feed budget has left
/// plus its grace, and the turn budget plus its grace (upstream's duration
/// backstops). The earliest wins; a null timeout, or a duration limit or
/// grace left unset, drops its term, and with all three unset there is no
/// deadline. Past it the worker is killed and the turn fails with
/// [MontyCrashedError]. Time spent in host callbacks is never counted: it
/// falls between turns.
///
/// A frame failure is mapped here, at the transport, by direction. A
/// request too large to frame is refused before a byte is written — the
/// worker never sees it and waits where it was — and the turn throws
/// [MontyRuntimeError] (`RuntimeError`), the session as it was. A reply
/// that cannot be framed or decoded cannot be trusted: the worker is
/// discarded and the turn fails with [MontyCrashedError], as any dead
/// worker's does.
final class _SessionChannel implements MontyChannel, TelemetryChannel {
  _SessionChannel(this._hold, this._options, SessionConfig config)
    : _budget = SessionBudget(config);

  /// Whether a protocol turn is in flight.
  bool inTurn = false;

  /// Whether the turn in flight is a dump's, which runs between a call's
  /// turns and belongs to none of them.
  bool dumping = false;

  /// Turns other than dumps waiting for the channel: a call's next turn,
  /// queued behind a dump.
  int waitingCalls = 0;

  /// Whether the last turn ended in a suspension still awaiting the host's
  /// answer (upstream's `pending`).
  bool pendingSuspension = false;

  /// Called when a turn ends in a suspension: the turn is free while the
  /// host answers.
  void Function()? onSuspended;

  final _Hold _hold;
  final PoolOptions _options;

  /// The checkout's suspension and sleep budgets, which a turn-ending event
  /// is admitted against.
  final SessionBudget _budget;

  /// Completes when the turn in flight ends.
  Completer<void>? _turnOver;

  @override
  TelemetryRecorder? get recorder =>
      (_hold.lease.channel as TelemetryChannel).recorder;

  @override
  set recorder(TelemetryRecorder? value) =>
      (_hold.lease.channel as TelemetryChannel).recorder = value;

  @override
  int? get telemetryPid =>
      (_hold.lease.channel as TelemetryChannel).telemetryPid;

  @override
  bool get isAlive => !_hold.isFinished && _hold.lease.channel.isAlive;

  /// Completes when the turn in flight ends. A caller that must find the
  /// channel free rechecks [inTurn] after it, in the same synchronous step
  /// as what it then does: another waiter may have taken the channel first.
  Future<void> get turnOver => (_turnOver ??= Completer<void>()).future;

  @override
  Future<pb.ChildEvent> turn(
    pb.ParentRequest request, {
    PrintHandler? onPrint,
  }) async {
    // Turns are serialized, as upstream's checkout lock serializes them: a
    // feed's next turn waits for a dump made from its host code. A free
    // channel starts the turn in this same synchronous step.
    final waiting = request.whichKind() == pb.ParentRequest_Kind.dump ? 0 : 1;
    while (inTurn) {
      waitingCalls += waiting;
      await turnOver;
      waitingCalls -= waiting;
    }
    final wasPending = _take(request);
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
        pendingSuspension = dumping ? wasPending : isSuspension(event);

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
      _give(request);
    }
  }

  /// The session's close owns the worker's end; the driver never closes.
  @override
  Future<void> close() async => kill();

  @override
  void kill() => _hold.lease.kill(reason: 'discarded', outcome: 'error');

  /// Takes the channel for [request], now free, and returns whether a
  /// suspension was pending.
  ///
  /// A feed is refused while one is: checked with the channel held, as
  /// upstream checks `pending` under its lock, so a feed that waited out a
  /// dump still finds it. A dump leaves the session as it was, suspended or
  /// not (upstream keeps `pending` across a Dump, an error reply included).
  /// A load starts with the dump's budget to come (upstream's restore:
  /// `begin_load`).
  bool _take(pb.ParentRequest request) {
    if (_hold.isFinished) throw _finishedError();
    final kind = request.whichKind();
    final wasPending = pendingSuspension;
    if (kind == pb.ParentRequest_Kind.feed && wasPending) {
      throw _pendingError();
    }
    inTurn = true;
    dumping = kind == pb.ParentRequest_Kind.dump;
    if (!dumping) pendingSuspension = false;
    if (kind == pb.ParentRequest_Kind.load) _budget.beginLoad();

    return wasPending;
  }

  /// Gives the channel back after [request]'s turn, however it ended: a
  /// load no reply decided gets the session's budget back (`end_load`),
  /// the next waiting turn may start, and a turn that left a suspension
  /// pending frees the session's turn while the host answers. A dump
  /// changes neither: the call it ran beside still holds the turn.
  void _give(pb.ParentRequest request) {
    if (request.whichKind() == pb.ParentRequest_Kind.load) _budget.endLoad();
    final dump = dumping;
    inTurn = false;
    dumping = false;
    final over = _turnOver;
    _turnOver = null;
    over?.complete();
    if (pendingSuspension && !dump) onSuspended?.call();
  }

  /// [request]'s turn-ending event; a suspension past the budget, or a
  /// system sleep past the sleep budget, is replaced by the reply to the
  /// `AbortFeed` sent in its place.
  Future<pb.ChildEvent> _turnWithBudget(
    pb.ParentRequest request,
    PrintHandler? onPrint,
  ) async {
    final channel = _hold.lease.channel;
    final event = await channel.turn(request, onPrint: onPrint);
    final exceeded = _budget.admit(event);
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
    if (kind == pb.ChildEvent_Kind.error) {
      // The reply's limits count as any event's do; an Error suspends
      // nothing, so it cannot itself be over budget.
      _budget.admit(reply);

      return reply;
    }
    kill();
    throw protocolError(
      'worker answered AbortFeed with something other than an Error',
    );
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
      _budget.beginFeed();
    }
    final feed = _backstop(
      _budget.feedBudget,
      _budget.reportedFeedExecution,
      _options.feedDurationLimitGrace,
    );
    final turn = _backstop(
      _budget.turnBudget,
      Duration.zero,
      _options.turnDurationLimitGrace,
    );

    return _earliest(_earliest(timeout, feed), turn);
  }
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
