// Budget deadlines are observed as scheduled timers, never wall-clock sleeps.
import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_pool_b2_support.dart';
import '_spec_pool_support.dart';

final Matcher _timeout = throwsA(
  isA<MontyCrashedError>().having((e) => e.timedOut, 'timedOut', isTrue),
);

Future<void> _backstop({
  bool turn = false,
  int used = 0,
  bool restore = false,
}) async {
  final timers = PoolTimers();
  await timers.run(() async {
    final event = poolCall()..feedExecutionMicros = Int64(used);
    if (restore) {
      event
        ..maxFeedDurationMicros = Int64(10000000)
        ..maxTurnDurationMicros = Int64(4000000);
    }
    final (session, _) = await poolB2Session(
      [
        answer([event]),
        hangAfter([]),
      ],
      config: SessionConfig(
        limits: ResourceLimits(
          maxFeedDuration: Duration(seconds: restore ? 99 : 10),
          maxTurnDuration: turn ? Duration(seconds: restore ? 99 : 4) : null,
        ),
      ),
      options: turn
          ? const PoolOptions(
              minProcesses: 0,
              maxProcesses: 1,
              feedDurationLimitGrace: null,
            )
          : const PoolOptions(
              minProcesses: 0,
              maxProcesses: 1,
              turnDurationLimitGrace: null,
            ),
    );
    final snapshot =
        (restore
                ? await session.loadSnapshot(Uint8List.fromList([1]))
                : await session.feedStart('f()'))
            as FunctionSnapshot;
    final failed = expectLater(snapshot.resume(poolB2Answer), _timeout);
    await pumpEventQueue();
    final expected = switch ((turn, used)) {
      (true, _) => 5,
      (false, >= 10000000) => 1,
      _ => 7,
    };
    expect(timers.active, [Duration(seconds: expected)]);
    timers.fire();
    await failed;
  });
}

Future<void> _ended(bool duration) async {
  final timers = PoolTimers();
  await timers.run(() async {
    final (session, channel) = await poolB2Session(
      [
        answer([poolCall()]),
        hangAfter([]),
      ],
      config: SessionConfig(
        limits: ResourceLimits(
          maxFeedDuration: duration ? const Duration(seconds: 1) : null,
        ),
      ),
      options: PoolOptions(
        minProcesses: 0,
        maxProcesses: 1,
        requestTimeout: duration ? null : const Duration(seconds: 2),
      ),
    );
    final snapshot = await session.feedStart('f()') as FunctionSnapshot;
    // Dump leaves the snapshot unspent, but a deadline ends its session.
    final failed = expectLater(
      duration ? snapshot.resume(poolB2Answer) : session.dump(),
      _timeout,
    );
    await pumpEventQueue();
    timers.fire();
    await failed;
    await expectLater(session.feedRun('1'), finishedPool);
    await expectLater(session.dump(), finishedPool);
    await expectLater(session.installDependencies([]), finishedPool);
    await expectLater(() => snapshot.resume(poolB2Answer), throwsStateError);
    await expectLater(snapshot.dump, throwsStateError);
    expect(channel.kills, 1);
  });
}

void main() {
  for (final turn in [false, true]) {
    test(
      'REQ-budgets-and-limits-45: default ${turn ? 'turn' : 'feed'} grace '
      'is one second',
      () => _backstop(turn: turn, used: 4000000),
    );
    test(
      'REQ-budgets-and-limits-52: restore preserves feed use and starts '
      'fresh turn ($turn)',
      () => _backstop(turn: turn, used: 4000000, restore: true),
    );
  }
  for (final used in [10000000, 12000000]) {
    test(
      'REQ-budgets-and-limits-46: exhausted feed use $used leaves only grace',
      () => _backstop(used: used),
    );
  }
  for (final duration in [false, true]) {
    test(
      'REQ-budgets-and-limits-72: operations after '
      '${duration ? 'duration' : 'request'} expiry fail',
      () => _ended(duration),
    );
  }
  test(
    'REQ-budgets-and-limits-48: omitted requestTimeout installs no turn '
    'deadline',
    () async {
      final timers = PoolTimers();
      await timers.run(() async {
        final channel = HeldPoolChannel();
        final pool = await poolWith([channel]);
        final session = await pool.checkout();
        final result = session.feedRun('None');
        await channel.entered.future;
        expect(timers.active, isEmpty);
        channel.reply.complete(completeNone());
        expect(await result, const MontyNone());
        await session.close();
      });
    },
  );
  test(
    'REQ-budgets-and-limits-49: OS callback is outside requestTimeout',
    () async {
      final timers = PoolTimers();
      await timers.run(() async {
        final entered = Completer<void>();
        final answerGate = Completer<MontyValue>();
        final (session, _) = await poolB2Session(
          [
            answer([poolOs()]),
            answer([completeNone()]),
          ],
          options: const PoolOptions(
            minProcesses: 0,
            maxProcesses: 1,
            requestTimeout: Duration(seconds: 1),
          ),
        );
        final result = session.feedRun(
          'read()',
          os: (_, _, _) {
            entered.complete();

            return answerGate.future;
          },
        );
        await entered.future;
        expect(timers.active, isEmpty);
        answerGate.complete(const MontyString('contents'));
        expect(await result, const MontyNone());
      });
    },
  );
  test(
    'REQ-platforms-11: null checkout timeout schedules no capacity deadline',
    () async {
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
        final waiting = pool.checkout();
        await pumpEventQueue();
        expect(timers.active, isEmpty);
        expect(pool.liveWorkers, 1);
        await first.close();
        final next = await waiting;
        expect(pool.liveWorkers, 1);
        await next.close();
      });
    },
  );
}
