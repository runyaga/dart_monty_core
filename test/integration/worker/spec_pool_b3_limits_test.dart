// Interpreter resource limits through actual dumps and recoverable errors.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_pool_support.dart';
import '_worker_harness.dart';

Future<Monty> _pool() async {
  final worker = await realWorker() as WorkerExecutable;
  final pool = await Monty.start(
    maxProcesses: 1,
    workerLocation: worker.path,
    feedDurationLimitGrace: null,
    turnDurationLimitGrace: null,
  );
  addTearDown(pool.close);

  return pool;
}

final Matcher _memory = throwsA(
  isA<MontyRuntimeError>()
      .having((e) => e.exception.excType, 'type', 'MemoryError')
      .having(
        (e) => e.exception.message,
        'message',
        matches(r'^memory limit exceeded: \d+ bytes > 16777216 bytes$'),
      ),
);
const _allocate = 'x = []\nwhile True:\n    x.append("a" * 100000)';

Future<void> _softError(String kind) async {
  final pool = await _pool();
  final session = await pool.checkout(
    limits: ResourceLimits(
      maxMemory: 16 * 1024 * 1024,
      maxFeedDuration: kind == 'feed' ? const Duration(milliseconds: 20) : null,
      maxTurnDuration: kind == 'turn' ? const Duration(milliseconds: 20) : null,
    ),
  );
  addTearDown(session.close);
  final pid = session.workerPid;
  await expectLater(
    session.feedRun(
      kind == 'memory'
          ? '["x" * 100000 for _ in range(1000)]'
          : 'while True: pass',
    ),
    kind == 'memory'
        ? _memory
        : throwsA(
            isA<MontyRuntimeError>()
                .having((e) => e.exception.excType, 'type', 'TimeoutError')
                .having(
                  (e) => e.exception.message,
                  'message',
                  matches('^$kind time limit exceeded: .+ > 20ms\$'),
                ),
          ),
  );
  expect(session.workerPid, pid);
  expect(await session.feedRun('6 * 7'), const MontyInt(42));
}

Future<void> _adopt(String kind) async {
  final pool = await _pool();
  final donor = await pool.checkout(
    limits: ResourceLimits(
      maxMemory: 16 * 1024 * 1024,
      maxRecursionDepth: kind == 'recursion' ? 8 : 100,
      gcInterval: 1,
    ),
  );
  final dump = await donor.dump();
  await donor.close();
  final receiver = await pool.checkout(
    limits: const ResourceLimits(
      maxMemory: 64 * 1024 * 1024,
      maxRecursionDepth: 100,
      gcInterval: 100000,
    ),
  );
  addTearDown(receiver.close);
  await receiver.loadSession(dump);
  if (kind == 'memory') {
    await expectLater(receiver.feedRun(_allocate), _memory);
  } else {
    await expectLater(
      receiver.feedRun(
        'def f(n):\n    return 42 if n == 20 else f(n + 1)\nf(0)',
      ),
      throwsA(
        runtimePool('RecursionError', 'maximum recursion depth exceeded'),
      ),
    );
  }
}

Future<void> _gcAdoption() async {
  const cycles =
      'for _ in range(300000):\n    x = []\n    x.append(x)\nx = None\n42';
  final pool = await _pool();
  const sparse = ResourceLimits(
    maxMemory: 16 * 1024 * 1024,
    gcInterval: 1000000000,
  );
  final checkout = pool.checkout;
  final control = await checkout(limits: sparse);
  await expectLater(control.feedRun(cycles), _memory);
  await control.close();
  final donor = await pool.checkout(
    limits: const ResourceLimits(
      maxMemory: 16 * 1024 * 1024,
      gcInterval: 1,
    ),
  );
  final dump = await donor.dump();
  await donor.close();
  final receiver = await checkout(limits: sparse);
  addTearDown(receiver.close);
  await receiver.loadSession(dump);
  expect(await receiver.feedRun(cycles), const MontyInt(42));
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'REQ-ResourceLimits-26: restored GC interval reclaims cycles',
    _gcAdoption,
  );
  for (final kind in ['memory', 'feed', 'turn']) {
    test(
      'REQ-ResourceLimits-42: same session accepts feed after soft $kind error',
      () => _softError(kind),
    );
  }
  for (final kind in ['memory', 'recursion']) {
    test(
      'REQ-ResourceLimits-26: restored interpreter adopts $kind limit',
      () => _adopt(kind),
    );
  }
  test(
    'REQ-ResourceLimits-32: receiving memory limit bounds Load before adoption',
    () async {
      final pool = await _pool();
      final checkout = pool.checkout;
      final donor = await checkout(
        limits: const ResourceLimits(
          maxMemory: 64 * 1024 * 1024,
        ),
      );
      expect(
        await donor.feedRun('payload = "x" * 8388608\nlen(payload)'),
        const MontyInt(8388608),
      );
      final dump = await donor.dump();
      await donor.close();
      final receiver = await pool.checkout(
        limits: const ResourceLimits(maxMemory: 65536),
      );
      addTearDown(receiver.close);
      await expectLater(
        receiver.loadSession(dump),
        throwsA(
          runtimePool(
            'MemoryError',
            'the worker exceeded its memory limit and was terminated',
          ),
        ),
      );
      await expectLater(receiver.feedRun('1'), finishedPool);
      final roomy = await checkout(
        limits: const ResourceLimits(maxMemory: 64 * 1024 * 1024),
      );
      addTearDown(roomy.close);
      await roomy.loadSession(dump);
      expect(await roomy.feedRun('len(payload)'), const MontyInt(8388608));
    },
  );
}
