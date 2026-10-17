// Pool capacity and ownership contracts from behaviour/pool-and-lifetimes.md.
import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/channel_factory.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_pool_support.dart';
import '_scripted_channel.dart';

const _thirtySeconds = Duration(seconds: 30);
final Matcher _startupCrash = throwsA(
  isA<MontyCrashedError>()
      .having(
        (e) => e.toString(),
        'description',
        'the worker was not ready within 0:00:30.000000',
      )
      .having((e) => e.timedOut, 'timedOut', isFalse)
      .having((e) => e.exitStatus, 'exitStatus', isNull),
);

Future<void> _startup() async {
  final timers = PoolTimers();
  await timers.run(() async {
    final arrival = Completer<MontyChannel>();
    final late = ScriptedChannel([]);
    final ready = ScriptedChannel([configurePool, resetPool]);
    var starts = 0;
    var cancelled = false;
    final pool = await startMonty(
      const PoolOptions(minProcesses: 0, maxProcesses: 1),
      open: () => PendingSpawn((cancel) {
        if (starts++ != 0) return Future.value(ready);
        unawaited(_after(cancel, () => cancelled = true));

        return arrival.future;
      }),
    );
    addTearDown(pool.close);
    final failed = expectLater(pool.checkout(), _startupCrash);
    await pumpEventQueue();
    expect(timers.active, [_thirtySeconds]);
    expect(pool.liveWorkers, 1);
    timers.fire();
    await failed;
    expect(cancelled, isTrue);
    expect(pool.liveWorkers, 0);
    arrival.complete(late);
    await pumpEventQueue();
    expect(late.kills, 1);
    final session = await pool.checkout();
    expect(pool.liveWorkers, 1);
    await session.close();
  });
}

Future<void> _startingCapacity() async {
  final arrival = Completer<MontyChannel>();
  final channel = ScriptedChannel([
    configurePool,
    resetPool,
    configurePool,
    resetPool,
  ]);
  var starts = 0;
  final pool = await startMonty(
    const PoolOptions(minProcesses: 0, maxProcesses: 1),
    open: () {
      starts++;

      return PendingSpawn((_) => arrival.future);
    },
  );
  addTearDown(pool.close);
  final first = pool.checkout();
  var secondFinished = false;
  final second = _after(pool.checkout(), () => secondFinished = true);
  await pumpEventQueue();
  expect(starts, 1);
  expect(pool.liveWorkers, 1);
  expect(secondFinished, isFalse);
  arrival.complete(channel);
  final held = await first;
  await pumpEventQueue();
  expect(secondFinished, isFalse);
  await held.close();
  final next = await second;
  expect(starts, 1);
  expect(secondFinished, isTrue);
  await next.close();
  expect(pool.idleWorkers, 1);
}

Future<void> _nested(int max) async {
  final timers = PoolTimers();
  await timers.run(() async {
    final pool = await poolWith(
      [
        ScriptedChannel([configurePool, resetPool]),
        ScriptedChannel([configurePool, resetPool]),
      ],
      options: PoolOptions(
        minProcesses: 0,
        maxProcesses: max,
        checkoutTimeout: const Duration(seconds: 2),
      ),
    );
    await pool.withSession((outer) async {
      if (max == 2) {
        final inner = await pool.checkout();
        expect(pool.liveWorkers, 2);
        await inner.close();
      } else {
        final failed = expectLater(
          pool.checkout(),
          throwsA(
            isA<TimeoutException>().having(
              (e) => e.message,
              'message',
              'no monty worker became available within the checkout timeout',
            ),
          ),
        );
        await pumpEventQueue();
        expect(pool.liveWorkers, 1);
        timers.fire();
        await failed;
      }
    });
  });
}

Future<void> _combinedCapacity() async {
  final starting = Completer<MontyChannel>();
  final idle = ScriptedChannel([
    for (var i = 0; i < 3; i++) ...[configurePool, resetPool],
  ]);
  final held = ScriptedChannel([configurePool, resetPool]);
  final late = ScriptedChannel([configurePool, resetPool]);
  var starts = 0;
  final pool = await startMonty(
    const PoolOptions(minProcesses: 2, maxProcesses: 3),
    open: () => PendingSpawn(
      (_) => switch (starts++) {
        0 => Future.value(held),
        1 => Future.value(idle),
        _ => starting.future,
      },
    ),
  );
  addTearDown(pool.close);
  final first = await pool.checkout(scriptName: 'first');
  final second = await pool.checkout(scriptName: 'second');
  final third = pool.checkout(scriptName: 'third');
  await first.close();
  expect(pool.idleWorkers, 1);
  expect(pool.liveWorkers, 3, reason: 'one idle, one held, one starting');
  final fourth = await pool.checkout(scriptName: 'fourth');
  var acquired = false;
  final fifth = _after(
    pool.checkout(scriptName: 'fifth'),
    () => acquired = true,
  );
  await pumpEventQueue();
  expect(starts, 3);
  expect(acquired, isFalse);
  await fourth.close();
  final last = await fifth;
  expect(starts, 3, reason: 'the idle worker supplies the waiting checkout');
  starting.complete(late);
  await (await third).close();
  await second.close();
  await last.close();
  expect(pool.idleWorkers, 3);
}

