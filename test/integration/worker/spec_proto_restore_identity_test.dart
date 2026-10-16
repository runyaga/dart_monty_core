// A restored idle session retains its dump state but new feeds use checkout's
// script name for any later suspension.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_worker_harness.dart';

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'later suspension uses restoring checkout name',
    () async {
      final pool = await Monty.start(maxProcesses: 2);
      addTearDown(pool.close);
      final source = await pool.checkout(scriptName: 'a.py');
      addTearDown(source.close);
      await source.feedRun('value = 41');
      final dump = await source.dump();
      final restored = await pool.checkout(scriptName: 'b.py');
      addTearDown(restored.close);
      await restored.loadSession(dump);
      expect(await restored.feedRun('value'), const MontyInt(41));
      final snapshot = await restored.feedStart('f()') as FunctionSnapshot;
      expect(snapshot.scriptName, 'b.py');
      expect(
        (await snapshot.resume(const ExternalReturnValue(MontyInt(1)))
                as MontyComplete)
            .output,
        const MontyInt(1),
      );
    },
  );
}
