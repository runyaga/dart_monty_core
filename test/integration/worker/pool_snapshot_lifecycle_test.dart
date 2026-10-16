// Real interpreter outcomes for FutureSnapshot and NameLookupSnapshot.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '../../unit/worker/_pool_support.dart';
import '_worker_harness.dart';

Future<Monty> _pool() async {
  final worker = await realWorker() as WorkerExecutable;
  final pool = await Monty.start(maxProcesses: 1, workerLocation: worker.path);
  addTearDown(pool.close);

  return pool;
}

Future<(MontySession, FunctionSnapshot, FutureSnapshot)> _pending(
  Monty pool,
) async {
  final session = await pool.checkout(scriptName: 'future-job.py');
  addTearDown(session.close);
  final call = await session.feedStart('await f()') as FunctionSnapshot;
  final future = await call.resume(const ExternalFuture()) as FutureSnapshot;

  return (session, call, future);
}

Future<void> _restoreFuture() async {
  final pool = await _pool();
  final (session, call, future) = await _pending(pool);
  final dump = await future.dump();
  final original =
      await future.resume({
            call.callId: const ExternalReturnValue(MontyInt(11)),
          })
          as MontyComplete;
  expect(original.output, const MontyInt(11));
  await session.close();
  final restoredSession = await pool.checkout();
  addTearDown(restoredSession.close);
  final restored = await restoredSession.loadSnapshot(dump) as FutureSnapshot;
  expect(restored.pendingCallIds, [call.callId]);
  final done =
      await restored.resume({
            call.callId: const ExternalReturnValue(MontyInt(29)),
          })
          as MontyComplete;
  expect(done.output, const MontyInt(29));
}

Future<void> _noneLookup() async {
  final pool = await _pool();
  final session = await pool.checkout();
  addTearDown(session.close);
  final start = session.feedStart;
  final first = await start('missing') as NameLookupSnapshot;
  await expectLater(
    first.resume(),
    throwsA(runtimePool('NameError', "name 'missing' is not defined")),
  );
  final second = await start('missing') as NameLookupSnapshot;
  final done = await second.resume(value: const MontyNone()) as MontyComplete;
  expect(done.output, const MontyNone());
  expect(await session.feedRun('missing is None'), const MontyBool(true));
}

Future<void> _cacheLookup() async {
  final pool = await _pool();
  final session = await pool.checkout();
  addTearDown(session.close);
  final snapshot = await session.feedStart('x + x') as NameLookupSnapshot;
  expect(snapshot.variableName, 'x');
  final done =
      await snapshot.resume(value: const MontyInt(21)) as MontyComplete;
  expect(done.output, const MontyInt(42));
  final next = await session.feedStart('x') as MontyComplete;
  expect(next.output, const MontyInt(21));
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'answered local is cached within its call',
    () async {
      final pool = await _pool();
      final session = await pool.checkout();
      addTearDown(session.close);
      final snapshot =
          await session.feedStart('def g():\n    x: int\n    return x + x\ng()')
              as NameLookupSnapshot;
      expect(snapshot.variableName, 'x');
      final done =
          await snapshot.resume(value: const MontyInt(21)) as MontyComplete;
      expect(done.output, const MontyInt(42));
    },
  );
  test('dumped futures remain resumable and restore manually', _restoreFuture);
  test(
    'position names the main await expression',
    () async {
      final pool = await _pool();
      final (_, _, future) = await _pending(pool);
      expect(
        future.position,
        SourceRange(filename: '<python-input-0>', start: 0, end: 9),
      );
    },
  );
  test(
    'empty settlement returns the pending snapshot',
    () async {
      final pool = await _pool();
      final (_, call, future) = await _pending(pool);
      final stillPending = await future.resume({}) as FutureSnapshot;
      expect(stillPending.pendingCallIds, [call.callId]);
      final done =
          await stillPending.resume({
                call.callId: const ExternalReturnValue(MontyInt(42)),
              })
              as MontyComplete;
      expect(done.output, const MontyInt(42));
    },
  );
  test(
    'unknown ID consumes but leaves session usable',
    () async {
      final pool = await _pool();
      final (session, call, future) = await _pending(pool);
      final unknown = call.callId + 1;
      await expectLater(
        future.resume({unknown: const ExternalReturnValue(MontyInt(42))}),
        throwsA(
          runtimePool(
            'RuntimeError',
            'unknown call_id $unknown, expected one of: [${call.callId}]',
          ),
        ),
      );
      expect(
        () => future.resume({
          call.callId: const ExternalReturnValue(MontyInt(42)),
        }),
        spentPool,
      );
      expect(await session.feedRun('6 * 7'), const MontyInt(42));
    },
  );
  test(
    'dump keeps original and restored lookup '
    'pending',
    () async {
      final pool = await _pool();
      final checkout = pool.checkout;
      final session = await checkout();
      addTearDown(session.close);
      final snapshot = await session.feedStart('x + 1') as NameLookupSnapshot;
      final dump = await snapshot.dump();
      final first =
          await snapshot.resume(value: const MontyInt(1)) as MontyComplete;
      expect(first.output, const MontyInt(2));
      await session.close();
      final next = await checkout();
      addTearDown(next.close);
      final restored = await next.loadSnapshot(dump) as NameLookupSnapshot;
      expect(restored.variableName, 'x');
      final second =
          await restored.resume(value: const MontyInt(9)) as MontyComplete;
      expect(second.output, const MontyInt(10));
    },
  );
  test('answered global is cached within and across feeds', _cacheLookup);
  test('Dart null is undefined and MontyNone supplies None', _noneLookup);
  test('idle restore adopts worker script name', () async {
    final worker = await realWorker() as WorkerExecutable;
    final pool = await Monty.start(
      maxProcesses: 1,
      workerLocation: worker.path,
    );
    addTearDown(pool.close);
    final original = await pool.checkout(
      scriptName: 'original.py',
      typeCheck: true,
    );
    final dump = await original.dump();
    await original.close();
    final restored = await pool.checkout(scriptName: 'restoring.py');
    addTearDown(restored.close);
    await restored.loadSession(dump);
    await expectLater(
      restored.feedRun('x: int = "bad"'),
      throwsA(
        isA<MontyTypingError>().having(
          (e) =>
              e.display().split('\n').where((line) => line.startsWith(' --> ')),
          'diagnostic source',
          [' --> original.py:1:10'],
        ),
      ),
    );
  });
}
