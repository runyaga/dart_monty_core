@TestOn('browser')
@Tags(['worker'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_telemetry_late_install_cases.dart';

void main() => telemetryLateInstallTests(() => Monty.start(maxProcesses: 1));
