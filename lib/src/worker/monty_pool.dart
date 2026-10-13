/// The pool of workers behind sessions: upstream's `AsyncMonty`.
///
/// Becomes the public `Monty` at the cutover; until then it is internal and
/// takes its settings as internal records.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';

import 'package:dart_monty_core/src/worker/pool_session.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';

/// A pool of Python workers, each dedicated to one session at a time.
///
/// [withPool] and [withSession] are the way to use it: they close what they
/// open on every exit path. A live worker keeps the Dart process from
/// exiting, so a pool from [start] and a session from [checkout] must each
/// be closed.
///
/// With [start]'s default `checkoutTimeout` of null a [checkout] waits for
/// a free worker forever, as upstream's does: a pool whose every worker is
/// held by a session that waits on another checkout hangs. Code that nests
/// checkouts sets a `checkoutTimeout` or sizes `maxProcesses` for them.
///
/// A busy native worker outlives a parent that dies without closing it,
/// until the worker's own duration limit ends the run; an idle one exits
/// when its stdin reaches end-of-file.
final class MontyPool {
  const MontyPool._(this._pool);

  final WorkerPool _pool;

  /// Starts a pool with [minProcesses] workers ready, failing if any of
  /// them cannot start (upstream `AsyncMonty`'s parameters).
  ///
  /// [maxProcesses] defaults to the processor count on native and to
  /// `navigator.hardwareConcurrency` (or 4) in a browser. [checkoutTimeout]
  /// bounds a [checkout]'s wait for a free worker (forever when null).
  /// [requestTimeout] bounds every protocol turn: a worker that has not
  /// answered by then is killed. [maxCheckoutsPerWorker] retires a worker
  /// after that many sessions. [feedDurationLimitGrace] and
  /// [turnDurationLimitGrace] are how far past a session's own feed and turn
  /// budgets the parent waits before it kills the worker; null turns that
  /// backstop off. [workerLocation] is the worker executable on native and
  /// the assets' base URL in a browser; null searches the usual places.
  static Future<MontyPool> start({
    int minProcesses = 1,
    int? maxProcesses,
    Duration? checkoutTimeout,
    Duration? requestTimeout,
    int? maxCheckoutsPerWorker,
    Duration? feedDurationLimitGrace = PoolOptions.defaultDurationLimitGrace,
    Duration? turnDurationLimitGrace = PoolOptions.defaultDurationLimitGrace,
    String? workerLocation,
  }) => startWith(
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

  /// [start] with [options], and [open] in place of the platform's channel
  /// factory: for tests, and for harnesses that must see each worker.
  static Future<MontyPool> startWith(
    PoolOptions options, {
    OpenChannel? open,
    Duration startupTimeout = WorkerPool.defaultStartupTimeout,
  }) async =>
      MontyPool._(await WorkerPool.start(options, open, startupTimeout));

  /// Runs [body] with a pool started with [start]'s parameters, and closes
  /// the pool however [body] ends: the form of upstream's
  /// `async with AsyncMonty()`.
  static Future<T> withPool<T>(
    Future<T> Function(MontyPool pool) body, {
    int minProcesses = 1,
    int? maxProcesses,
    Duration? checkoutTimeout,
    Duration? requestTimeout,
    int? maxCheckoutsPerWorker,
    Duration? feedDurationLimitGrace = PoolOptions.defaultDurationLimitGrace,
    Duration? turnDurationLimitGrace = PoolOptions.defaultDurationLimitGrace,
    String? workerLocation,
  }) async {
    final pool = await start(
      minProcesses: minProcesses,
      maxProcesses: maxProcesses,
      checkoutTimeout: checkoutTimeout,
      requestTimeout: requestTimeout,
      maxCheckoutsPerWorker: maxCheckoutsPerWorker,
      feedDurationLimitGrace: feedDurationLimitGrace,
      turnDurationLimitGrace: turnDurationLimitGrace,
      workerLocation: workerLocation,
    );
    try {
      return await body(pool);
    } finally {
      await pool.close();
    }
  }

  /// Dedicates a worker to a new session, configured with [scriptName] (the
  /// file name tracebacks report), [limits], the type check ([typeCheck],
  /// with [typeCheckStubs], [typeCheckFormat] (one of [typeCheckFormats];
  /// null is `full`) and [typeCheckColor]), [assertMessageAnnotations]
  /// (bytes of each operand an `assert` failure shows; 0 turns them off),
  /// [printFlushInterval] (how long the worker may hold printed text) and
  /// [osPolicy] (the clock, zone, sleep and randomness the session gets).
  ///
  /// Throws [ArgumentError] for an unknown [typeCheckFormat], before any
  /// worker is taken. Waits for a free worker up to the pool's
  /// `checkoutTimeout`, then throws [TimeoutException]. Throws [StateError]
  /// once the pool is closed.
  Future<PoolSession> checkout({
    String scriptName = 'main.py',
    SessionLimits? limits,
    bool typeCheck = false,
    String? typeCheckStubs,
    String? typeCheckFormat,
    bool typeCheckColor = false,
    int? assertMessageAnnotations,
    Duration? printFlushInterval,
    pb.OsPolicy? osPolicy,
  }) async {
    if (typeCheckFormat != null &&
        !typeCheckFormats.containsKey(typeCheckFormat)) {
      throw ArgumentError.value(
        typeCheckFormat,
        'typeCheckFormat',
        'must be one of ${typeCheckFormats.keys.join(', ')}',
      );
    }
    final config = SessionConfig(
      scriptName: scriptName,
      maxMemoryBytes: limits?.maxMemoryBytes,
      maxRecursionDepth: limits?.maxRecursionDepth,
      maxFeedDuration: limits?.maxFeedDuration,
      maxTurnDuration: limits?.maxTurnDuration,
      maxSuspensions: limits?.maxSuspensions,
      assertMessageAnnotations: assertMessageAnnotations,
      printFlushInterval: printFlushInterval,
      typeCheck: typeCheck,
      typeCheckStubs: typeCheckStubs,
      typeCheckFormat: typeCheckFormat,
      typeCheckColor: typeCheckColor,
      osPolicy: osPolicy,
    );

    return openPoolSession(await _pool.acquire(), _pool.options, config);
  }

  /// Runs [body] with a session from [checkout]'s parameters, and closes
  /// the session however [body] ends: the form of upstream's
  /// `async with pool.checkout()`.
  Future<T> withSession<T>(
    Future<T> Function(PoolSession session) body, {
    String scriptName = 'main.py',
    SessionLimits? limits,
    bool typeCheck = false,
    String? typeCheckStubs,
    String? typeCheckFormat,
    bool typeCheckColor = false,
    int? assertMessageAnnotations,
    Duration? printFlushInterval,
    pb.OsPolicy? osPolicy,
  }) async {
    final session = await checkout(
      scriptName: scriptName,
      limits: limits,
      typeCheck: typeCheck,
      typeCheckStubs: typeCheckStubs,
      typeCheckFormat: typeCheckFormat,
      typeCheckColor: typeCheckColor,
      assertMessageAnnotations: assertMessageAnnotations,
      printFlushInterval: printFlushInterval,
      osPolicy: osPolicy,
    );
    try {
      return await body(session);
    } finally {
      await session.close();
    }
  }

  /// Refuses new checkouts and ends the idle workers. Sessions still open
  /// run on; each one's close then kills its worker. Idempotent.
  Future<void> close() => _pool.close();

  /// Idle workers now (upstream `idle_workers`). Diagnostics and tests:
  /// stale once returned.
  int get idleWorkers => _pool.idleWorkers;

  /// Slots taken now: idle, checked-out and starting workers. Diagnostics
  /// and tests: stale once returned.
  int get liveWorkers => _pool.liveWorkers;
}
