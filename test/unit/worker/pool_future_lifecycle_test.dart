// FutureSnapshot contracts: lifecycle and errors at the manual-resume boundary.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_pool_protocol_support.dart';
import '_pool_support.dart';
import '_scripted_channel.dart';

Future<void> _noTasks(bool restored) async {
  final (session, channel) = await poolB2Session([
    answer([poolB2Futures()]),
  ]);
  final snapshot =
      (restored
              ? await session.loadSnapshot(Uint8List.fromList([1]))
              : await session.feedStart('await f()'))
          as FutureSnapshot;
  await expectLater(snapshot.resumeAuto(), throwsStateError);
  expect(() => snapshot.resume({1: poolB2Answer}), spentPool);
  expect(channel.kills, 1);
  await expectLater(session.feedRun('1'), finishedPool);
}

Future<void> _lifecycle(bool closed) async {
  final (session, channel) = await poolB2Session([
    answer([poolB2Futures()]),
    if (!closed) answer([completeNone()]),
  ]);
  final snapshot = await session.feedStart('await f()') as FutureSnapshot;
  if (closed) {
    await session.close();
    await expectLater(snapshot.dump, finishedPool);
  } else {
    final done = await snapshot.resume({1: poolB2Answer}) as MontyComplete;
    expect(done.output, const MontyNone());
  }
  expect(
    () => snapshot.resume({
      1: const ExternalReturnValue(MontyBytes([256])),
    }),
    throwsArgumentError,
  );
  await expectLater(
    () => snapshot.resume({1: poolB2Answer}),
    closed ? finishedPool : spentPool,
  );
  await expectLater(snapshot.dump, throwsStateError);
  await expectLater(snapshot.resumeAuto, throwsStateError);
  expect(channel.requests, hasLength(3));
}

Future<void> _crash(Reply reply, Matcher error) async {
  final (session, channel) = await poolB2Session([
    answer([poolB2Futures()]),
    reply,
  ]);
  final snapshot = await session.feedStart('await f()') as FutureSnapshot;
  await expectLater(snapshot.resume({1: poolB2Answer}), error);
  expect(() => snapshot.resume({1: poolB2Answer}), spentPool);
  await expectLater(session.feedRun('1'), finishedPool);
  expect(channel.kills, 1);
}

Future<void> _deadline() async {
  final timers = PoolTimers();
  await timers.run(() async {
    final (session, channel) = await poolB2Session(
      [
        answer([poolB2Futures()]),
        hangAfter([]),
      ],
      options: const PoolOptions(
        minProcesses: 0,
        maxProcesses: 1,
        requestTimeout: Duration(seconds: 2),
      ),
    );
    final snapshot = await session.feedStart('await f()') as FutureSnapshot;
    final failed = expectLater(
      snapshot.resume({1: poolB2Answer}),
      throwsA(
        isA<MontyCrashedError>().having((e) => e.timedOut, 'timedOut', isTrue),
      ),
    );
    await pumpEventQueue();
    expect(timers.active, [const Duration(seconds: 2)]);
    timers.fire();
    await failed;
    expect(channel.kills, 1);
    await expectLater(session.feedRun('1'), finishedPool);
  });
}

void main() {
  test(
    'settlement deadline kills and finishes',
    _deadline,
  );
  for (final restored in [false, true]) {
    test(
      'no host tasks consumes and ends ($restored)',
      () => _noTasks(restored),
    );
  }
  for (final closed in [false, true]) {
    test(
      'validation precedes lifecycle ($closed)',
      () => _lifecycle(closed),
    );
  }
  test(
    'pending future reports session script name',
    () async {
      final (session, _) = await poolB2Session([
        answer([poolB2Futures()]),
      ], config: const SessionConfig(scriptName: 'future-job.py'));
      final snapshot = await session.feedStart('await f()') as FutureSnapshot;
      expect(snapshot.scriptName, 'future-job.py');
    },
  );
  test(
    'resumed SyntaxError keeps its type and text',
    () async {
      final (session, _) = await poolB2Session([
        answer([poolB2Futures()]),
        answer([raised('SyntaxError', 'invalid syntax')]),
        answer([completeNone()]),
      ]);
      final snapshot = await session.feedStart('await f()') as FutureSnapshot;
      await expectLater(
        snapshot.resume({1: poolB2Answer}),
        throwsA(
          isA<MontySyntaxError>()
              .having((e) => e.exception.excType, 'type', 'SyntaxError')
              .having((e) => e.exception.message, 'message', 'invalid syntax'),
        ),
      );
      expect(await session.feedRun('None'), const MontyNone());
    },
  );
  test(
    'exit 65 during settlement ends session',
    () => _crash(
      crash(CrashCause.outOfMemory, 'I/O failed', 65),
      throwsA(
        runtimePool(
          'MemoryError',
          'the worker exceeded its memory limit and was terminated',
        ),
      ),
    ),
  );
  for (final (label, reply) in [
    ('death', crash(CrashCause.vanished, 'broken pipe', 7)),
    ('fatal', answer([fatal('worker failed')])),
  ]) {
    test(
      '$label during settlement ends session',
      () => _crash(
        reply,
        throwsA(
          isA<MontyCrashedError>().having(
            (e) => e.timedOut,
            'timedOut',
            isFalse,
          ),
        ),
      ),
    );
  }
}
