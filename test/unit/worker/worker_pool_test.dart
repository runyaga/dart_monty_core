// WorkerPool's mechanics over scripted channels and scripted starts: no
// worker runs. Pure Dart: vm, dart2js and dart2wasm.
import 'dart:async';

import 'package:dart_monty_core/src/worker/asset_base.dart';
import 'package:dart_monty_core/src/worker/channel_factory.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_scripted_channel.dart';

/// A channel that answers every `Reset` with `Ok`, [resets] times.
ScriptedChannel resettable({int resets = 20}) => ScriptedChannel([
  for (var i = 0; i < resets; i++) answer([ok()]),
]);

/// One scripted worker start.
final class FakeStart {
  /// Whether the pool cancelled it.
  bool cancelled = false;

  /// The channel it completed with, if any.
  ScriptedChannel? completedWith;

  final _channel = Completer<MontyChannel>();

  /// The channel it completed with; fails the test if it has none.
  ScriptedChannel get channel =>
      completedWith ?? fail('this start has no channel');

  /// Becomes ready with [ch] (default: a [resettable] channel).
  void succeed([ScriptedChannel? ch]) =>
      _channel.complete(completedWith = ch ?? resettable());

  /// Fails with [error].
  void failWith(Object error) =>
      _channel.completeError(error, StackTrace.current);

  Future<MontyChannel> run(Future<void> cancel) {
    unawaited(_noteCancel(cancel));

    return _channel.future;
  }

  Future<void> _noteCancel(Future<void> cancel) async {
    await cancel;
    cancelled = true;
  }
}

/// The pool's `open`: records each start; with [auto], each is ready at
/// once with a fresh [resettable] channel.
final class FakeStarts {
  FakeStarts({this.auto = true});

  /// Whether starts become ready by themselves.
  final bool auto;

  /// Every start so far, in order.
  final List<FakeStart> all = [];

  /// Start [i].
  FakeStart at(int i) => itemAt(all, i);

  /// The only start.
  FakeStart get only => onlyItem(all);

  SpawnHandle open() {
    final start = FakeStart();
    all.add(start);
    if (auto) start.succeed();

    return PendingSpawn(start.run);
  }
}

/// Lets pending microtasks and zero timers run.
Future<void> pump() => Future.delayed(Duration.zero);

/// [count] checkouts of [pool], one after the other.
Future<List<WorkerLease>> acquireEach(WorkerPool pool, int count) async => [
  for (var i = 0; i < count; i++) await pool.acquire(),
];

/// Matches a [MontyCrashedError] with [CrashCause.killed].
final Matcher throwsKilled = throwsA(
  isA<MontyCrashedError>().having((e) => e.cause, 'cause', CrashCause.killed),
);

