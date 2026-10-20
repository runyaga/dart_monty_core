/// The worker pool: upstream `monty-pool`'s lifecycle in one pure-Dart
/// implementation over [MontyChannel].
///
/// The channel is the only backend-specific part, chosen by
/// `channel_factory.dart`'s conditional import.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';
import 'dart:collection';

import 'package:dart_monty_core/src/worker/channel_factory.dart' as chf;
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/suppressed_failures.dart';
import 'package:dart_monty_core/src/worker/telemetry.dart';
import 'package:dart_monty_core/src/worker/telemetry_metrics.dart';
import 'package:meta/meta.dart';

/// Starts one worker.
typedef OpenChannel = SpawnHandle Function();

/// A pool of workers, each dedicated to one checkout at a time.
///
/// Acquiring reuses an idle worker, discards one that died while idle, and
/// reserves a slot before spawning; with every slot taken it waits, up to
/// `checkoutTimeout`, for a release. Releasing sends `Reset` and returns the
/// worker to the idle list, or retires it after `maxCheckoutsPerWorker`
/// checkouts (upstream `pool.rs`, `checkout.rs`).
///
/// [close] refuses new checkouts and reaps idle workers. Checked-out
/// workers run on, and an [acquire] already started completes, as upstream's
/// do. A worker released after close goes, reset, to an [acquire] still
/// waiting, as upstream's does; with none waiting it is killed, as a closed
/// pool has no later reaping to hand it to (D-045).
///
/// A busy native worker outlives a parent that dies without closing it,
/// until the worker's own duration limit ends the run; an idle one exits
/// when its stdin reaches end-of-file. There is no watchdog, as upstream
/// has none.
final class WorkerPool {
  WorkerPool._(
    this.options,
    this.maxProcesses,
    this.startupTimeout,
    this._open,
  );

  /// How long a starting worker may take to become ready before it is
  /// cancelled and fails as [MontyCrashedError].
  ///
  /// Covers a Web Worker that loads but never greets.
  static const Duration defaultStartupTimeout = Duration(seconds: 30);

  /// The settings the pool was started with.
  final PoolOptions options;

  /// [PoolOptions.maxProcesses], or the platform's default.
  final int maxProcesses;

  /// See [defaultStartupTimeout].
  final Duration startupTimeout;

  final OpenChannel _open;
  final List<_Worker> _idleWorkers = [];
  final Queue<Completer<void>> _waiters = Queue();
  int _liveWorkers = 0;
  int _nextId = 1;
  bool _closed = false;
  Future<void>? _closing;

  /// Idle workers now. Diagnostics and tests: stale once returned.
  int get idleWorkers => _idleWorkers.length;

  /// Slots taken now: idle, checked-out and starting workers.
  int get liveWorkers => _liveWorkers;

  /// Starts [PoolOptions.minProcesses] workers, failing fast if any cannot
  /// start: the others still starting are cancelled and those already
  /// ready are closed before the error is rethrown.
  ///
  /// Throws [ArgumentError] before any worker starts for a setting
  /// upstream's constructor refuses, in its order and with its message
  /// ([PoolOptions.validate]), then for an impossible size: a
  /// [PoolOptions.minProcesses] below 0, an effective
  /// [PoolOptions.maxProcesses] below 1, or a minimum above it. The
  /// effective maximum is the setting or the platform's default, which can
  /// sit below [PoolOptions.minProcesses]: the processor count on native,
  /// the browser's reported hardware concurrency on the web, 4 where the
  /// browser reports none. Set [PoolOptions.maxProcesses] there.
  ///
  /// A worker that cannot be located or spawned ([CrashCause.spawn]), or is
  /// not ready within [startupTimeout] ([CrashCause.killed]), fails the
  /// call as [MontyCrashedError], after the cleanup above.
  ///
  /// [open] replaces the platform's channel factory in tests.
  static Future<WorkerPool> start([
    PoolOptions options = const PoolOptions(),
    @visibleForTesting OpenChannel? open,
    @visibleForTesting Duration startupTimeout = defaultStartupTimeout,
  ]) async {
    options.validate();
    final min = options.minProcesses;
    final max = options.maxProcesses ?? chf.defaultMaxProcesses();
    if (max < 1 || min < 0 || min > max) {
      throw ArgumentError(
        'invalid pool size: minProcesses=$min maxProcesses=$max',
      );
    }
    final location = options.workerLocation;
    final pool = WorkerPool._(
      options,
      max,
      startupTimeout,
      open ?? () => chf.openChannel(workerLocation: location),
    );
    final channels = await pool._startAll(min);
    for (final channel in channels) {
      pool._idleWorkers.add(_Worker(pool._nextId++, channel));
    }
    pool._liveWorkers = channels.length;
    workerDelta(channels.length, channels.length);

    return pool;
  }

