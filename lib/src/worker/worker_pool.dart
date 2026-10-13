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
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
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
/// [close] refuses new checkouts and reaps idle workers; checked-out
/// workers run on, and each is killed when its lease is released.
///
/// A busy native worker outlives a parent that dies without closing it,
/// until the worker's own duration limit ends the run; an idle one exits
/// when its stdin reaches end-of-file. There is no watchdog, as upstream
/// has none.
final class WorkerPool {
  WorkerPool._({
    required this.minProcesses,
    required this.maxProcesses,
    required this.checkoutTimeout,
    required this.requestTimeout,
    required this.maxCheckoutsPerWorker,
    required this.startupTimeout,
    required OpenChannel open,
  }) : _open = open;

  /// How long a starting worker may take to become ready before it is
  /// cancelled and fails as [MontyCrashedError].
  ///
  /// Covers a Web Worker that loads but never greets.
  static const Duration defaultStartupTimeout = Duration(seconds: 30);

  /// Starts [minProcesses] workers, failing fast if any cannot start.
  ///
  /// [maxProcesses] defaults to the platform's ([chf.defaultMaxProcesses]).
  /// [workerLocation] overrides where the worker is found: an executable on
  /// native, an asset base URL on the web. If a worker fails, the others
  /// still starting are cancelled and those already ready are closed before
  /// the error is rethrown.
  static Future<WorkerPool> start({
    int minProcesses = 1,
    int? maxProcesses,
    Duration? checkoutTimeout,
    Duration? requestTimeout,
    int? maxCheckoutsPerWorker,
    String? workerLocation,
    @visibleForTesting OpenChannel? open,
    @visibleForTesting Duration startupTimeout = defaultStartupTimeout,
  }) async {
    final max = maxProcesses ?? chf.defaultMaxProcesses();
    if (max < 1 || minProcesses < 0 || minProcesses > max) {
      throw ArgumentError(
        'invalid pool size: minProcesses=$minProcesses maxProcesses=$max',
      );
    }
    if (maxCheckoutsPerWorker != null && maxCheckoutsPerWorker < 1) {
      throw ArgumentError.value(
        maxCheckoutsPerWorker,
        'maxCheckoutsPerWorker',
        'must be at least 1',
      );
    }
    final pool = WorkerPool._(
      minProcesses: minProcesses,
      maxProcesses: max,
      checkoutTimeout: checkoutTimeout,
      requestTimeout: requestTimeout,
      maxCheckoutsPerWorker: maxCheckoutsPerWorker,
      startupTimeout: startupTimeout,
      open: open ?? () => chf.openChannel(workerLocation: workerLocation),
    );
    final channels = await pool._startAll(minProcesses);
    for (final channel in channels) {
      pool._idle.add(_Worker(pool._nextId++, channel));
    }
    pool._total = channels.length;

    return pool;
  }

  /// Workers [start] spawns eagerly.
  final int minProcesses;

  /// The most workers alive at once, idle and checked out.
  final int maxProcesses;

  /// How long [acquire] waits for a free slot; forever when null.
  final Duration? checkoutTimeout;

  /// How long a lease's `Reset` turn may take before its worker is killed;
  /// unbounded when null.
  final Duration? requestTimeout;

  /// Checkouts a worker serves before it is retired; unbounded when null.
  final int? maxCheckoutsPerWorker;

  /// See [defaultStartupTimeout].
  final Duration startupTimeout;

  final OpenChannel _open;
  final List<_Worker> _idle = [];
  final Queue<Completer<void>> _waiters = Queue();
  final Set<SpawnHandle> _starting = {};
  int _total = 0;
  int _nextId = 1;
  bool _closed = false;
  Future<void>? _closing;

  /// Idle workers now. Diagnostics and tests: stale once returned.
  int get idleWorkers => _idle.length;

  /// Slots taken now: idle, checked-out and starting workers.
  int get liveWorkers => _total;

  /// Whether [close] has run.
  bool get isClosed => _closed;

  /// Dedicates a worker to the caller until its lease is released.
  ///
  /// Throws [TimeoutException] if no worker becomes free within
  /// [checkoutTimeout], [StateError] once the pool is closed, and whatever
  /// the start of a new worker throws ([MontyCrashedError] when it is not
  /// ready within [startupTimeout]).
  Future<WorkerLease> acquire() async {
    final waited = Stopwatch()..start();
    for (;;) {
      if (_closed) throw _closedError();
      while (_idle.isNotEmpty) {
        final worker = _idle.removeLast();
        if (worker.channel.isAlive) return WorkerLease._(this, worker);
        // Died while idle; this acquire or a later one replaces it.
        _total--;
      }
      if (_total < maxProcesses) {
        // Reserve the slot before the start, as upstream does.
        _total++;

        return WorkerLease._(this, _Worker(_nextId++, await _spawnOne()));
      }
      await _waitForSlot(waited);
    }
  }

