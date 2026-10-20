/// The pool of workers behind sessions: upstream's `AsyncMonty`, public as
/// [Monty].
///
/// [startMonty], [withMonty] and the [MontyInternal] extension take the
/// settings as internal records ([PoolOptions], [SessionConfig]) for tests
/// and harnesses; the public show list leaves them out.
library;

import 'dart:async';

import 'package:dart_monty_core/src/worker/monty_session.dart';
import 'package:dart_monty_core/src/worker/os_policy.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';

/// A pool of Python workers, each dedicated to one session at a time.
///
/// [withPool] and [withSession] are the way to use it: they close what they
/// open on every exit path. A live worker keeps the Dart process from
/// exiting, so a pool from [start] and a session from [checkout] must each
/// be closed. (A session collected unclosed has its worker killed by a
/// finalizer, but only if the collector runs it, which nothing guarantees.)
///
/// With [start]'s default `checkoutTimeout` of null a [checkout] waits for
/// a free worker forever, as upstream's does: a pool whose every worker is
/// held by a session that waits on another checkout hangs. Code that nests
/// checkouts sets a `checkoutTimeout` or sizes `maxProcesses` for them.
///
/// A busy native worker outlives a parent that dies without closing it,
/// until the worker's own duration limit ends the run; an idle one exits
/// when its stdin reaches end-of-file.
final class Monty {
  const Monty._(this._pool);

  final WorkerPool _pool;

  /// Starts a pool with [minProcesses] workers ready, failing if any of them
  /// cannot start (upstream `AsyncMonty`). A setting upstream refuses is an
  /// [ArgumentError] before any worker starts.
  ///
  /// [maxProcesses] bounds the workers alive at once (the platform's default
  /// when null: the number of processors on native, the browser's hardware
  /// concurrency on the web, 4 where the browser does not say).
  /// [checkoutTimeout] bounds how long [checkout]
  /// waits for a free worker (forever when null); [requestTimeout] bounds
  /// each request turn (unbounded when null). [maxCheckoutsPerWorker]
  /// retires a worker after that many checkouts (never when null; 0 retires
  /// each worker at its first release). [feedDurationLimitGrace] and
  /// [turnDurationLimitGrace] are how far past a session's duration limits
  /// the parent lets a turn run before it kills the worker (one second by
  /// default); null leaves that limit unguarded by the parent. Each
  /// execution turn — a feed, or a resume after a suspension — runs under
  /// the earliest of three deadlines: `requestTimeout`, what the session's
  /// `maxFeedDuration` has left plus `feedDurationLimitGrace`, and
  /// `maxTurnDuration` plus `turnDurationLimitGrace`.
  /// [workerLocation] is where the worker is found: an executable on
  /// native, an asset base URL on the web; null searches the usual places.
  ///
  /// [minProcesses] is 1 by default and must not be negative;
  /// [maxProcesses] must be at least 1 and at least [minProcesses] — a
  /// platform default below [minProcesses] is an impossible size, so set
  /// [maxProcesses] there; [maxCheckoutsPerWorker] must fit an unsigned
  /// 32-bit integer; and a duration must not be negative. A value outside
  /// its domain throws [ArgumentError] with upstream's message, before any
  /// worker starts; so does an impossible pool size. A worker that cannot
  /// be located or spawned, or is not ready within 30 seconds, fails the
  /// call with a `MontyCrashedError`.
  static Future<Monty> start({
    int minProcesses = 1,
    int? maxProcesses,
    Duration? checkoutTimeout,
    Duration? requestTimeout,
    int? maxCheckoutsPerWorker,
    Duration? feedDurationLimitGrace = PoolOptions.defaultDurationLimitGrace,
    Duration? turnDurationLimitGrace = PoolOptions.defaultDurationLimitGrace,
    String? workerLocation,
  }) => startMonty(
    PoolOptions(
      minProcesses: minProcesses,
      maxProcesses: maxProcesses,
      checkoutTimeout: checkoutTimeout,
      requestTimeout: requestTimeout,
      maxCheckoutsPerWorker: maxCheckoutsPerWorker,
      feedDurationLimitGrace: feedDurationLimitGrace,
      turnDurationLimitGrace: turnDurationLimitGrace,
      workerLocation: workerLocation,
    ),
  );