  /// Dedicates a worker to the caller until its lease is released.
  ///
  /// Throws [TimeoutException] if no worker becomes free within
  /// [PoolOptions.checkoutTimeout], [StateError] if the pool is closed when
  /// it is called, and whatever the start of a new worker throws
  /// ([MontyCrashedError] when it is not ready within [startupTimeout]).
  ///
  /// [PoolOptions.checkoutTimeout] bounds only the wait for a slot: a new
  /// worker's spawn is bounded by [startupTimeout] and the session
  /// configured on the lease by [PoolOptions.requestTimeout], each a
  /// deadline of its own, so a checkout can take all three.
  ///
  /// A call made before [close] runs to its end, as upstream's acquisition
  /// holds its pool: it waits, spawns and is served as before.
  Future<WorkerLease> acquire() async {
    final waited = Stopwatch()..start();
    try {
      if (_closed) throw _closedError();
      final (worker, outcome) = await _acquireWorker(waited);
      TelemetryMetrics.checkout.duration(waited, outcome);

      return WorkerLease._(this, worker);
    } on Object catch (error) {
      TelemetryMetrics.checkout.duration(
        waited,
        error is _CheckoutTimeout ? 'exhausted' : 'error',
      );
      rethrow;
    }
  }

  /// Refuses new checkouts and asks idle workers to exit, waiting for them
  /// (upstream's `Pool::close`).
  ///
  /// Returns without waiting for checked-out workers, or for an [acquire]
  /// already started, which still completes, served by a worker released
  /// meanwhile or a new one. A worker released with no [acquire] waiting is
  /// killed. Idempotent.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    final idle = [..._idleWorkers];
    _idleWorkers.clear();
    _liveWorkers -= idle.length;
    workerDelta(0, -idle.length);
    for (final _ in idle) {
      TelemetryMetrics.terminated.attribute(1, 'reason', 'closed');
    }
    await Future.wait([for (final worker in idle) _closeWorker(worker)]);
  }

  /// Starts [count] workers; if one fails, cancels the rest, closes the
  /// ready ones, and rethrows the first failure.
  Future<List<MontyChannel>> _startAll(int count) async {
    final handles = _openEach(_open, count);
    final waiting = {...handles};
    final ready = <MontyChannel>[];
    final closing = <Future<void>>[];
    (Object, StackTrace)? failure;

    Future<void> settle(SpawnHandle handle) async {
      try {
        final channel = await _ready(handle);
        waiting.remove(handle);
        if (failure == null) {
          ready.add(channel);
        } else {
          closing.add(_closeSafely(channel, 'worker_pool.start_cleanup.close'));
        }
      } on Object catch (error, stack) {
        waiting.remove(handle);
        if (failure != null) {
          SuppressedFailures.record(
            error,
            stack,
            'worker_pool.start_cleanup.sibling_start',
          );

          return;
        }
        failure = (error, stack);
        _abortStartup(waiting, ready, closing);
      }
    }

    await Future.wait([for (final handle in handles) settle(handle)]);
    await Future.wait(closing);
    if (failure case (final error, final stack)) {
      Error.throwWithStackTrace(error, stack);
    }

    return ready;
  }

  /// Starts a worker into a slot already reserved, releasing the slot if
  /// the start fails.
  Future<MontyChannel> _spawnOne() async {
    try {
      return await _ready(_open());
    } on Object {
      _releaseSlot();
      rethrow;
    }
  }

  /// [handle]'s channel, or [MontyCrashedError] once [startupTimeout] passes,
  /// after cancelling it.
  Future<MontyChannel> _ready(SpawnHandle handle) => handle.ready.timeout(
    startupTimeout,
    onTimeout: () {
      _cancelSafely(handle, 'worker_pool.startup_timeout.cancel');
      throw crashedError(
        CrashCause.killed,
        detail: 'the worker was not ready within $startupTimeout',
      );
    },
  );

  /// Waits for a release, or throws [TimeoutException] once [waited] passes
  /// the checkout timeout. The wait for a slot is all that deadline
  /// covers: spawn and configure turns have deadlines of their own
  /// ([startupTimeout], [PoolOptions.requestTimeout]).
  Future<void> _waitForSlot(Stopwatch waited) async {
    final waiter = Completer<void>();
    _waiters.add(waiter);
    final limit = options.checkoutTimeout;
    if (limit == null) return waiter.future;
    final left = limit - waited.elapsed;
    final timer = Timer(left.isNegative ? Duration.zero : left, () {
      if (waiter.isCompleted) return;
      _waiters.remove(waiter);
      waiter.completeError(
        _CheckoutTimeout(limit),
        StackTrace.current,
      );
    });
    try {
      await waiter.future;
    } finally {
      timer.cancel();
    }
  }

  /// A worker left the pool: its slot is free, and the longest waiter
  /// retries.
  void _releaseSlot() {
    _liveWorkers--;
    workerDelta(-1, 0);
    if (_waiters.isNotEmpty) _waiters.removeFirst().complete();
  }

  /// Takes back a worker whose `Reset` succeeded: idle again, or retired
  /// when it reached `maxCheckoutsPerWorker`, or when the pool is closed and
  /// no [acquire] waits for it.
  void _takeBack(_Worker worker) {
    final max = options.maxCheckoutsPerWorker;
    final unwanted = _closed && _waiters.isEmpty;
    if (unwanted || (max != null && worker.served >= max)) {
      worker.channel.kill();
      TelemetryMetrics.terminated.attribute(
        1,
        'reason',
        unwanted ? 'closed' : 'recycled',
      );
      _releaseSlot();
    } else {
      _idleWorkers.add(worker);
      workerDelta(0, 1);
      if (_waiters.isNotEmpty) _waiters.removeFirst().complete();
    }
  }
}

