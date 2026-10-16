/// Host telemetry bridge. Installation and failures are isolate-wide.
library;

import 'dart:async';

part 'telemetry_bridge.dart';
part 'invocation.dart';

final class _Telemetry {
  TelemetryBridge? bridge;
}

/// Receives Monty's records for the host's own telemetry SDK.
///
/// Monty owns no exporter, provider or credentials. Attribute values are
/// strings, integers, doubles or booleans. Delivery is synchronous; there
/// is nothing for Monty to flush. Each failing signal is disabled for the
/// rest of this isolate and reported once through the installation zone.
abstract interface class MontyTelemetry {
  /// The host's current context; null means no parent.
  Object? currentContext();

  /// [context] with [span] as its current span.
  Object? contextWithSpan(Object? context, Object span);

  /// Starts [name] under [parent] at explicit Unix-epoch nanoseconds.
  /// An adapter ignoring spans returns any token and ignores it thereafter.
  Object startSpan(
    String name,
    Object? parent,
    Map<String, Object> attributes, {
    required BigInt startTimeUnixNanos,
  });

  /// Adds [attributes] and ends [span] at explicit Unix-epoch nanoseconds.
  void endSpan(
    Object span,
    Map<String, Object> attributes, {
    required BigInt endTimeUnixNanos,
  });

  /// Emits a log under [span], null when no span is open or spans failed.
  /// [severity] is INFO (9) or ERROR (17); the timestamp is epoch nanoseconds.
  void emitLog(
    Object? span,
    String severity,
    String body,
    Map<String, Object> attributes, {
    required BigInt timestampUnixNanos,
    required int severityNumber,
  });

  /// Records a raw measurement; [context] is explicitly empty (null).
  /// The adapter must use its SDK's empty context, not the ambient span.
  void recordMetric(
    String name,
    String kind,
    String unit,
    String description,
    num value,
    Map<String, Object> attributes, {
    required Object? context,
  });

  /// Runs [body] with [context] current, including asynchronous continuations.
  R runInContext<R>(Object? context, R Function() body);
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
}

/// Internal installation, shared by all recorders and the metric boundary.
TelemetryBridge? get telemetryBridge => _installation.bridge;

final _installation = _Telemetry();
