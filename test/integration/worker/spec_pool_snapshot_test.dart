// Snapshot contracts against the real worker, with spec-authored expectations.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_pool_support.dart';
import '_worker_harness.dart';

Future<void> _withSession(Future<void> Function(MontySession) body) async {
  final location = await realWorker() as WorkerExecutable;
  await Monty.withPool(
    (pool) => pool.withSession(
      body,
      limits: const ResourceLimits(maxMemory: 64 * 1024 * 1024),
      osPolicy: const OsPolicy(sleep: 'call_host'),
    ),
    maxProcesses: 1,
    workerLocation: location.path,
  );
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'REQ-FunctionSnapshot-11: declining non-filesystem OS call '
    'raises RuntimeError',
    () => _withSession((session) async {
      final call =
          await session.feedStart('import time\ntime.sleep(0)')
              as FunctionSnapshot;
      expect(call.functionName, 'time.sleep');
      await expectLater(
        call.resumeNotHandled(),
        throwsA(
          runtimePool(
            'RuntimeError',
            "'time.sleep' is not supported in this environment",
          ),
        ),
      );
    }),
  );
  test(
    'REQ-FunctionSnapshot-33: rejected OS future is absent '
    'from pending futures',
    () => _withSession((session) async {
      final sleep =
          await session.feedStart('''
import time
try:
    time.sleep(0)
except RuntimeError as error:
    message = str(error)
await f()
message
''')
              as FunctionSnapshot;
      final next =
          await sleep.resume(const ExternalFuture()) as FunctionSnapshot;
      expect(next.functionName, 'f');
      final futures =
          await next.resume(const ExternalFuture()) as FutureSnapshot;
      expect(futures.pendingCallIds, [next.callId]);
      expect(futures.pendingCallIds, isNot(contains(sleep.callId)));
      final done =
          await futures.resume({
                next.callId: const ExternalReturnValue(MontyNone()),
              })
              as MontyComplete;
      expect(
        done.output,
        const MontyString('time.sleep cannot be answered with a future'),
      );
    }),
  );
  test(
    'REQ-FunctionSnapshot-34: rejected OS future consumes the snapshot',
    () => _withSession((session) async {
      final call =
          await session.feedStart('import time\ntime.sleep(0)')
              as FunctionSnapshot;
      await expectLater(
        call.resume(const ExternalFuture()),
        throwsA(
          runtimePool(
            'RuntimeError',
            'time.sleep cannot be answered with a future',
          ),
        ),
      );
      expect(call.isSpent, isTrue);
      expect(
        () => call.resume(const ExternalReturnValue(MontyNone())),
        spentPool,
      );
    }),
  );
  test(
    'REQ-SourceRange-9: eval offsets exclude leading whitespace',
    () => _withSession((session) async {
      final call =
          await session.feedStart("eval('  1 + fetch()')") as FunctionSnapshot;
      expect(
        call.position,
        SourceRange(filename: '<string>', start: 4, end: 11),
      );
      final done =
          await call.resume(const ExternalReturnValue(MontyInt(2)))
              as MontyComplete;
      expect(done.output, const MontyInt(3));
    }),
  );
  test(
    'REQ-SourceRange-12: earlier function points into its defining feed',
    () => _withSession((session) async {
      expect(
        await session.feedRun('def g():\n    return fetch()\n'),
        const MontyNone(),
      );
      final call = await session.feedStart('g()') as FunctionSnapshot;
      expect(
        call.position,
        SourceRange(
          filename: '<python-input-0>',
          start: 20,
          end: 27,
        ),
      );
      final done =
          await call.resume(const ExternalReturnValue(MontyInt(7)))
              as MontyComplete;
      expect(done.output, const MontyInt(7));
    }),
  );
}
