@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart'
    show WorkerExecutable;
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../unit/worker/_telemetry_cases.dart';
import '_worker_harness.dart';

void main() {
  expectNoWorkersLeftAfterEachTest();
  telemetryWorkerTests(() async {
    final location = await realWorker() as WorkerExecutable;
    return startMonty(
      PoolOptions(maxProcesses: 1, workerLocation: location.path),
    );
  }, native: true);
}
