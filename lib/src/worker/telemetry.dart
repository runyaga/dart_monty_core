/// Host telemetry bridge. Installation and failures are isolate-wide.
library;

import 'dart:async';

import 'package:dart_monty_core/src/worker/telemetry_metrics.dart';

part 'monty_telemetry.dart';
part 'telemetry_bridge.dart';
part 'invocation.dart';

final class _Telemetry {
  TelemetryBridge? bridge;
}

/// Installs [telemetry] for this isolate's lifetime. Cannot be undone.
/// A second call throws [StateError]. With no adapter, no records are made
/// and snapshot trace contexts are null (D-087). Browser sessions record
/// the same signals as native sessions (D-090).
void instrumentTelemetry(MontyTelemetry telemetry) {
  if (_installation.bridge != null) {
    throw StateError('Monty telemetry is already configured');
  }
  _installation.bridge = TelemetryBridge(telemetry, Zone.current);
  seedWorkerGauges();
}

/// Internal installation, shared by all recorders and the metric boundary.
TelemetryBridge? get telemetryBridge => _installation.bridge;

final _installation = _Telemetry();
