// Remaining session boundaries from Monty.md and session-turns.md.
import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_pool_b2_support.dart';
import '_spec_pool_support.dart';

const _negative = Duration(microseconds: -1);
final _invalid = {
  'format': const SessionConfig(typeCheckFormat: 'unknown'),
  'memory': const SessionConfig(limits: ResourceLimits(maxMemory: -1)),
  'gc': const SessionConfig(limits: ResourceLimits(gcInterval: -1)),
  'recursion': const SessionConfig(
    limits: ResourceLimits(maxRecursionDepth: -1),
  ),
  'suspensions': const SessionConfig(
    limits: ResourceLimits(maxSuspensions: -1),
  ),
  'feed duration': const SessionConfig(
    limits: ResourceLimits(maxFeedDuration: _negative),
  ),
  'turn duration': const SessionConfig(
    limits: ResourceLimits(maxTurnDuration: _negative),
  ),
  'sleep duration': const SessionConfig(
    limits: ResourceLimits(maxTotalSleep: _negative),
  ),
  'flush interval': const SessionConfig(printFlushInterval: _negative),
  'negative annotations': const SessionConfig(assertMessageAnnotations: -1),
  'large annotations': const SessionConfig(
    assertMessageAnnotations: 4294967296,
  ),
};

Future<void> _invalidCheckout(SessionConfig config) async {
  final channel = ScriptedChannel([configurePool, resetPool]);
  final pool = await poolWith([channel]);
  final held = await pool.checkout();
  addTearDown(held.close);
  var rejected = false;
  Future<void> check() async {
    await expectLater(pool.checkoutWith(config), throwsArgumentError);
    rejected = true;
  }

  final checking = check();
  await pumpEventQueue();
  expect(
    rejected,
    isTrue,
    reason: 'validation must finish while capacity is held',
  );
  await checking;
  expect(channel.requests, hasLength(1));
  expect(pool.liveWorkers, 1);
  expect(pool.idleWorkers, 0);
}

Future<void> _waiter(MontySession session, int id, List<int> order) async {
  await expectLater(session.feedRun('queued'), finishedPool);
  order.add(id);
}

Future<void> _fifo(bool close) async {
  final channel = HeldPoolChannel();
  final pool = await poolWith([channel]);
  final session = await pool.checkout();
  final failed = expectLater(
    session.feedRun('held'),
    throwsA(isA<MontyCrashedError>()),
  );
  await channel.entered.future;
  final order = <int>[];
  final waiting = [for (var i = 0; i < 4; i++) _waiter(session, i, order)];
  await pumpEventQueue();
  expect(order, isEmpty);
  if (close) {
    await session.close();
    channel.reply.complete(completeNone());
  } else {
    channel.reply.complete(fatal('worker failed'));
  }
  await failed;
  await Future.wait(waiting);
  expect(order, [0, 1, 2, 3]);
  expect(channel.requests, [
    pb.ParentRequest_Kind.configure,
    pb.ParentRequest_Kind.feed,
  ]);
  expect(pool.liveWorkers, 0);
}

Future<void> _sleep() async {
  final timers = PoolTimers();
  await timers.run(() async {
    final (session, channel) = await poolB2Session(
      [
        answer([poolB2Sleep(5)]),
        answer([completeNone()]),
      ],
      config: const SessionConfig(
        limits: ResourceLimits(
          maxFeedDuration: Duration(seconds: 1),
          maxTurnDuration: Duration(seconds: 1),
        ),
      ),
      options: const PoolOptions(
        minProcesses: 0,
        maxProcesses: 1,
        requestTimeout: Duration(seconds: 2),
        feedDurationLimitGrace: Duration.zero,
        turnDurationLimitGrace: Duration.zero,
      ),
    );
    final running = session.feedRun('sleep');
    await pumpEventQueue();
    expect(timers.active, [
      const Duration(seconds: 5),
    ], reason: 'only the sleep runs between execution turns');
    timers.fire();
    expect(await running, const MontyNone());
    expect(channel.kills, 0);
  });
}

void main() {
  for (final MapEntry(:key, :value) in _invalid.entries) {
    test(
      'REQ-Monty-35: $key is refused before waiting on exhausted capacity',
      () => _invalidCheckout(value),
    );
  }
  for (final close in [false, true]) {
    test(
      'REQ-session-turns-3: terminal waiters fail in FIFO order (close=$close)',
      () => _fifo(close),
    );
  }
  test('REQ-os-calls-20: system wait has no execution deadline', _sleep);
  test(
    'REQ-snapshots-and-futures-61: closed pool kills idle snapshot '
    'without Reset',
    () async {
      final channel = ScriptedChannel([
        configurePool,
        answer([poolCall()]),
      ]);
      final pool = await poolWith([channel]);
      final session = await pool.checkout();
      final snapshot = await session.feedStart('f()') as FunctionSnapshot;
      await pool.close();
      expect(channel.kills, 0);
      await session.close();
      expect(channel.kills, 1);
      expect(pool.liveWorkers, 0);
      expect(channel.requests.map((r) => r.whichKind()), [
        pb.ParentRequest_Kind.configure,
        pb.ParentRequest_Kind.feed,
      ]);
      await expectLater(snapshot.resume(poolB2Answer), finishedPool);
    },
  );
}