  /// Runs [body] with a pool started as [start] does with the same
  /// settings, and closes the pool however [body] ends: the form of
  /// upstream's `async with AsyncMonty()`.
  ///
  /// The settings are [start]'s, with the same defaults and the same
  /// domains: an [ArgumentError] for a setting upstream refuses comes
  /// before the pool starts.
  static Future<T> withPool<T>(
    Future<T> Function(Monty monty) body, {
    int minProcesses = 1,
    int? maxProcesses,
    Duration? checkoutTimeout,
    Duration? requestTimeout,
    int? maxCheckoutsPerWorker,
    Duration? feedDurationLimitGrace = PoolOptions.defaultDurationLimitGrace,
    Duration? turnDurationLimitGrace = PoolOptions.defaultDurationLimitGrace,
    String? workerLocation,
  }) => withMonty(
    body,
    PoolOptions(
      minProcesses: minProcesses,
      maxProcesses: maxProcesses,
      checkoutTimeout: checkoutTimeout,
      requestTimeout: requestTimeout,
      maxCheckoutsPerWorker: maxCheckoutsPerWorker,
      feedDurationLimitGrace: feedDurationLimitGrace,
      turnDurationLimitGrace: turnDurationLimitGrace,
      workerLocation: workerLocation,
    ),
  );

  /// Dedicates a worker to a new session (upstream `checkout`): [scriptName]
  /// is the file name tracebacks report (`main.py` by default), [limits] the
  /// resource limits (null leaves every one off, the recursion depth and
  /// the suspension count at upstream's 1000), [typeCheck] whether each
  /// snippet is type-checked first (false by default, with
  /// [typeCheckStubs], [typeCheckFormat] and [typeCheckColor]); the check runs
  /// in the worker under the limits' feed duration, so set one when the source
  /// is untrusted,
  /// [assertMessageAnnotations] how many bytes of each operand an `assert`
  /// message shows (null keeps the worker's default of 120 bytes, 0 turns
  /// the annotations off), [printFlushInterval] how long the worker may hold
  /// printed text (null keeps the worker's default, zero sends each line as
  /// it ends), and [osPolicy] the clock, zone, sleep and randomness the
  /// session gets (null is upstream's default policy). A null setting keeps
  /// upstream's default.
  ///
  /// [typeCheckFormat] is one of `full`, `concise`, `azure`, `json`,
  /// `jsonlines` (also `json-lines`), `rdjson`, `pylint`, `gitlab` or
  /// `github`, ASCII case ignored, and `full` by default.
  /// [assertMessageAnnotations] must fit an unsigned 32-bit integer, and
  /// [printFlushInterval] must not be negative.
  ///
  /// Throws [ArgumentError] for a setting upstream refuses, with upstream's
  /// message, before any worker is taken, an unknown IANA zone name
  /// included. Waits for a free worker up to the pool's `checkoutTimeout`,
  /// then throws [TimeoutException]. That wait is all `checkoutTimeout`
  /// covers: starting a new worker is bounded by the pool's 30-second
  /// startup deadline, and configuring the session by `requestTimeout`,
  /// each separately. A worker that cannot be located, spawned or readied
  /// throws `MontyCrashedError`, and so does one that dies while
  /// configuring; a configure refusal from the worker throws the error it
  /// raised (a `MontyRuntimeError`, say). Throws [StateError] once the pool
  /// is closed; a checkout already waiting then still completes.
  Future<MontySession> checkout({
    String scriptName = 'main.py',
    ResourceLimits? limits,
    bool typeCheck = false,
    String? typeCheckStubs,
    String? typeCheckFormat,
    bool typeCheckColor = false,
    int? assertMessageAnnotations,
    Duration? printFlushInterval,
    OsPolicy? osPolicy,
  }) => checkoutWith(
    SessionConfig(
      scriptName: scriptName,
      limits: limits,
      typeCheck: typeCheck,
      typeCheckStubs: typeCheckStubs,
      typeCheckFormat: typeCheckFormat,
      typeCheckColor: typeCheckColor,
      assertMessageAnnotations: assertMessageAnnotations,
      printFlushInterval: printFlushInterval,
      osPolicy: osPolicy,
    ),
  );

