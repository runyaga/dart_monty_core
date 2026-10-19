// Snapshot consumption and failure contracts from api/FunctionSnapshot.md.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_pool_support.dart';
import '_scripted_channel.dart';

Future<void> _memoryFailure({bool resume = false}) async {
  final channel = ScriptedChannel([
    configurePool,
    if (resume) answer([poolCall()]),
    crash(CrashCause.outOfMemory, 'I/O failed', 65),
  ]);
  final pool = await poolWith([channel]);
  final session = await pool.checkout();
  addTearDown(session.close);
  final Future<Object?> failed;
  if (resume) {
    final snapshot = await session.feedStart('f()') as FunctionSnapshot;
    failed = snapshot.resume(const ExternalReturnValue(MontyNone()));
  } else {
    failed = session.feedRun('allocate()');
  }
  await expectLater(
    failed,
    throwsA(
      runtimePool(
        'MemoryError',
        'the worker exceeded its memory limit and was terminated',
      ),
    ),
  );
  await expectLater(session.feedRun('1'), finishedPool);
  expect(pool.liveWorkers, 0);
  expect(channel.kills, 1);
}

void main() {
  test(
    'auto consumes before a failing callback',
    () async {
      final channel = ScriptedChannel([
        configurePool,
        answer([poolCall()]),
        answer([raised('ValueError', 'callback failed')]),
        resetPool,
      ]);
      final pool = await poolWith([channel]);
      final session = await pool.checkout();
      addTearDown(session.close);
      late final FunctionSnapshot snapshot;
      var called = 0;
      bool? spentAtEntry;
      snapshot =
          await session.feedStart(
                'f()',
                externalLookup: {
                  'f': MontyHostFunction('f', (_, _) {
                    called++;
                    spentAtEntry = snapshot.isSpent;
                    throw const ExternalException(
                      'ValueError',
                      'callback failed',
                    );
                  }),
                },
              )
              as FunctionSnapshot;
      await expectLater(
        snapshot.resumeAuto(),
        throwsA(runtimePool('ValueError', 'callback failed')),
      );
      expect(called, 1);
      expect(spentAtEntry, isTrue);
      expect(
        () => snapshot.resume(const ExternalReturnValue(MontyInt(1))),
        spentPool,
      );
      await expectLater(Future.sync(snapshot.resumeAuto), spentPool);
      expect(called, 1);
    },
  );
  test(
    'invalid answer wins over already consumed',
    () async {
      final channel = ScriptedChannel([
        configurePool,
        answer([poolCall()]),
        answer([completeNone()]),
        resetPool,
      ]);
      final pool = await poolWith([channel]);
      final session = await pool.checkout();
      addTearDown(session.close);
      final snapshot = await session.feedStart('f()') as FunctionSnapshot;
      await snapshot.resume(const ExternalReturnValue(MontyNone()));
      expect(
        () => snapshot.resume(const ExternalReturnValue(MontyBytes([256]))),
        throwsArgumentError,
      );
      expect(
        () => snapshot.resume(const ExternalException('NoSuchError')),
        throwsArgumentError,
      );
      expect(
        () => snapshot.resume(const ExternalReturnValue(MontyInt(1))),
        spentPool,
      );
      expect(channel.requests, hasLength(3));
    },
  );
  test(
    'close recovers an oversized manual answer',
    () async {
      final channel = ScriptedChannel([
        configurePool,
        answer([poolCall()]),
        resetPool,
        configurePool,
        answer([completeNone()]),
        resetPool,
      ], frameLimit: 64);
      final pool = await poolWith([channel]);
      final session = await pool.checkout();
      final snapshot = await session.feedStart('f()') as FunctionSnapshot;
      await expectLater(
        snapshot.resume(
          ExternalReturnValue(
            MontyString('x' * 100),
          ),
        ),
        throwsA(isA<MontyRuntimeError>()),
      );
      expect(snapshot.isSpent, isTrue);
      await expectLater(
        session.feedRun('1'),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'feed called while a suspension is awaiting an answer',
          ),
        ),
      );
      expect(channel.requests, hasLength(2));
      await session.close();
      expect(
        itemAt(channel.requests, channel.requests.length - 1).whichKind(),
        pb.ParentRequest_Kind.reset,
      );
      expect(pool.idleWorkers, 1);
      final next = await pool.checkout(scriptName: 'next.py');
      expect(await next.feedRun('None'), const MontyNone());
      await next.close();
      expect(channel.kills, 0);
    },
  );
  test(
    'resume deadline kills and finishes checkout',
    () async {
      final timers = PoolTimers();
      await timers.run(() async {
        final channel = ScriptedChannel([
          configurePool,
          answer([poolCall()]),
          hangAfter([]),
        ]);
        final pool = await poolWith(
          [channel],
          options: const PoolOptions(
            minProcesses: 0,
            maxProcesses: 1,
            requestTimeout: Duration(seconds: 2),
          ),
        );
        final session = await pool.checkout();
        final snapshot = await session.feedStart('f()') as FunctionSnapshot;
        final failed = expectLater(
          snapshot.resume(const ExternalReturnValue(MontyNone())),
          throwsA(
            isA<MontyCrashedError>()
                .having((e) => e.timedOut, 'timedOut', isTrue)
                .having((e) => e.exitStatus, 'exitStatus', isNull),
          ),
        );
        expect(timers.active, [const Duration(seconds: 2)]);
        timers.fire();
        await failed;
        expect(snapshot.isSpent, isTrue);
        expect(channel.kills, 1);
        expect(pool.liveWorkers, 0);
        await expectLater(session.feedRun('1'), finishedPool);
      });
    },
  );
  test(
    'exit 65 during resume finishes checkout',
    () => _memoryFailure(resume: true),
  );
  test(
    'exit 65 has the exact MemoryError and finishes checkout',
    _memoryFailure,
  );
}
