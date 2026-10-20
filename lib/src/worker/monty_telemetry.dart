part of 'telemetry.dart';

/// Receives Monty's records for the host's own telemetry SDK.
///
/// Monty owns no exporter, provider or credentials. Attribute values are
/// strings, integers, doubles or booleans. Delivery is synchronous; there
/// is nothing for Monty to flush. Each failing signal is disabled for the
/// rest of this isolate and reported once through the installation zone.
///
/// The context and the span are the adapter's own tokens: Monty only hands
/// them back. [currentContext] gives the parent of a session's spans,
/// [startSpan] opens a span under a parent and returns its token, and
/// [endSpan] and [emitLog] take that token again. An adapter ignoring
/// spans returns any token and ignores it thereafter.
///
/// The three signals fail apart: a span that fails leaves the logs and the
/// metrics working, and the other way about.
///
/// ```dart
/// class PrintingTelemetry implements MontyTelemetry {
///   @override
///   Object? currentContext() => null;
///
///   @override
///   Object? contextWithSpan(Object? context, Object span) => context;
///
///   @override
///   Object startSpan(
///     String name,
///     Object? parent,
///     Map<String, Object> attributes, {
///     required BigInt startTimeUnixNanos,
///   }) => name;
///
///   @override
///   void endSpan(
///     Object span,
///     Map<String, Object> attributes, {
///     required BigInt endTimeUnixNanos,
///   }) {}
///
///   @override
///   void emitLog(
///     Object? span,
///     String severity,
///     String body,
///     Map<String, Object> attributes, {
///     required BigInt timestampUnixNanos,
///     required int severityNumber,
///   }) => print('[$severity] $body');
///
///   @override
///   void recordMetric(
///     String name,
///     String kind,
///     String unit,
///     String description,
///     num value,
///     Map<String, Object> attributes, {
///     required Object? context,
///   }) => print('$name: $value');
///
///   @override
///   R runInContext<R>(Object? context, R Function() body) => body();
/// }
///
/// void main() {
///   instrumentTelemetry(PrintingTelemetry());
/// }
/// ```
abstract interface class MontyTelemetry {
  /// The host's current context; null means no parent.
  ///
  /// It is the parent of the spans a session opens, captured when the
  /// session is checked out.
  Object? currentContext();

  /// [context] with [span] as its current span.
  ///
  /// The result is the context a host callback runs in, and the one a
  /// snapshot reports as its trace context.
  Object? contextWithSpan(Object? context, Object span);

  /// Starts [name] under [parent] at explicit Unix-epoch nanoseconds.
  /// An adapter ignoring spans returns any token and ignores it thereafter.
  ///
  /// The token is the span's handle: [endSpan] and [emitLog] take it again.
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
  ///
  /// The name, kind, unit and description are upstream's instrument names.
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

  /// Runs [body] with [context] current, including asynchronous continuations.
  ///
  /// The body runs once, whatever the adapter does: an adapter that does not
  /// call it has it run anyway.
  R runInContext<R>(Object? context, R Function() body);
}
