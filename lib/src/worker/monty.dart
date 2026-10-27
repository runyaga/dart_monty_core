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

/// Owns Python workers and dedicates one to each checked-out session.
///
/// Live workers keep the Dart process alive, and finalizers are not
/// guaranteed. Every pool and session therefore needs an explicit close. A
/// busy native worker can survive an unclosed parent until its duration limit,
/// while an idle worker exits at standard-input EOF. A null checkout timeout
/// can deadlock nested checkouts when every worker is already held.
final class Monty {
  const Monty._(this._pool);

  final WorkerPool _pool;

  /// Starts a worker pool with [minProcesses] workers ready.
  ///
  /// Invalid settings fail with [ArgumentError] before any worker starts. If
  /// an initial worker cannot be located, spawned, or readied within 30
  /// seconds, the pool cancels the other spawns, closes ready workers, and
  /// throws `MontyCrashedError` with the cause.
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

  /// Runs a body with a pool and closes the pool afterward.
  ///
  /// The helper closes only the pool. The body still owns every checked-out
  /// session and must close it.
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

  /// Dedicates one worker to a new session.
  ///
  /// `checkoutTimeout` from pool startup bounds only the wait for a slot. A
  /// new worker has a separate 30-second startup deadline, and the Configure
  /// turn uses `requestTimeout`, with no bound when that setting is null. A
  /// checkout timeout throws [TimeoutException]. This pool throws [StateError]
  /// after [close]. An unknown IANA zone throws [ArgumentError] before a
  /// worker is taken. The worker type checks under `maxFeedDuration`, so
  /// untrusted source needs a feed duration limit. A worker that dies during
  /// Configure produces `MontyCrashedError`, while a Configure refusal retains
  /// its worker error.
  ///
  /// [assertMessageAnnotations] limits each assertion operand to that many
  /// bytes, defaults to 120 when null, and fits an unsigned 32-bit integer.
  /// [printFlushInterval] holds printed text before delivery, defaults in the
  /// worker when null, and sends complete lines at once when zero. It must not
  /// be negative. [typeCheckFormat] defaults to `full` and accepts `full`,
  /// `concise`, `azure`, `json`, `jsonlines`, `json-lines`, `rdjson`, `pylint`,
  /// `gitlab`, or `github`, ignoring ASCII case.
  ///
  /// [externalModules] holds the modules an `import` asks for: the very map
  /// is kept and read live, and an entry is a module itself or a factory, a
  /// zero-argument function returning one.
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
    Map<String, Object?>? externalModules,
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
      externalModules: externalModules,
    ),
  );

  /// Runs a body with a checked-out session and closes the session afterward.
  ///
  /// [externalModules] holds the modules an `import` asks for: the very map
  /// is kept and read live, and an entry is a module itself or a factory, a
  /// zero-argument function returning one.
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
    Map<String, Object?>? externalModules,
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
      externalModules: externalModules,
    ),
  );

  /// Refuses new checkouts and closes idle workers.
  ///
  /// Open sessions and checkouts already waiting continue, and this call does
  /// not await or close them. A later session close resets its worker for an
  /// existing waiter or kills it when no waiter remains.
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
