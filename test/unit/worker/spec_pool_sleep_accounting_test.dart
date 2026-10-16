// Exact checkout-wide charges from behaviour/budgets-and-limits.md.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_pool_b2_support.dart';
import '_spec_pool_support.dart';

Future<void> _capped(double seconds) async {
  final (session, _) = await poolB2Session(
    [
      answer([poolB2Sleep(seconds)]),
      answer([completeNone()]),
      answer([poolB2Sleep(0.001)]),
      poolB2Abort,
    ],
    config: const SessionConfig(
      osPolicy: OsPolicy(sleepSystemMax: Duration(milliseconds: 20)),
      limits: ResourceLimits(maxTotalSleep: Duration(milliseconds: 20)),
    ),
  );
  final snapshot = await session.feedStart('sleep') as FunctionSnapshot;
  await snapshot.resume(poolB2Answer);
  await expectLater(
    session.feedStart('sleep'),
    throwsA(runtimePool('TimeoutError', 'sleep limit exceeded: 21ms > 20ms')),
  );
}

Future<void> _restoreCap(bool snapshot) async {
  final sleepEvent = poolB2Sleep(50);
  final (session, _) = await poolB2Session(
    [
      answer([if (snapshot) sleepEvent else ok()]),
      if (!snapshot) answer([sleepEvent]),
      answer([completeNone()]),
      answer([poolB2Sleep(0.001)]),
      poolB2Abort,
    ],
    config: const SessionConfig(
      osPolicy: OsPolicy(sleepSystemMax: Duration(milliseconds: 20)),
      limits: ResourceLimits(maxTotalSleep: Duration(milliseconds: 20)),
    ),
  );
  final bytes = Uint8List.fromList([1]);
  final FunctionSnapshot sleep;
  if (snapshot) {
    sleep = await session.loadSnapshot(bytes) as FunctionSnapshot;
  } else {
    await session.loadSession(bytes);
    sleep = await session.feedStart('sleep') as FunctionSnapshot;
  }
  await sleep.resume(poolB2Answer);
  await expectLater(
    session.feedStart('sleep'),
    throwsA(runtimePool('TimeoutError', 'sleep limit exceeded: 21ms > 20ms')),
  );
}

Future<void> _refusedWithoutTimer() async {
  final timers = PoolTimers();
  await timers.run(() async {
    final (session, channel) = await poolB2Session(
      [
        answer([poolB2Sleep(5)]),
        poolB2Abort,
        answer([poolB2Sleep(0.25)]),
        answer([completeNone()]),
        answer([poolB2Sleep(0.001)]),
        poolB2Abort,
      ],
      config: const SessionConfig(
        limits: ResourceLimits(maxTotalSleep: Duration(milliseconds: 250)),
      ),
    );
    final failed = expectLater(
      session.feedRun('sleep'),
      throwsA(runtimePool('TimeoutError', 'sleep limit exceeded: 5s > 250ms')),
    );
    // Pumping lets a wrongly installed sleep timer become observable without
    // waiting for it; the assertion fails instead of hanging for five seconds.
    await pumpEventQueue();
    expect(timers.active, isEmpty);
    await failed;
    expect(channel.requests, hasLength(3));
    final sleep = await session.feedStart('sleep') as FunctionSnapshot;
    await sleep.resume(poolB2Answer);
    await expectLater(
      session.feedStart('sleep'),
      throwsA(
        runtimePool('TimeoutError', 'sleep limit exceeded: 251ms > 250ms'),
      ),
    );
  });
}

