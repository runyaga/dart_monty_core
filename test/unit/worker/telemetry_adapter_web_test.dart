@TestOn('browser')
@Tags(['worker'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../integration/worker/_telemetry_adapter_cases.dart';

void main() => telemetryAdapterTests(() => Monty.start(maxProcesses: 1));
