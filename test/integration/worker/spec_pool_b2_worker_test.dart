// Batch-two contracts that need a real worker, including Python rejections.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_pool_support.dart';
import '_worker_harness.dart';

Future<Monty> _pool({bool disableGraces = false}) async {
  final location = await realWorker() as WorkerExecutable;
  final pool = await Monty.start(
    maxProcesses: 1,
    workerLocation: location.path,
    feedDurationLimitGrace: disableGraces ? null : const Duration(seconds: 1),
    turnDurationLimitGrace: disableGraces ? null : const Duration(seconds: 1),
  );
  addTearDown(pool.close);

  return pool;
}

Future<void> _unknown() async {
  final pool = await _pool();
  final session = await pool.checkout();
  addTearDown(session.close);
  final call = await session.feedStart('await f()') as FunctionSnapshot;
  final pending = await call.resume(const ExternalFuture()) as FutureSnapshot;
  final id = call.callId + 1;
  expect(pending.pendingCallIds, [call.callId]);
  await expectLater(
    pending.resume({id: const ExternalReturnValue(MontyInt(1))}),
    throwsA(
      runtimePool(
        'RuntimeError',
        'unknown call_id $id, expected one of: [${call.callId}]',
      ),
    ),
  );
  expect(
    () => pending.resume({call.callId: const ExternalReturnValue(MontyInt(1))}),
    spentPool,
  );
}

Future<void> _softError(String kind) async {
  final pool = await _pool(disableGraces: true);
  final limits = ResourceLimits(
    maxMemory: 16 * 1024 * 1024,
    maxFeedDuration: kind == 'feed' ? const Duration(milliseconds: 20) : null,
    maxTurnDuration: kind == 'turn' ? const Duration(milliseconds: 20) : null,
  );
  final session = await pool.checkout(limits: limits);
  final pid = session.workerPid;
  final memory = kind == 'memory';
  await expectLater(
    session.feedRun(
      memory
          ? 'x = []\nwhile True:\n    x.append("a" * 100000)'
          : 'while True: pass',
    ),
    throwsA(
      isA<MontyRuntimeError>()
          .having(
            (e) => e.exception.excType,
            'type',
            memory ? 'MemoryError' : 'TimeoutError',
          )
          .having(
            (e) => e.exception.message,
            'message',
            matches(
              memory
                  ? r'^memory limit exceeded: \d+ bytes > 16777216 bytes$'
                  : '^$kind time limit exceeded: .+ > 20ms\$',
            ),
          ),
    ),
  );
  // Soft errors need not preserve heap state: reuse the reset worker.
  await session.close();
  final next = await pool.checkout();
  addTearDown(next.close);
  expect(next.workerPid, pid);
  expect(await next.feedRun('6 * 7'), const MontyInt(42));
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  for (final id in [
    'ExternalSettledResult-13',
    'ExternalSettledResult-8',
    'MontySnapshot-9',
  ]) {
    test('REQ-$id: unknown pending call consumes the snapshot', _unknown);
  }
  for (final kind in ['memory', 'feed', 'turn']) {
    test(
      'REQ-budgets-and-limits-67: worker reused after soft $kind error',
      () => _softError(kind),
    );
  }
  for (final kind in ['feed', 'turn']) {
    test(
      'REQ-budgets-and-limits-45: null graces retain interpreter $kind limit',
      () => _softError(kind),
    );
  }
  test(
    'REQ-budgets-and-limits-43: call_host sleeps consume no total-sleep budget',
    () async {
      final pool = await _pool();
      final session = await pool.checkout(
        limits: const ResourceLimits(maxTotalSleep: Duration.zero),
        osPolicy: const OsPolicy(sleep: 'call_host'),
      );
      addTearDown(session.close);
      final calls = <String>[];
      for (var feed = 0; feed < 2; feed++) {
        expect(
          await session.feedRun(
            'import time\ntime.sleep(10)\n42',
            os: (name, args, kwargs) {
              calls.add(name);
              expect(args, [const MontyInt(10)]);
              expect(kwargs, isEmpty);

              return const MontyNone();
            },
          ),
          const MontyInt(42),
        );
      }
      expect(calls, ['time.sleep', 'time.sleep']);
    },
  );
}