void main() {
  test(
    'idle held and starting workers share the cap',
    _combinedCapacity,
  );
  test('readiness expires at thirty seconds and frees capacity', _startup);
  test('a starting worker reserves the only slot', _startingCapacity);
  test(
    'nested checkout needs spare capacity',
    () async {
      await _nested(1);
      await _nested(2);
    },
  );
  test(
    'Future.timeout leaves acquisition running',
    () async {
      final timers = PoolTimers();
      await timers.run(() async {
        final pool = await poolWith([
          ScriptedChannel([
            configurePool,
            resetPool,
            configurePool,
            resetPool,
          ]),
        ]);
        final held = await pool.checkout();
        final acquisition = pool.checkout();
        final failed = expectLater(
          acquisition.timeout(const Duration(seconds: 3)),
          throwsA(isA<TimeoutException>()),
        );
        await pumpEventQueue();
        timers.fire();
        await failed;
        await held.close();
        // Keep the original future solely to clean up the otherwise unclaimed
        // session. The caller of timeout has already received its failure.
        final late = await acquisition;
        expect(pool.liveWorkers, 1);
        expect(pool.idleWorkers, 0);
        await late.close();
        expect(pool.idleWorkers, 1);
      });
    },
  );
  test(
    'successful withPool body is awaited and closed',
    () async {
      final body = Completer<int>();
      final entered = Completer<Monty>();
      var completed = false;
      final result = _after(
        Monty.withPool((pool) {
          entered.complete(pool);

          return body.future;
        }, minProcesses: 0),
        () => completed = true,
      );
      final pool = await entered.future;
      await pumpEventQueue();
      expect(completed, isFalse);
      body.complete(42);
      expect(await result, 42);
      await expectLater(pool.checkout(), throwsStateError);
    },
  );
  test(
    'withPool awaits its body and closes after success or failure',
    () async {
      final entered = Completer<Monty>();
      final body = Completer<int>();
      var settled = false;
      final successful = _after(
        Monty.withPool((pool) async {
          final session = await pool.checkout();
          await session.close();
          entered.complete(pool);

          return body.future;
        }, minProcesses: 0),
        () => settled = true,
      );
      final first = await entered.future;
      await pumpEventQueue();
      expect(settled, isFalse);
      final stillOpen = await first.checkout();
      await stillOpen.close();
      body.complete(42);
      expect(await successful, 42);
      await expectLater(first.checkout(), throwsStateError);

      final failed = Completer<Monty>();
      final failedBody = Completer<void>();
      final failure = Monty.withPool<void>((pool) async {
        final session = await pool.checkout();
        await session.close();
        failed.complete(pool);
        await failedBody.future;
        throw StateError('body failed');
      }, minProcesses: 0);
      final closedAfterFailure = await failed.future;
      final openUntilFailure = await closedAfterFailure.checkout();
      await openUntilFailure.close();
      failedBody.complete();
      await expectLater(
        failure,
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'body failed'),
        ),
      );
      await expectLater(closedAfterFailure.checkout(), throwsStateError);
    },
  );
  test('a checkout without a timeout waits for a released session', () async {
    final timers = PoolTimers();
    await timers.run(() async {
      final channel = ScriptedChannel([
        configurePool,
        resetPool,
        configurePool,
        resetPool,
      ]);
      final pool = await poolWith([channel]);
      final first = await pool.checkout();
      var completed = false;
      Future<MontySession> observe(Future<MontySession> checkout) async {
        final session = await checkout;
        completed = true;

        return session;
      }

      final waitingCheckout = pool.checkout();
      final waiting = observe(waitingCheckout);
      await pumpEventQueue();
      expect(timers.active, isEmpty);
      expect(completed, isFalse);
      await first.close();
      final next = await waiting;
      expect(completed, isTrue);
      await next.close();
    });
  });
  test(
    'null maximum is resolved before spawning',
    () async {
      final min = defaultMaxProcesses() + 1;
      var starts = 0;
      await expectLater(
        WorkerPool.start(
          PoolOptions(minProcesses: min),
          () {
            starts++;

            return PendingSpawn((_) async => ScriptedChannel([]));
          },
        ),
        throwsArgumentError,
      );
      expect(starts, 0);
      await expectLater(Monty.start(minProcesses: min), throwsArgumentError);
      await expectLater(
        Monty.withPool((_) async => 0, minProcesses: min),
        throwsArgumentError,
      );
    },
  );
  test('invalid public pool sizes fail before a worker starts', () async {
    final defaultMaximum = defaultMaxProcesses();
    final sizes = [
      (min: -1, max: 1),
      (min: 0, max: 0),
      (min: 2, max: 1),
      (min: defaultMaximum + 1, max: null),
    ];
    for (final size in sizes) {
      var starts = 0;
      await expectLater(
        WorkerPool.start(
          PoolOptions(minProcesses: size.min, maxProcesses: size.max),
          () {
            starts++;

            return PendingSpawn((_) async => ScriptedChannel([]));
          },
        ),
        throwsArgumentError,
        reason: '$size WorkerPool.start',
      );
      expect(starts, 0, reason: '$size WorkerPool.start');
      await expectLater(
        Monty.start(minProcesses: size.min, maxProcesses: size.max),
        throwsArgumentError,
        reason: '$size Monty.start',
      );
      await expectLater(
        Monty.withPool<void>(
          (_) async => throw StateError('a worker was opened'),
          minProcesses: size.min,
          maxProcesses: size.max,
        ),
        throwsArgumentError,
        reason: '$size Monty.withPool',
      );
    }
  });
  test('negative public timeouts reject before entering a pool body', () async {
    const negative = Duration(microseconds: -1);
    final starts = {
      'checkout timeout': () => Monty.start(
        checkoutTimeout: negative,
        workerLocation: '/worker-must-not-start',
      ),
      'request timeout': () => Monty.start(
        requestTimeout: negative,
        workerLocation: '/worker-must-not-start',
      ),
      'feed duration grace': () => Monty.start(
        feedDurationLimitGrace: negative,
        workerLocation: '/worker-must-not-start',
      ),
      'turn duration grace': () => Monty.start(
        turnDurationLimitGrace: negative,
        workerLocation: '/worker-must-not-start',
      ),
    };
    for (final entry in starts.entries) {
      var entered = false;
      Future<void> body(Monty _) {
        entered = true;

        return Future.value();
      }

      await expectLater(entry.value(), throwsArgumentError, reason: entry.key);
      await expectLater(
        switch (entry.key) {
          'checkout timeout' => Monty.withPool<void>(
            body,
            checkoutTimeout: negative,
            workerLocation: '/worker-must-not-start',
          ),
          'request timeout' => Monty.withPool<void>(
            body,
            requestTimeout: negative,
            workerLocation: '/worker-must-not-start',
          ),
          'feed duration grace' => Monty.withPool<void>(
            body,
            feedDurationLimitGrace: negative,
            workerLocation: '/worker-must-not-start',
          ),
          'turn duration grace' => Monty.withPool<void>(
            body,
            turnDurationLimitGrace: negative,
            workerLocation: '/worker-must-not-start',
          ),
          _ => throw StateError('unknown timeout'),
        },
        throwsArgumentError,
        reason: entry.key,
      );
      expect(entered, isFalse, reason: entry.key);
    }
  });
  test(
    'null bounds retain the platform cap and reuse',
    () async {
      final timers = PoolTimers();
      await timers.run(() async {
        final channel = ScriptedChannel([
          for (var i = 0; i < 4; i++) ...[configurePool, resetPool],
        ]);
        final pool = await WorkerPool.start(
          const PoolOptions(minProcesses: 0),
          () => PendingSpawn((_) async => channel),
        );
        addTearDown(pool.close);
        expect(pool.maxProcesses, defaultMaxProcesses());
        final sessions = await poolWith([channel]);
        for (var i = 0; i < 4; i++) {
          final session = await sessions.checkout();
          expect(timers.active, isEmpty);
          await session.close();
          expect(channel.kills, 0);
          expect(sessions.idleWorkers, 1);
        }
      });
    },
  );
}

Future<T> _after<T>(Future<T> work, void Function() completed) async {
  final result = await work;
  completed();

  return result;
}