Future<void> _overlapping() async {
  final timers = PoolTimers();
  await timers.run(() async {
    final second = poolB2Sleep(0.08, asynchronous: true)..osCall.callId = 2;
    final (session, _) = await poolB2Session(
      [
        answer([poolB2Sleep(0.08, asynchronous: true)]),
        answer([second]),
        answer([
          poolB2Futures([1, 2]),
        ]),
        answer([completeNone()]),
        answer([poolB2Sleep(0.001)]),
        poolB2Abort,
      ],
      config: const SessionConfig(
        limits: ResourceLimits(maxTotalSleep: Duration(milliseconds: 160)),
      ),
    );
    final running = session.feedRun('gather');
    await pumpEventQueue();
    expect(timers.active, [
      const Duration(milliseconds: 80),
      const Duration(milliseconds: 80),
    ]);
    for (final timer
        in timers.timers.where((candidate) => candidate.isActive).toList()) {
      timer.fire();
    }
    expect(await running, const MontyNone());
    await expectLater(
      session.feedStart('sleep'),
      throwsA(
        runtimePool('TimeoutError', 'sleep limit exceeded: 161ms > 160ms'),
      ),
    );
  });
}

void main() {
  for (final (label, seconds) in [
    ('negative', -1.0),
    ('NaN', double.nan),
    ('out of range', 1e30),
  ]) {
    test(
      'REQ-budgets-and-limits-40: $label charges the full ceiling',
      () => _capped(seconds),
    );
  }
  for (final snapshot in [false, true]) {
    test(
      'REQ-budgets-and-limits-35: restore retains parent sleep cap ($snapshot)',
      () => _restoreCap(snapshot),
    );
  }
  test(
    'REQ-budgets-and-limits-39: overlapping sleeps each charge their full '
    'delay',
    _overlapping,
  );
  test(
    'REQ-budgets-and-limits-42: refused sleep installs no timer and '
    'retains accepted total',
    _refusedWithoutTimer,
  );
  test(
    'REQ-budgets-and-limits-41: cumulative sleep saturates before comparison',
    () async {
      final hugeSleep = poolB2Sleep((BigInt.one << 63).toDouble());
      final last = poolB2Sleep(1)..maxTotalSleepMicros = Int64(1);
      final (session, _) = await poolB2Session(
        [
          answer([hugeSleep]),
          answer([hugeSleep]),
          answer([last]),
          poolB2Abort,
        ],
        config: const SessionConfig(
          osPolicy: OsPolicy(
            sleepSystemMax: Duration(microseconds: 9007199254740991),
          ),
        ),
      );
      final first = await session.feedStart('sleep') as FunctionSnapshot;
      final second = await first.resume(poolB2Answer) as FunctionSnapshot;
      await expectLater(
        second.resume(poolB2Answer),
        throwsA(
          runtimePool(
            'TimeoutError',
            'sleep limit exceeded: 18446744073709551615.999999999s > 1µs',
          ),
        ),
      );
    },
  );
  test(
    'REQ-budgets-and-limits-28: partial future waits count across feeds',
    () async {
      final (session, _) = await poolB2Session(
        [
          answer([poolCall()]),
          answer([completeNone()]),
          answer([
            poolB2Futures([1, 2]),
          ]),
          answer([
            poolB2Futures([2]),
          ]),
          poolB2Abort,
        ],
        config: const SessionConfig(limits: ResourceLimits(maxSuspensions: 2)),
      );
      final call = await session.feedStart('f()') as FunctionSnapshot;
      await call.resume(poolB2Answer);
      final futures = await session.feedStart('gather') as FutureSnapshot;
      await expectLater(
        futures.resume({1: poolB2Answer}),
        throwsA(runtimePool('RuntimeError', 'suspension limit 2 exceeded')),
      );
    },
  );
  test(
    'REQ-budgets-and-limits-56: aborted restored suspension keeps adopted '
    'budget',
    () async {
      final restored = poolCall()..maxSuspensions = Int64.ZERO;
      final (session, _) = await poolB2Session(
        [
          answer([restored]),
          poolB2Abort,
          answer([poolCall()]),
          poolB2Abort,
        ],
        config: const SessionConfig(limits: ResourceLimits(maxSuspensions: 5)),
      );
      final exceeded = throwsA(
        runtimePool('RuntimeError', 'suspension limit 0 exceeded'),
      );
      await expectLater(
        session.loadSnapshot(Uint8List.fromList([1])),
        exceeded,
      );
      await expectLater(session.feedStart('f()'), exceeded);
    },
  );
}
