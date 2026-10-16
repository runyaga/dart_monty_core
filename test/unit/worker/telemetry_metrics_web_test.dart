@TestOn('browser')
@Tags(['worker'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_telemetry_metrics_cases.dart';

void main() => telemetryMetricsTests(() => Monty.start(maxProcesses: 2));