void main() {
  late FakeStarts starts;

  Future<WorkerPool> pool(
    PoolOptions options, {
    Duration startupTimeout = WorkerPool.defaultStartupTimeout,
  }) async {
    final p = await WorkerPool.start(options, starts.open, startupTimeout);
    addTearDown(p.close);

    return p;
  }

  setUp(() => starts = FakeStarts());

  group('start', () {
    test('spawns minProcesses, all idle', () async {
      final p = await pool(const PoolOptions(minProcesses: 2, maxProcesses: 3));
      expect(starts.all, hasLength(2));
      expect(p.idleWorkers, 2);
      expect(p.liveWorkers, 2);
    });

    test('rejects an impossible size', () {
      for (final (min, max) in [(3, 2), (0, 0), (-1, 2)]) {
        expect(
          () => WorkerPool.start(
            PoolOptions(minProcesses: min, maxProcesses: max),
            starts.open,
          ),
          throwsArgumentError,
          reason: 'min $min, max $max',
        );
      }
      expect(
        () => WorkerPool.start(
          const PoolOptions(maxCheckoutsPerWorker: 0),
          starts.open,
        ),
        throwsArgumentError,
      );
      expect(starts.all, isEmpty);
    });

    test('fails fast: cancels the starting, closes the ready', () async {
      starts = FakeStarts(auto: false);
      final started = WorkerPool.start(
        const PoolOptions(minProcesses: 3, maxProcesses: 3),
        starts.open,
      );
      final ready = starts.at(0)..succeed();
      await pump();
      starts.at(1).failWith(StateError('no worker here'));
      await expectLater(started, throwsA(isA<StateError>()));
      await pump();
      expect(ready.channel.closes, 1, reason: 'the ready one');
      expect(ready.channel.kills, 0, reason: 'closed, not killed');
      final pending = starts.at(2);
      expect(pending.cancelled, isTrue, reason: 'the starting one');
      // It arrives anyway: it is killed, not leaked.
      pending.succeed();
      await pump();
      expect(pending.channel.kills, 1);
      expect(pending.channel.isAlive, isFalse);
    });

    test('a worker that never becomes ready fails it', () async {
      starts = FakeStarts(auto: false);
      await expectLater(
        WorkerPool.start(
          const PoolOptions(),
          starts.open,
          const Duration(milliseconds: 50),
        ),
        throwsKilled,
      );
      await pump();
      expect(starts.only.cancelled, isTrue);
    });
  });

  group('acquire', () {
    test('reuses the idle worker, then spawns up to max', () async {
      final p = await pool(const PoolOptions(maxProcesses: 2));
      final [a, b] = await acquireEach(p, 2);
      expect([a.workerId, b.workerId], [1, 2]);
      expect(starts.all, hasLength(2), reason: 'the idle one was reused');
      expect(p.liveWorkers, 2);
      expect(p.idleWorkers, 0);
      await a.release();
      expect(p.idleWorkers, 1);
      final [c] = await acquireEach(p, 1);
      expect(c.workerId, 1, reason: 'released, reset, reused');
      expect(
        starts.at(0).channel.requests.map((r) => r.whichKind()),
        [pb.ParentRequest_Kind.reset],
      );
      await b.release();
      await c.release();
    });

    test('waits for a release at max, and gets that worker', () async {
      final p = await pool(const PoolOptions(maxProcesses: 1));
      final [a] = await acquireEach(p, 1);
      var got = false;
      final waiting = acquireEach(p, 1);
      unawaited(waiting.whenComplete(() => got = true));
      await pump();
      expect(got, isFalse);
      await a.release();
      final [b] = await waiting;
      expect(b.workerId, a.workerId);
      expect(starts.all, hasLength(1));
      await b.release();
    });

    test('times out after checkoutTimeout, then still serves', () async {
      final p = await pool(
        const PoolOptions(
          maxProcesses: 1,
          checkoutTimeout: Duration(milliseconds: 50),
        ),
      );
      final [a] = await acquireEach(p, 1);
      final clock = Stopwatch()..start();
      await expectLater(acquireEach(p, 1), throwsA(isA<TimeoutException>()));
      expect(clock.elapsedMilliseconds, greaterThanOrEqualTo(40));
      expect(p.liveWorkers, 1);
      // The timed-out waiter left no stale entry to swallow the wake-up.
      final waiting = acquireEach(p, 1);
      await a.release();
      final [b] = await waiting;
      expect(b.workerId, a.workerId);
      await b.release();
    });

    test('a slot freed by a kill wakes a waiter, which spawns', () async {
      final p = await pool(const PoolOptions(maxProcesses: 1));
      final [a] = await acquireEach(p, 1);
      final waiting = acquireEach(p, 1);
      a.kill();
      final [b] = await waiting;
      expect(b.workerId, 2);
      expect(p.liveWorkers, 1);
      await b.release();
    });

    test('discards a worker that died while idle', () async {
      final p = await pool(const PoolOptions(maxProcesses: 1));
      starts.at(0).channel.kill();
      final [a] = await acquireEach(p, 1);
      expect(a.workerId, 2);
      expect(starts.all, hasLength(2));
      expect(p.liveWorkers, 1);
      await a.release();
    });

    test('a failed start gives its slot back', () async {
      starts = FakeStarts(auto: false);
      final p = await pool(const PoolOptions(minProcesses: 0, maxProcesses: 1));
      final first = acquireEach(p, 1);
      starts.at(0).failWith(StateError('no worker here'));
      await expectLater(first, throwsA(isA<StateError>()));
      expect(p.liveWorkers, 0);
      final second = acquireEach(p, 1);
      starts.at(1).succeed();
      final [lease] = await second;
      expect(p.liveWorkers, 1);
      await lease.release();
    });

    test('a worker that never becomes ready is cancelled and its slot '
        'given back', () async {
      starts = FakeStarts(auto: false);
      final p = await pool(
        const PoolOptions(minProcesses: 0, maxProcesses: 1),
        startupTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(acquireEach(p, 1), throwsKilled);
      await pump();
      final start = starts.only;
      expect(start.cancelled, isTrue);
      expect(p.liveWorkers, 0);
      // It greets at last: killed on arrival.
      start.succeed();
      await pump();
      expect(start.channel.kills, 1);
    });
  });

  group('release', () {
    test('retires a worker after maxCheckoutsPerWorker', () async {
      final p = await pool(
        const PoolOptions(maxProcesses: 1, maxCheckoutsPerWorker: 2),
      );
      for (var i = 0; i < 2; i++) {
        final [lease] = await acquireEach(p, 1);
        expect(lease.workerId, 1);
        await lease.release();
      }
      expect(starts.at(0).channel.kills, 1);
      expect(p.liveWorkers, 0);
      final [next] = await acquireEach(p, 1);
      expect(next.workerId, 2);
      await next.release();
    });

    test('a Reset that fails kills the worker and rethrows', () async {
      starts = FakeStarts(auto: false);
      final p = await pool(const PoolOptions(minProcesses: 0, maxProcesses: 1));
      final acquired = acquireEach(p, 1);
      final start = starts.only
        ..succeed(
          ScriptedChannel([
            answer([raised('X')]),
          ]),
        );
      final [lease] = await acquired;
      await expectLater(lease.release(), throwsA(isA<StateError>()));
      expect(start.channel.kills, 1);
      expect(p.liveWorkers, 0);
      expect(lease.isReleased, isTrue);
    });

    test('a Reset over requestTimeout kills the worker', () async {
      starts = FakeStarts(auto: false);
      final p = await pool(
        const PoolOptions(
          minProcesses: 0,
          maxProcesses: 1,
          requestTimeout: Duration(milliseconds: 50),
        ),
      );
      final acquired = acquireEach(p, 1);
      starts.only.succeed(ScriptedChannel([hangAfter([])]));
      final [lease] = await acquired;
      await expectLater(lease.release(), throwsKilled);
      expect(p.liveWorkers, 0);
    });
  });

  group('one lease, one release', () {
    test('release twice: one Reset, one slot back', () async {
      final p = await pool(const PoolOptions(maxProcesses: 1));
      final [lease] = await acquireEach(p, 1);
      final first = lease.release();
      expect(lease.release(), same(first));
      await first;
      await lease.release();
      expect(starts.at(0).channel.requests, hasLength(1));
      expect(p.liveWorkers, 1);
      expect(p.idleWorkers, 1);
    });

    test('kill twice, then release: one slot back', () async {
      final p = await pool(const PoolOptions(maxProcesses: 2));
      final [a, b] = await acquireEach(p, 2);
      a
        ..kill()
        ..kill();
      await a.release();
      expect(p.liveWorkers, 1);
      final killed = starts.at(0).channel;
      expect(killed.kills, 1);
      expect(killed.requests, isEmpty);
      await b.release();
    });

    test('release, then kill: the kill does nothing', () async {
      final p = await pool(const PoolOptions(maxProcesses: 1));
      final [lease] = await acquireEach(p, 1);
      final channel = lease.channel;
      await lease.release();
      expect(() => lease.channel, throwsStateError);
      lease.kill();
      final only = starts.at(0).channel;
      expect(channel, same(only));
      expect(only.kills, 0);
      expect(p.idleWorkers, 1);
      expect(p.liveWorkers, 1);
    });

    test('a kill during the Reset wins, once', () async {
      starts = FakeStarts(auto: false);
      final p = await pool(const PoolOptions(minProcesses: 0, maxProcesses: 1));
      final acquired = acquireEach(p, 1);
      final start = starts.only..succeed(ScriptedChannel([hangAfter([])]));
      final [lease] = await acquired;
      final releasing = lease.release();
      await pump();
      lease.kill();
      await releasing;
      expect(lease.isReleased, isTrue);
      expect(p.liveWorkers, 0);
      expect(start.channel.kills, 1);
    });
  });

  group('close', () {
    test('reaps idle workers and refuses checkouts', () async {
      final p = await pool(const PoolOptions(minProcesses: 2, maxProcesses: 2));
      final [held] = await acquireEach(p, 1);
      final heldChannel = held.channel as ScriptedChannel;
      final idleChannel = starts.at(2 - held.workerId).channel;
      await p.close();
      await expectLater(acquireEach(p, 1), throwsA(isA<StateError>()));
      expect(p.idleWorkers, 0);
      expect(idleChannel.closes, 1);
      // A checked-out worker runs on, and is killed when released.
      expect(heldChannel.isAlive, isTrue);
      expect(p.liveWorkers, 1);
      await held.release();
      expect(heldChannel.kills, 1);
      expect(p.liveWorkers, 0);
    });

    test('fails a waiting acquire', () async {
      final p = await pool(const PoolOptions(maxProcesses: 1));
      final [held] = await acquireEach(p, 1);
      final waiting = expectLater(
        acquireEach(p, 1),
        throwsA(isA<StateError>()),
      );
      await pump();
      await p.close();
      await waiting;
      held.kill();
      expect(p.liveWorkers, 0);
    });

    test('cancels a worker still starting', () async {
      starts = FakeStarts(auto: false);
      final p = await pool(const PoolOptions(minProcesses: 0, maxProcesses: 1));
      final acquired = expectLater(
        acquireEach(p, 1),
        throwsA(isA<StateError>()),
      );
      await pump();
      await p.close();
      await acquired;
      await pump();
      final start = starts.only;
      expect(start.cancelled, isTrue);
      expect(p.liveWorkers, 0);
      start.succeed();
      await pump();
      expect(start.channel.kills, 1, reason: 'killed on arrival');
    });

    test('is idempotent', () async {
      final p = await pool(const PoolOptions(maxProcesses: 1));
      final first = p.close();
      expect(p.close(), same(first));
      await first;
      expect(starts.at(0).channel.closes, 1);
    });
  });

  group('PendingSpawn', () {
    test('cancel after ready kills the channel', () async {
      final ch = resettable();
      final handle = PendingSpawn((_) async => ch);
      expect(await handle.ready, same(ch));
      handle
        ..cancel()
        ..cancel();
      expect(ch.kills, 1);
    });

    test('a failed start fails ready with its error', () async {
      final handle = PendingSpawn((_) async => throw StateError('nope'));
      await expectLater(handle.ready, throwsA(isA<StateError>()));
      handle.cancel();
    });

    test('a cancelled start that fails reports only the cancel', () async {
      final failing = Completer<MontyChannel>();
      final handle = PendingSpawn((_) => failing.future)..cancel();
      failing.completeError(StateError('late'), StackTrace.current);
      await expectLater(handle.ready, throwsKilled);
    });
  });

  group('the channel factory', () {
    test('defaultMaxProcesses is at least 1', () {
      expect(defaultMaxProcesses(), greaterThanOrEqualTo(1));
    });

    test('asset bases: the Flutter layout first, then the package', () async {
      final tried = <String>[];
      final base = await resolveAssetBase((url) async {
        tried.add(url);

        return url.startsWith(packageAssetBase);
      });
      expect(base, packageAssetBase);
      expect(tried, [
        workerScriptUrl(flutterAssetBase),
        workerScriptUrl(packageAssetBase),
      ]);
      expect(await resolveAssetBase((_) async => true), flutterAssetBase);
      expect(workerWasmUrl('b'), 'b/dart_monty_core_proto_worker.wasm');
    });

    test('no assets anywhere: a StateError naming what was tried', () {
      expect(
        resolveAssetBase((_) async => false),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains(workerScriptUrl(flutterAssetBase)),
              contains(workerScriptUrl(packageAssetBase)),
            ),
          ),
        ),
      );
    });
  });
}
