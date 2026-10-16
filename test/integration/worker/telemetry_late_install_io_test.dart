@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';

import '../../unit/worker/_telemetry_late_install_cases.dart';
import '_worker_harness.dart';

void main() {
  expectNoWorkersLeftAfterEachTest();
  telemetryLateInstallTests(() async {
    final worker = await realWorker() as WorkerExecutable;

    return Monty.start(maxProcesses: 1, workerLocation: worker.path);
  });
}
