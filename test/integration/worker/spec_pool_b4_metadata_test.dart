// The dump owns the worker filename; snapshot metadata has its own rule.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '_worker_harness.dart';

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'REQ-snapshots-and-futures-49: idle restore adopts worker script name',
    () async {
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
            (e) => e
                .display()
                .split('\n')
                .where((line) => line.startsWith(' --> ')),
            'diagnostic source',
            [' --> original.py:1:10'],
          ),
        ),
      );
    },
  );
}
