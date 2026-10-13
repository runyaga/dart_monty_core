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

import '_scripted_channel.dart';

/// A channel that answers every `Reset` with `Ok`, [resets] times.
ScriptedChannel resettable({int resets = 20}) => ScriptedChannel([
  for (var i = 0; i < resets; i++) answer([ok()]),
]);

/// One scripted worker start.
final class FakeStart {
  final _channel = Completer<MontyChannel>();

  /// Whether the pool cancelled it.
  bool cancelled = false;

  /// The channel it completed with, if any.
  ScriptedChannel? channel;

  /// Becomes ready with [ch] (default: a [resettable] channel).
  void succeed([ScriptedChannel? ch]) =>
      _channel.complete(channel = ch ?? resettable());

  /// Fails with [error].
  void fail(Object error) => _channel.completeError(error);

  Future<MontyChannel> _run(Future<void> cancel) {
    unawaited(cancel.then((_) => cancelled = true));

    return _channel.future;
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

  /// The channel of start [i].
  ScriptedChannel channel(int i) => all[i].channel!;

  SpawnHandle open() {
    final start = FakeStart();
    all.add(start);
    if (auto) start.succeed();

    return PendingSpawn(start._run);
  }
}

/// Lets pending microtasks and zero timers run.
Future<void> pump() => Future<void>.delayed(Duration.zero);

void main() {
  late FakeStarts starts;

  Future<WorkerPool> pool({
    int min = 1,
    int max = 2,
    Duration? checkoutTimeout,
    Duration? requestTimeout,
    int? maxCheckoutsPerWorker,
    Duration startupTimeout = WorkerPool.defaultStartupTimeout,
  }) async {
    final p = await WorkerPool.start(
      minProcesses: min,
      maxProcesses: max,
      checkoutTimeout: checkoutTimeout,
      requestTimeout: requestTimeout,
      maxCheckoutsPerWorker: maxCheckoutsPerWorker,
      startupTimeout: startupTimeout,
      open: starts.open,
    );
    addTearDown(p.close);

    return p;
  }

  setUp(() => starts = FakeStarts());

  group('start', () {
    test('spawns minProcesses, all idle', () async {
      final p = await pool(min: 2, max: 3);
      expect(starts.all, hasLength(2));
      expect(p.idleWorkers, 2);
      expect(p.liveWorkers, 2);
    });

    test('rejects an impossible size', () {
      for (final (min, max) in [(3, 2), (0, 0), (-1, 2)]) {
        expect(
          () => WorkerPool.start(
            minProcesses: min,
            maxProcesses: max,
            open: starts.open,
          ),
          throwsArgumentError,
          reason: 'min $min, max $max',
        );
      }
      expect(
        () => WorkerPool.start(maxCheckoutsPerWorker: 0, open: starts.open),
        throwsArgumentError,
      );
      expect(starts.all, isEmpty);
    });

    test('fails fast: cancels the starting, closes the ready', () async {
      starts = FakeStarts(auto: false);
      final started = WorkerPool.start(
        minProcesses: 3,
        maxProcesses: 3,
        open: starts.open,
      );
      starts.all[0].succeed();
      await pump();
      starts.all[1].fail(StateError('no worker here'));
      await expectLater(started, throwsA(isA<StateError>()));
      await pump();
      expect(starts.channel(0).closes, 1, reason: 'the ready one');
      expect(starts.channel(0).kills, 0, reason: 'closed, not killed');
      expect(starts.all[2].cancelled, isTrue, reason: 'the starting one');
      // It arrives anyway: it is killed, not leaked.
      starts.all[2].succeed();
      await pump();
      expect(starts.channel(2).kills, 1);
      expect(starts.channel(2).isAlive, isFalse);
    });

    test('a worker that never becomes ready fails it', () async {
      starts = FakeStarts(auto: false);
      await expectLater(
        WorkerPool.start(
          startupTimeout: const Duration(milliseconds: 50),
          open: starts.open,
        ),
        throwsA(
          isA<MontyCrashedError>().having(
            (e) => e.cause,
            'cause',
            CrashCause.killed,
          ),
        ),
      );
      await pump();
      expect(starts.all.single.cancelled, isTrue);
    });
  });

  group('acquire', () {
    test('reuses the idle worker, then spawns up to max', () async {
      final p = await pool();
      final a = await p.acquire();
      expect(a.workerId, 1);
      expect(starts.all, hasLength(1), reason: 'the idle one was reused');
      final b = await p.acquire();
      expect(b.workerId, 2);
      expect(p.liveWorkers, 2);
      expect(p.idleWorkers, 0);
      await a.release();
      expect(p.idleWorkers, 1);
      final c = await p.acquire();
      expect(c.workerId, 1, reason: 'released, reset, reused');
      expect(
        starts.channel(0).requests.map((r) => r.whichKind()),
        [pb.ParentRequest_Kind.reset],
      );
      await b.release();
      await c.release();
    });

    test('waits for a release at max, and gets that worker', () async {
      final p = await pool(max: 1);
      final a = await p.acquire();
      var got = false;
      final waiting = p.acquire()..then((_) => got = true).ignore();
      await pump();
      expect(got, isFalse);
      await a.release();
      final b = await waiting;
      expect(b.workerId, a.workerId);
      expect(starts.all, hasLength(1));
      await b.release();
    });

    test('times out after checkoutTimeout, then still serves', () async {
      final p = await pool(
        max: 1,
        checkoutTimeout: const Duration(milliseconds: 50),
      );
      final a = await p.acquire();
      final clock = Stopwatch()..start();
      await expectLater(p.acquire(), throwsA(isA<TimeoutException>()));
      expect(
        clock.elapsedMilliseconds,
        greaterThanOrEqualTo(40),
      );
      expect(p.liveWorkers, 1);
      // The timed-out waiter left no stale entry to swallow the wake-up.
      final waiting = p.acquire();
      await a.release();
      final b = await waiting;
      expect(b.workerId, a.workerId);
      await b.release();
    });

    test('a slot freed by a kill wakes a waiter, which spawns', () async {
      final p = await pool(max: 1);
      final a = await p.acquire();
      final waiting = p.acquire();
      a.kill();
      final b = await waiting;
      expect(b.workerId, 2);
      expect(p.liveWorkers, 1);
      await b.release();
    });

    test('discards a worker that died while idle', () async {
      final p = await pool(max: 1);
      starts.channel(0).kill();
      final a = await p.acquire();
      expect(a.workerId, 2);
      expect(starts.all, hasLength(2));
      expect(p.liveWorkers, 1);
      await a.release();
    });

    test('a failed start gives its slot back', () async {
      starts = FakeStarts(auto: false);
      final p = await pool(min: 0, max: 1);
      final first = p.acquire();
      starts.all[0].fail(StateError('no worker here'));
      await expectLater(first, throwsA(isA<StateError>()));
      expect(p.liveWorkers, 0);
      final second = p.acquire();
      starts.all[1].succeed();
      final lease = await second;
      expect(p.liveWorkers, 1);
      await lease.release();
    });

    test('a worker that never becomes ready is cancelled and its slot '
        'given back', () async {
      starts = FakeStarts(auto: false);
      final p = await pool(
        min: 0,
        max: 1,
        startupTimeout: const Duration(milliseconds: 50),
      );
      await expectLater(
        p.acquire(),
        throwsA(
          isA<MontyCrashedError>().having(
            (e) => e.cause,
            'cause',
            CrashCause.killed,
          ),
        ),
      );
      await pump();
      expect(starts.all.single.cancelled, isTrue);
      expect(p.liveWorkers, 0);
      // It greets at last: killed on arrival.
      starts.all.single.succeed();
      await pump();
      expect(starts.channel(0).kills, 1);
    });
  });

  group('release', () {
    test('retires a worker after maxCheckoutsPerWorker', () async {
      final p = await pool(max: 1, maxCheckoutsPerWorker: 2);
      for (var i = 0; i < 2; i++) {
        final lease = await p.acquire();
        expect(lease.workerId, 1);
        await lease.release();
      }
      expect(starts.channel(0).kills, 1);
      expect(p.liveWorkers, 0);
      final next = await p.acquire();
      expect(next.workerId, 2);
      await next.release();
    });

    test('a Reset that fails kills the worker and rethrows', () async {
      starts = FakeStarts(auto: false);
      final p = await pool(min: 0, max: 1);
      final acquired = p.acquire();
      starts.all.single.succeed(
        ScriptedChannel([
          answer([raised('X')]),
        ]),
      );
      final lease = await acquired;
      await expectLater(lease.release(), throwsA(isA<StateError>()));
      expect(starts.channel(0).kills, 1);
      expect(p.liveWorkers, 0);
      expect(lease.isReleased, isTrue);
    });

    test('a Reset over requestTimeout kills the worker', () async {
      starts = FakeStarts(auto: false);
      final p = await pool(
        min: 0,
        max: 1,
        requestTimeout: const Duration(milliseconds: 50),
      );
      final acquired = p.acquire();
      starts.all.single.succeed(ScriptedChannel([hangAfter([])]));
      final lease = await acquired;
      await expectLater(lease.release(), throwsA(isA<MontyCrashedError>()));
      expect(p.liveWorkers, 0);
    });
  });

  group('one lease, one release', () {
    test('release twice: one Reset, one slot back', () async {
      final p = await pool(max: 1);
      final lease = await p.acquire();
      final first = lease.release();
      final second = lease.release();
      await Future.wait([first, second]);
      await lease.release();
      expect(starts.channel(0).requests, hasLength(1));
      expect(p.liveWorkers, 1);
      expect(p.idleWorkers, 1);
    });

    test('kill twice, then release: one slot back', () async {
      final p = await pool();
      final a = await p.acquire();
      final b = await p.acquire();
      a
        ..kill()
        ..kill();
      await a.release();
      expect(p.liveWorkers, 1);
      expect(starts.channel(0).kills, 1);
      expect(starts.channel(0).requests, isEmpty);
      await b.release();
    });

    test('release, then kill: the kill does nothing', () async {
      final p = await pool(max: 1);
      final lease = await p.acquire();
      final channel = lease.channel;
      await lease.release();
      expect(() => lease.channel, throwsStateError);
      lease.kill();
      expect(channel, same(starts.channel(0)));
      expect(starts.channel(0).kills, 0);
      expect(p.idleWorkers, 1);
      expect(p.liveWorkers, 1);
    });

    test('a kill during the Reset wins, once', () async {
      starts = FakeStarts(auto: false);
      final p = await pool(min: 0, max: 1);
      final acquired = p.acquire();
      starts.all.single.succeed(ScriptedChannel([hangAfter([])]));
      final lease = await acquired;
      final releasing = lease.release();
      await pump();
      lease.kill();
      await releasing;
      expect(lease.isReleased, isTrue);
      expect(p.liveWorkers, 0);
      expect(starts.channel(0).kills, 1);
    });
  });

  group('close', () {
    test('reaps idle workers and refuses checkouts', () async {
      final p = await pool(min: 2);
      final held = await p.acquire();
      final heldChannel = starts.channel(held.workerId - 1);
      final idleChannel = starts.channel(2 - held.workerId);
      await p.close();
      await expectLater(p.acquire(), throwsA(isA<StateError>()));
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
      final p = await pool(max: 1);
      final held = await p.acquire();
      final waiting = expectLater(p.acquire(), throwsA(isA<StateError>()));
      await pump();
      await p.close();
      await waiting;
      held.kill();
      expect(p.liveWorkers, 0);
    });

    test('cancels a worker still starting', () async {
      starts = FakeStarts(auto: false);
      final p = await pool(min: 0, max: 1);
      final acquired = expectLater(p.acquire(), throwsA(isA<StateError>()));
      await pump();
      await p.close();
      await acquired;
      await pump();
      expect(starts.all.single.cancelled, isTrue);
      expect(p.liveWorkers, 0);
      starts.all.single.succeed();
      await pump();
      expect(starts.channel(0).kills, 1, reason: 'killed on arrival');
    });

    test('is idempotent', () async {
      final p = await pool(max: 1);
      await Future.wait([p.close(), p.close()]);
      await p.close();
      expect(starts.channel(0).closes, 1);
      expect(p.isClosed, isTrue);
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
      failing.completeError(StateError('late'));
      await expectLater(handle.ready, throwsA(isA<MontyCrashedError>()));
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
      expect(
        await resolveAssetBase((_) async => true),
        flutterAssetBase,
      );
      expect(
        workerWasmUrl('b'),
        'b/dart_monty_core_proto_worker.wasm',
      );
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
