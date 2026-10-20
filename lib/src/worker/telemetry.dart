/// Host telemetry bridge. Installation and failures are isolate-wide.
///
/// The host installs an adapter with [instrumentTelemetry]; every pool and
/// session in the isolate then reports through it. The adapter's contract
/// is [MontyTelemetry]: the context and span tokens it hands back, the
/// spans it opens and ends, the logs it emits, the measurements it records
/// and the context it runs a host callback in.
library;

import 'dart:async';

import 'package:dart_monty_core/src/worker/telemetry_metrics.dart';

part 'monty_telemetry.dart';
part 'telemetry_bridge.dart';
part 'invocation.dart';

final class _Telemetry {
  TelemetryBridge? bridge;
}

/// Installs [telemetry] for this isolate's lifetime: every pool and session
/// in this isolate reports through it. Cannot be undone.
///
/// A second call throws [StateError]. With no adapter, no records are made
/// and snapshot trace contexts are null (D-087). Browser sessions record
/// the same signals as native sessions (D-090).
///
/// An adapter that throws disables the signal it failed in — spans, logs or
/// metrics — for the rest of the isolate, and the failure is reported once
/// through the zone [instrumentTelemetry] was called in.
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