/// How a [WorkerPool] is sized and bounded (upstream `PoolConfig`).
final class PoolOptions {
  /// The pool's settings; see each field.
  const PoolOptions({
    this.minProcesses = 1,
    this.maxProcesses,
    this.checkoutTimeout,
    this.requestTimeout,
    this.maxCheckoutsPerWorker,
    this.feedDurationLimitGrace = defaultDurationLimitGrace,
    this.turnDurationLimitGrace = defaultDurationLimitGrace,
    this.workerLocation,
  });

  /// Upstream's `DEFAULT_DURATION_LIMIT_GRACE`: one second, the default of
  /// [feedDurationLimitGrace] and [turnDurationLimitGrace].
  static const Duration defaultDurationLimitGrace = Duration(seconds: 1);

  /// Workers [WorkerPool.start] spawns eagerly; 0 or more, and at most the
  /// effective maximum ([WorkerPool.start] refuses the rest).
  final int minProcesses;

  /// The most workers alive at once, idle and checked out; null for the
  /// platform's default ([chf.defaultMaxProcesses]): the processor count
  /// on native, the browser's reported hardware concurrency on the web, 4
  /// where the browser reports none. Must be 1 or more and at least
  /// [minProcesses]; a platform default below [minProcesses] is refused,
  /// so set this there.
  final int? maxProcesses;

  /// How long [WorkerPool.acquire] waits for a free slot; forever when
  /// null. Bounds only that wait: a new worker's spawn is bounded by
  /// [WorkerPool.startupTimeout] and the session's configure turn by
  /// [requestTimeout], each its own deadline. Must not be negative.
  final Duration? checkoutTimeout;

  /// How long any one protocol turn may take before its worker is killed;
  /// unbounded when null. A lease's `Reset` turn and a session's configure
  /// turn are turns. Must not be negative.
  final Duration? requestTimeout;

  /// Checkouts a worker serves before it is retired; unbounded when null.
  /// 0 retires each worker at its first release. Upstream's is a `u32`: 0
  /// to 2^32 - 1, and [validate] refuses the rest.
  final int? maxCheckoutsPerWorker;

  /// How far past what a session's `maxFeedDuration` has left the parent
  /// lets an execution turn run before it kills the worker; null leaves the
  /// feed budget unguarded by the parent (upstream
  /// `feed_duration_limit_grace`). One second by default
  /// ([defaultDurationLimitGrace]); must not be negative.
  final Duration? feedDurationLimitGrace;