  /// Runs [body] with a session from [checkout] with the same settings, and
  /// closes the session however [body] ends: the form of upstream's
  /// `async with pool.checkout()`.
  ///
  /// The settings are [checkout]'s, with the same defaults and the same
  /// domains: an [ArgumentError] for a setting upstream refuses comes
  /// before a worker is taken.
  Future<T> withSession<T>(
    Future<T> Function(MontySession session) body, {
    String scriptName = 'main.py',
    ResourceLimits? limits,
    bool typeCheck = false,
    String? typeCheckStubs,
    String? typeCheckFormat,
    bool typeCheckColor = false,
    int? assertMessageAnnotations,
    Duration? printFlushInterval,
    OsPolicy? osPolicy,
  }) => withSessionWith(
    body,
    SessionConfig(
      scriptName: scriptName,
      limits: limits,
      typeCheck: typeCheck,
      typeCheckStubs: typeCheckStubs,
      typeCheckFormat: typeCheckFormat,
      typeCheckColor: typeCheckColor,
      assertMessageAnnotations: assertMessageAnnotations,
      printFlushInterval: printFlushInterval,
      osPolicy: osPolicy,
    ),
  );

  /// Refuses new checkouts and ends the idle workers. Sessions still open,
  /// and checkouts already waiting, run on; each one's close then kills its
  /// worker. Idempotent.
  Future<void> close() => _pool.close();
}

/// Starts a [Monty] as [options] say, with [open] in place of the
/// platform's channel factory: for tests, and for harnesses that must see
/// each worker. Internal: the public show list leaves it out.
Future<Monty> startMonty(
  PoolOptions options, {
  OpenChannel? open,
  Duration startupTimeout = WorkerPool.defaultStartupTimeout,
}) async => Monty._(await WorkerPool.start(options, open, startupTimeout));

/// [Monty.withPool] with its settings as one record. Internal.
Future<T> withMonty<T>(
  Future<T> Function(Monty monty) body, [
  PoolOptions options = const PoolOptions(),
]) async {
  final monty = await startMonty(options);
  try {
    return await body(monty);
  } finally {
    await monty.close();
  }
}

/// Members of [Monty] that are internal: the public show list leaves this
/// extension out, so only code that imports this library sees them.
extension MontyInternal on Monty {
  /// [Monty.checkout] with its settings as one record.
  Future<MontySession> checkoutWith([
    SessionConfig options = const SessionConfig(),
  ]) async {
    options.validate();

    return openPoolSession(await _pool.acquire(), _pool.options, options);
  }

  /// [Monty.withSession] with its settings as one record.
  Future<T> withSessionWith<T>(
    Future<T> Function(MontySession session) body, [
    SessionConfig options = const SessionConfig(),
  ]) async {
    final session = await checkoutWith(options);
    try {
      return await body(session);
    } finally {
      await session.close();
    }
  }

  /// Idle workers now (upstream `idle_workers`). Diagnostics and tests:
  /// stale once returned.
  int get idleWorkers => _pool.idleWorkers;

  /// Slots taken now: idle, checked-out and starting workers. Diagnostics
  /// and tests: stale once returned.
  int get liveWorkers => _pool.liveWorkers;
}
