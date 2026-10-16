@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '../../unit/worker/_telemetry_metrics_cases.dart';
import '_worker_harness.dart';

void main() {
  expectNoWorkersLeftAfterEachTest();
  telemetryMetricsTests(() async {
    final worker = await realWorker() as WorkerExecutable;

    return Monty.start(maxProcesses: 2, workerLocation: worker.path);
  });
}
