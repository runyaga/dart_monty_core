/// Host telemetry bridge with isolate-wide installation and failures.
library;

import 'dart:async';

import 'package:dart_monty_core/src/worker/telemetry_metrics.dart';

part 'monty_telemetry.dart';
part 'telemetry_bridge.dart';
part 'invocation.dart';

final class _Telemetry {
  TelemetryBridge? bridge;
}

/// Installs the telemetry adapter for this isolate's lifetime.
///
/// This must run before the first checkout because existing sessions never
/// report. A second call throws [StateError]. A throwing signal stops for the
/// rest of the isolate while the other signals continue, and its first failure
/// is reported through the installation zone. Browser and native sessions
/// record the same signals.
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
