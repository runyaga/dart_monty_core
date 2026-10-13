// A program whose session prints with no print callback. The test that runs
// it reads what reached this process's own stdout and stderr.
//
// usage: dart default_print_probe.dart <worker executable>
//
// DCM: this is a spawned entry point, not a test.
// ignore_for_file: prefer-correct-test-file-name

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';

Future<void> main(List<String> args) async {
  await MontyPool.withPool(
    (pool) => pool.withSession(
      (session) => session.feedRun(
        "print('a', end='')\n"
        "print('b')\n"
        'import sys\n'
        "print('e', file=sys.stderr)\n",
      ),
    ),
    maxProcesses: 1,
    workerLocation: args.firstOrNull,
  );
}