  /// How far past a session's `maxTurnDuration` the parent lets an
  /// execution turn run before it kills the worker; null leaves the turn
  /// budget unguarded by the parent (upstream `turn_duration_limit_grace`).
  /// One second by default ([defaultDurationLimitGrace]); must not be
  /// negative.
  final Duration? turnDurationLimitGrace;

  /// Where the worker is found: an executable on native, an asset base URL
  /// on the web; null to search the usual places.
  final String? workerLocation;

  /// Throws [ArgumentError] for a setting upstream's constructor refuses,
  /// in its order and with its message: a negative [minProcesses] or
  /// [maxProcesses] (its `usize` extraction's `OverflowError`),
  /// [maxCheckoutsPerWorker] outside 0..2^32-1 (`u32`), then a negative
  /// duration (`duration_from_secs`'s `ValueError`).
  void validate() {
    for (final (value, name) in [
      (minProcesses, 'minProcesses'),
      (maxProcesses, 'maxProcesses'),
    ]) {
      if (value != null && value < 0) {
        throw ArgumentError.value(
          value,
          name,
          "can't convert negative int to unsigned",
        );
      }
    }
    final recycle = maxCheckoutsPerWorker;
    if (recycle != null && (recycle < 0 || recycle > _maxU32)) {
      throw ArgumentError.value(
        recycle,
        'maxCheckoutsPerWorker',
        'number too ${recycle < 0 ? 'small' : 'large'} to fit in target type',
      );
    }
    _duration(checkoutTimeout, 'checkoutTimeout', 'checkout_timeout');
    _duration(requestTimeout, 'requestTimeout', 'request_timeout');
    _duration(
      feedDurationLimitGrace,
      'feedDurationLimitGrace',
      'feed_duration_limit_grace',
    );
    _duration(
      turnDurationLimitGrace,
      'turnDurationLimitGrace',
      'turn_duration_limit_grace',
    );
  }
}

/// `u32::MAX`.
const int _maxU32 = 0xFFFFFFFF;

/// Throws upstream's `duration_from_secs` refusal of [value], the argument
/// [name] (upstream's [upstreamName]).
void _duration(Duration? value, String name, String upstreamName) {
  final refusal = value == null ? null : durationRefusal(value);
  if (refusal != null) {
    throw ArgumentError.value(value, name, 'invalid $upstreamName: $refusal');
  }
}

StateError _closedError() => StateError('the monty pool is closed');

/// [count] starts from [open]; if [open] throws, cancels the ones already
/// made and rethrows.
List<SpawnHandle> _openEach(OpenChannel open, int count) {
  final handles = <SpawnHandle>[];
  try {
    for (var i = 0; i < count; i++) {
      handles.add(open());
    }
  } on Object {
    for (final handle in handles) {
      _cancelSafely(handle, 'worker_pool.open_rollback.cancel');
    }
    rethrow;
  }

  return handles;
}

void _abortStartup(
  Set<SpawnHandle> waiting,
  List<MontyChannel> ready,
  List<Future<void>> closing,
) {
  for (final other in [...waiting]) {
    _cancelSafely(other, 'worker_pool.start_cleanup.cancel');
  }
  for (final channel in ready) {
    closing.add(_closeSafely(channel, 'worker_pool.start_cleanup.close'));
  }
  ready.clear();
}

void _cancelSafely(SpawnHandle handle, String stage) {
  try {
    handle.cancel();
  } on Object catch (error, stack) {
    SuppressedFailures.record(error, stack, stage);
  }
}

Future<void> _closeSafely(MontyChannel channel, String stage) async {
  try {
    await channel.close();
  } on Object catch (error, stack) {
    SuppressedFailures.record(error, stack, stage);
  }
}

final class _Worker {
  _Worker(this.id, this.channel);

  final int id;
  final MontyChannel channel;

  /// Checkouts whose `Reset` succeeded (upstream `checkouts_served`).
  int served = 0;
}

/// One checkout's hold on a worker and its pool slot.
///
/// Single use: [release] or [kill] gives the slot back exactly once,
/// whichever comes first and however often either is called.
final class WorkerLease {
  WorkerLease._(this._pool, this._worker)
    : _metrics = telemetryBridge == null ? null : SessionMetrics();

