@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '_telemetry_adapter_cases.dart';
import '_worker_harness.dart';

void main() {
  expectNoWorkersLeftAfterEachTest();
  telemetryAdapterTests(() async {
    final worker = await realWorker() as WorkerExecutable;

    return Monty.start(maxProcesses: 1, workerLocation: worker.path);
  });
}
