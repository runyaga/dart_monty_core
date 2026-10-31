// The 1.3.0 migration cases against the real native worker: the cases that
// must change with the worker, run on the VM.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:test/test.dart';

import '../../unit/worker/_migration_130_cases.dart';
import '_worker_harness.dart';

void main() {
  expectNoWorkersLeftAfterEachTest();
  migration130SessionTests('vm', startMonty);
}
