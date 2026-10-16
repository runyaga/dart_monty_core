// Manual OS futures: expectations from ExternalFuture.md and
// snapshots-and-futures.md.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_pool_support.dart';
import '_worker_harness.dart';

Future<MontySession> _session({String sleep = 'call_host'}) async {
  final worker = await realWorker() as WorkerExecutable;
  final pool = await Monty.start(maxProcesses: 1, workerLocation: worker.path);
  addTearDown(pool.close);
  final session = await pool.checkout(
    osPolicy: OsPolicy(
      sleep: sleep,
      datetime: 'call_host',
      randomStart: 'call_host',
    ),
  );
  addTearDown(session.close);

  return session;
}

Future<void> _fileEffect(String operation, String mode) async {
  final session = await _session();
  final call =
      await session.feedStart(
            'result = await handle.$operation\n(result, handle.tell())',
            inputs: {
              'handle': MontyFileHandle('/f', mode, position: BigInt.one),
            },
          )
          as FunctionSnapshot;
  expect(call.isOsFunction, isTrue);
  final pending = await call.resume(const ExternalFuture()) as FutureSnapshot;
  expect(call.isSpent, isTrue);
  expect(() => call.resume(const ExternalFuture()), spentPool);
  expect(pending.pendingCallIds, [call.callId]);
  final done =
      await pending.resume({
            call.callId: const ExternalReturnValue(MontyString('raw reply')),
          })
          as MontyComplete;
  expect(
    done.output,
    const MontyTuple([MontyString('raw reply'), MontyInt(1)]),
  );
  if (mode == 'r') {
    // Discarded BufferStore leaves the next read needing a fresh OS reply.
    final read = await session.feedStart('handle.read(1)') as FunctionSnapshot;
    expect(read.functionName, 'Path.read_text');
    final next =
        await read.resume(const ExternalReturnValue(MontyString('ABCD')))
            as MontyComplete;
    expect(next.output, const MontyString('B'));
  }
}

Future<void> _rejected(String expression, String name) async {
  final session = await _session();
  final call =
      await session.feedStart('''
import os
import time
from pathlib import Path
try:
    $expression
except RuntimeError as error:
    message = str(error)
await f()
message
''')
          as FunctionSnapshot;
  expect(call.functionName, switch (name) {
    'os.listdir' => 'Path.iterdir',
    'os.chdir' => 'Path.stat',
    _ => name,
  });
  final next = await call.resume(const ExternalFuture()) as FunctionSnapshot;
  expect(call.isSpent, isTrue);
  expect(() => call.resume(const ExternalFuture()), spentPool);
  expect(next.functionName, 'f');
  final pending = await next.resume(const ExternalFuture()) as FutureSnapshot;
  expect(pending.pendingCallIds, [next.callId]);
  final done =
      await pending.resume({
            next.callId: const ExternalReturnValue(MontyNone()),
          })
          as MontyComplete;
  expect(done.output, MontyString('$name cannot be answered with a future'));
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  for (final id in ['ExternalFuture-11', 'ExternalFuture-12']) {
    for (final (operation, mode) in [
      ('read(2)', 'r'),
      ('seek(0, 2)', 'r'),
      ("write('XY')", 'w'),
    ]) {
      test(
        'REQ-$id: $operation discards effects and settles raw reply',
        () => _fileEffect(operation, mode),
      );
    }
  }
  for (final sleep in ['system', 'call_host']) {
    test(
      'REQ-ExternalFuture-13: $sleep future preserves sleep result',
      () async {
        final session = await _session(sleep: sleep);
        final call =
            await session.feedStart(
                  'import asyncio\nawait asyncio.sleep(0.25, result=7)',
                )
                as FunctionSnapshot;
        expect(
          call.functionName,
          sleep == 'system' ? 'system.async_sleep' : 'asyncio.sleep',
        );
        final pending =
            await call.resume(const ExternalFuture()) as FutureSnapshot;
        expect(pending.pendingCallIds, [call.callId]);
        final done =
            await pending.resume({
                  call.callId: const ExternalReturnValue(MontyInt(99)),
                })
                as MontyComplete;
        expect(done.output, const MontyInt(7));
      },
    );
  }
  for (final id in ['snapshots-and-futures-74']) {
    for (final (expression, name) in [
      ("os.listdir('/')", 'os.listdir'),
      ("os.chdir('/')", 'os.chdir'),
      ("list(Path('/').iterdir())", 'Path.iterdir'),
      ('os.urandom(2)', 'os.urandom'),
      ("open('/f')", 'open'),
      ('time.sleep(0)', 'time.sleep'),
    ]) {
      test(
        'REQ-$id: $name rejects future without registering it',
        () => _rejected(expression, name),
      );
    }
  }
  test(
    'REQ-snapshots-and-futures-85: unresolved future rejects a second awaiter',
    () async {
      final session = await _session();
      final call =
          await session.feedStart('''
import asyncio
pending = f()
async def waiter():
    return await pending
await asyncio.gather(waiter(), waiter())
''')
              as FunctionSnapshot;
      await expectLater(
        call.resume(const ExternalFuture()),
        throwsA(
          runtimePool('RuntimeError', 'cannot reuse already awaited future'),
        ),
      );
      expect(await session.feedRun('6 * 7'), const MontyInt(42));
    },
  );
}