  final SessionMetrics? _metrics;
  final WorkerPool _pool;
  final _Worker _worker;
  bool _isReleased = false;
  Future<void>? _releasing;

  /// The worker's channel. Throws [StateError] once the lease has ended:
  /// the worker may then serve another lease.
  MontyChannel get channel {
    if (_isReleased) throw StateError('this worker lease has been released');

    return _worker.channel;
  }

  /// The worker's pool-unique id; a reused worker keeps it.
  int get workerId => _worker.id;

  /// The worker's process id; null on the web, and once the lease has
  /// ended.
  int? get pid => _isReleased ? null : chf.channelPid(_worker.channel);

  /// Whether the slot has been given back.
  bool get isReleased => _isReleased;

  /// Sends `Reset` and, on `Ok`, gives the worker back to the pool;
  /// otherwise kills it and rethrows the failure (a reply other than `Ok`
  /// is a [StateError]). The `Reset` turn is bounded by the pool's
  /// `requestTimeout`. Once the pool is closed it kills the worker at once,
  /// without a `Reset`, unless an [WorkerPool.acquire] is waiting for it.
  ///
  /// Completes normally if [kill] ends the lease first. Idempotent.
  Future<void> release() => _releasing ??= _release();

  /// Kills the worker now and gives its slot back, unless the lease already
  /// ended. A turn in flight, `Reset` included, fails as killed.
  void kill({String reason = 'abandoned', String outcome = 'abandoned'}) {
    if (_isReleased) return;
    _isReleased = true;
    _worker.channel.kill();
    TelemetryMetrics.terminated.attribute(1, 'reason', reason);
    _metrics?.finish(outcome);
    _pool._releaseSlot();
  }

  Future<void> _release() async {
    if (_isReleased) return;
    // A closed pool keeps no idle worker: unless an acquire waits for this
    // one, there is nothing to Reset for.
    if (_pool._closed && _pool._waiters.isEmpty) {
      kill(reason: 'closed', outcome: 'ok');

      return;
    }
    final worker = _worker;
    final limit = _pool.options.requestTimeout;
    final timer = limit == null ? null : Timer(limit, worker.channel.kill);
    try {
      final reply = await worker.channel.turn(
        pb.ParentRequest(reset: pb.Reset()),
      );
      _checkReset(reply);
    } on Object {
      if (_isReleased) return;
      kill(reason: 'discarded', outcome: 'error');
      rethrow;
    } finally {
      timer?.cancel();
    }
    if (_isReleased) return;
    _isReleased = true;
    worker.served++;
    _pool._takeBack(worker);
    _metrics?.finish('ok');
  }

  void _checkReset(pb.ChildEvent reply) {
    final kind = reply.whichKind();
    if (kind != pb.ChildEvent_Kind.ok) {
      throw StateError('unexpected reply to Reset: $kind');
    }
  }
}

extension on WorkerPool {
  Future<void> _closeWorker(_Worker worker) async {
    try {
      await worker.channel.close();
    } finally {
      workerDelta(-1, 0);
    }
  }

  Future<(_Worker, String)> _acquireWorker(Stopwatch clock) async {
    var waited = false;
    for (;;) {
      final (reused, died, removed) = _takeIdle();
      final spawn = reused == null && _liveWorkers < maxProcesses;
      if (spawn) _liveWorkers++;
      workerDelta((spawn ? 1 : 0) - died, -removed);
      if (reused != null) return (reused, waited ? 'waited' : 'idle');
      if (spawn) {
        final worker = _Worker(_nextId++, await _spawnOne());

        return (worker, waited ? 'waited' : 'spawned');
      }
      waited = true;
      await _waitForSlot(clock);
    }
  }

  (_Worker?, int, int) _takeIdle() {
    var died = 0;
    var removed = 0;
    while (_idleWorkers.isNotEmpty) {
      final worker = _idleWorkers.removeLast();
      removed++;
      if (worker.channel.isAlive) return (worker, died, removed);
      worker.channel.kill();
      _liveWorkers--;
      died++;
      TelemetryMetrics.terminated.attribute(1, 'reason', 'died_idle');
    }

    return (null, died, removed);
  }
}

/// Distinguishes capacity exhaustion from a timeout raised by the spawner.
final class _CheckoutTimeout extends TimeoutException {
  _CheckoutTimeout(Duration limit)
    : super(
        'no monty worker became available within the checkout timeout',
        limit,
      );
}
