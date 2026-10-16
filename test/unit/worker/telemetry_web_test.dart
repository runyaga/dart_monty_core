@TestOn('browser')
@Tags(['worker'])
library;

import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_telemetry_cases.dart';

void main() => telemetryWorkerTests(
  () => startMonty(const PoolOptions(maxProcesses: 1)),
  native: false,
);