  /// Refuses new checkouts, fails every waiting [acquire], cancels workers
  /// still starting, and asks idle workers to exit, waiting for them.
  ///
  /// Returns without waiting for checked-out workers: each is killed when
  /// its lease is released. Idempotent.
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    while (_waiters.isNotEmpty) {
      _waiters.removeFirst().completeError(_closedError());
    }
    for (final handle in [..._starting]) {
      handle.cancel();
    }
    final idle = [..._idle];
    _idle.clear();
    _total -= idle.length;
    await Future.wait([for (final worker in idle) worker.channel.close()]);
  }

  /// Starts [count] workers; if one fails, cancels the rest, closes the
  /// ready ones, and rethrows the first failure.
  Future<List<MontyChannel>> _startAll(int count) async {
    final handles = [for (var i = 0; i < count; i++) _open()];
    final waiting = {...handles};
    final ready = <MontyChannel>[];
    final closing = <Future<void>>[];
    (Object, StackTrace)? failure;
    await Future.wait([
      for (final handle in handles)
        _ready(handle).then(
          (channel) {
            waiting.remove(handle);
            if (failure == null) {
              ready.add(channel);
            } else {
              closing.add(channel.close());
            }
          },
          onError: (Object error, StackTrace stack) {
            waiting.remove(handle);
            if (failure != null) return;
            failure = (error, stack);
            for (final other in [...waiting]) {
              other.cancel();
            }
            closing.addAll([for (final channel in ready) channel.close()]);
            ready.clear();
          },
        ),
    ]);
    await Future.wait(closing);
    if (failure case (final error, final stack)) {
      Error.throwWithStackTrace(error, stack);
    }

    return ready;
  }

  /// Starts a worker into a slot already reserved, releasing the slot if
  /// the start fails or the pool closes meanwhile.
  Future<MontyChannel> _spawnOne() async {
    final handle = _open();
    _starting.add(handle);
    final MontyChannel channel;
    try {
      channel = await _ready(handle);
    } on Object {
      _releaseSlot();
      if (_closed) throw _closedError();
      rethrow;
    } finally {
      _starting.remove(handle);
    }
    if (_closed) {
      channel.kill();
      _releaseSlot();
      throw _closedError();
    }

    return channel;
  }

  /// [handle]'s channel, or [MontyCrashedError] once [startupTimeout] passes,
  /// after cancelling it.
  Future<MontyChannel> _ready(SpawnHandle handle) => handle.ready.timeout(
    startupTimeout,
    onTimeout: () {
      handle.cancel();
      throw MontyCrashedError(
        CrashCause.killed,
        message: 'the worker was not ready within $startupTimeout',
      );
    },
  );

  /// Waits for a release, or throws [TimeoutException] once [waited] passes
  /// [checkoutTimeout].
  Future<void> _waitForSlot(Stopwatch waited) async {
    final waiter = Completer<void>();
    _waiters.add(waiter);
    final limit = checkoutTimeout;
    if (limit == null) return waiter.future;
    final left = limit - waited.elapsed;
    final timer = Timer(left.isNegative ? Duration.zero : left, () {
      if (waiter.isCompleted) return;
      _waiters.remove(waiter);
      waiter.completeError(
        TimeoutException(
          'no monty worker became available within $limit',
          limit,
        ),
      );
    });
    try {
      await waiter.future;
    } finally {
      timer.cancel();
    }
  }

  /// Wakes the longest waiter, which retries.
  void _wake() {
    if (_waiters.isNotEmpty) _waiters.removeFirst().complete();
  }

  /// A worker left the pool: its slot is free.
  void _releaseSlot() {
    _total--;
    _wake();
  }

  /// Takes back a worker whose `Reset` succeeded: idle again, or retired
  /// when it reached [maxCheckoutsPerWorker] or the pool is closed.
  void _takeBack(_Worker worker) {
    final max = maxCheckoutsPerWorker;
    if (_closed || (max != null && worker.served >= max)) {
      worker.channel.kill();
      _releaseSlot();
    } else {
      _idle.add(worker);
      _wake();
    }
  }

  StateError _closedError() => StateError('the monty pool is closed');
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
  WorkerLease._(this._pool, this._worker);

  final WorkerPool _pool;
  final _Worker _worker;
  bool _done = false;
  Future<void>? _releasing;

  /// The worker's channel. Throws [StateError] once the lease has ended:
  /// the worker may then serve another lease.
  MontyChannel get channel {
    if (_done) throw StateError('this worker lease has been released');

    return _worker.channel;
  }

  /// The worker's pool-unique id; a reused worker keeps it.
  int get workerId => _worker.id;

  /// Whether the slot has been given back.
  bool get isReleased => _done;

  /// Sends `Reset` and, on `Ok`, gives the worker back to the pool;
  /// otherwise kills it and rethrows the failure (a reply other than `Ok`
  /// is a [StateError]). The `Reset` turn is bounded by the pool's
  /// `requestTimeout`.
  ///
  /// Completes normally if [kill] ends the lease first. Idempotent.
  Future<void> release() => _releasing ??= _release();

  /// Kills the worker now and gives its slot back, unless the lease already
  /// ended. A turn in flight, `Reset` included, fails as killed.
  void kill() {
    if (_done) return;
    _done = true;
    _worker.channel.kill();
    _pool._releaseSlot();
  }

  Future<void> _release() async {
    if (_done) return;
    final channel = _worker.channel;
    final limit = _pool.requestTimeout;
    final timer = limit == null ? null : Timer(limit, channel.kill);
    try {
      final reply = await channel.turn(pb.ParentRequest(reset: pb.Reset()));
      if (reply.whichKind() != pb.ChildEvent_Kind.ok) {
        throw StateError('unexpected reply to Reset: ${reply.whichKind()}');
      }
    } on Object {
      if (_done) return;
      kill();
      rethrow;
    } finally {
      timer?.cancel();
    }
    if (_done) return;
    _done = true;
    _worker.served++;
    _pool._takeBack(_worker);
  }
}
