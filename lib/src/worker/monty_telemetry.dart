part of 'telemetry.dart';

/// Receives Monty's records for the host's telemetry SDK.
///
/// Attribute values are strings, integers, doubles, or booleans. Delivery is
/// synchronous, so Monty has nothing to flush.
abstract interface class MontyTelemetry {
  /// Returns the current parent context.
  Object? currentContext();

  /// Returns a context with the supplied span current.
  Object? contextWithSpan(Object? context, Object span);

  /// Starts a span at a Unix-epoch nanosecond time and returns the adapter's
  /// token. An adapter that ignores spans may return any token and ignore it.
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

  /// Emits one log record at a Unix-epoch nanosecond timestamp.
  ///
  /// [severity] is `INFO` with number 9 or `ERROR` with number 17. [span] is
  /// null when no span is open or the span signal has failed.
  void emitLog(
    Object? span,
    String severity,
    String body,
    Map<String, Object> attributes, {
    required BigInt timestampUnixNanos,
    required int severityNumber,
  });

  /// Records one metric measurement with an explicitly empty context.
  ///
  /// The adapter must use its SDK's empty context instead of the ambient span.
  // The approved adapter shape mirrors upstream's metric record (name, kind,
  // unit, description, value, attributes, context); bundling would add a
  // public type the surface delta does not allow.
  // ignore: number-of-parameters
  void recordMetric(
    String name,
    String kind,
    String unit,
    String description,
    num value,
    Map<String, Object> attributes, {
    required Object? context,
  });

  /// Runs a body with the supplied context current for its continuations.
  ///
  /// The body runs exactly once even if the adapter omits it or throws.
  R runInContext<R>(Object? context, R Function() body);
}
