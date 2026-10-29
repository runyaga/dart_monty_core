// Budget deadlines are observed as scheduled timers, never wall-clock sleeps.
//
// The ceilings a restore keeps or tightens are asserted where the budget
// itself is: session_budget_test.dart.
import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '_pool_protocol_support.dart';
import '_pool_support.dart';
import '_scripted_channel.dart';

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

/// The deadline a session arms once a load restored a dump: the load's
/// reply is [load], and the turn that follows it hangs, so the only
/// deadline is the one the restored budget backs. A [snapshot] load is
/// resumed, an idle one is fed.
Future<List<Duration>> _afterLoad({
  required bool snapshot,
  required pb.ChildEvent load,
  Duration parentFeed = const Duration(seconds: 99),
  int frameLimit = 268435456,
}) async {
  final timers = PoolTimers();
  final armed = <Duration>[];
  await timers.run(() async {
    final (session, _) = await poolB2Session(
      [
        answer([load]),
        hangAfter([]),
      ],
      config: SessionConfig(
        limits: ResourceLimits(maxFeedDuration: parentFeed),
      ),
      options: const PoolOptions(
        minProcesses: 0,
        maxProcesses: 1,
        turnDurationLimitGrace: null,
      ),
      frameLimit: frameLimit,
    );
    final Future<void> failed;
    if (snapshot) {
      final restored =
          await session.loadSnapshot(Uint8List.fromList([1]))
              as FunctionSnapshot;
      failed = expectLater(restored.resume(poolB2Answer), _timeout);
    } else {
      await session.loadSession(Uint8List.fromList([1]));
      failed = expectLater(session.feedRun('1'), _timeout);
    }
    await pumpEventQueue();
    armed.addAll(timers.active);
    timers.fire();
    await failed;
  });

  return armed;
}

void main() {
  for (final turn in [false, true]) {
    test(
      'default ${turn ? 'turn' : 'feed'} grace '
      'is one second',
      () => _backstop(turn: turn, used: 4000000),
    );
    test(
      'restore preserves feed use and starts '
      'fresh turn ($turn)',
      () => _backstop(turn: turn, used: 4000000, restore: true),
    );
  }
  for (final used in [10000000, 12000000]) {
    test(
      'exhausted feed use $used leaves only grace',
      () => _backstop(used: used),
    );
  }
  for (final duration in [false, true]) {
    test(
      'operations after '
      '${duration ? 'duration' : 'request'} expiry fail',
      () => _ended(duration),
    );
  }
  test(
    'omitted requestTimeout installs no turn '
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
    'OS callback is outside requestTimeout',
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
    'null checkout timeout schedules no capacity deadline',
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
  test(
    'a load that reports a smaller feed duration tightens the backstop',
    () async {
      // The session allows 99s; the dump it restores allows 4s, so the
      // backstop is the dump's 4s plus the grace.
      final armed = await _afterLoad(
        snapshot: false,
        load: pb.ChildEvent(
          ok: pb.Ok(),
          maxFeedDurationMicros: Int64(4000000),
        ),
      );
      expect(armed, [const Duration(seconds: 5)]);
    },
  );
  test(
    "a restored dump's feed time reduces the resume deadline",
    () async {
      // The dump allows 10s and had already spent 4s of it, so the resume
      // has 6s left plus the grace.
      final armed = await _afterLoad(
        snapshot: true,
        load: pb.ChildEvent(
          functionCall: pb.FunctionCall(functionName: 'f', callId: 1),
          feedExecutionMicros: Int64(4000000),
          maxFeedDurationMicros: Int64(10000000),
        ),
      );
      expect(armed, [const Duration(seconds: 7)]);
    },
  );
  test(
    "a load the worker refused keeps the session's feed budget",
    () async {
      final timers = PoolTimers();
      await timers.run(() async {
        final (session, _) = await poolB2Session(
          [
            answer([raised('ValueError', 'bad dump')]),
            hangAfter([]),
          ],
          config: const SessionConfig(
            limits: ResourceLimits(maxFeedDuration: Duration(seconds: 99)),
          ),
          options: const PoolOptions(
            minProcesses: 0,
            maxProcesses: 1,
            turnDurationLimitGrace: null,
          ),
        );
        await expectLater(
          session.loadSession(Uint8List.fromList([1])),
          throwsA(isA<MontyRuntimeError>()),
        );
        // The refused load left the session's own 99s in force.
        final failed = expectLater(session.feedRun('1'), _timeout);
        await pumpEventQueue();
        expect(timers.active, [const Duration(seconds: 100)]);
        timers.fire();
        await failed;
      });
    },
  );
  test(
    "a load the worker never saw keeps the session's feed budget",
    () async {
      final timers = PoolTimers();
      await timers.run(() async {
        final (session, _) = await poolB2Session(
          [hangAfter([])],
          config: const SessionConfig(
            limits: ResourceLimits(maxFeedDuration: Duration(seconds: 99)),
          ),
          options: const PoolOptions(
            minProcesses: 0,
            maxProcesses: 1,
            turnDurationLimitGrace: null,
          ),
          frameLimit: 4096,
        );
        // The frame is refused before it is written, so the worker never
        // sees the load and never answers it.
        await expectLater(
          session.loadSession(Uint8List.fromList(List.filled(5000, 1))),
          throwsA(
            isA<MontyRuntimeError>().having(
              (e) => e.exception.message,
              'message',
              contains('exceeds the maximum of 4096 bytes'),
            ),
          ),
        );
        // The unanswered load left the session's own 99s in force.
        final failed = expectLater(session.feedRun('1'), _timeout);
        await pumpEventQueue();
        expect(timers.active, [const Duration(seconds: 100)]);
        timers.fire();
        await failed;
      });
    },
  );
}
