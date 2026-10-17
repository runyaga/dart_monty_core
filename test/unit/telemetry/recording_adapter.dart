// Expected records follow upstream 1.1.0 tracing.rs and the R contracts.
import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// In-memory adapter with independently injectable signal failures.
class RecordingAdapter implements MontyTelemetry {
  /// Records all calls, optionally failing [failure].
  RecordingAdapter({this.failure});

  /// Signal or context operation to fail.
  String? failure;

  /// Emulates an installed adapter with only logs or metrics enabled.
  bool ignoreSpans = false;

  /// Started spans, including their eventual attributes and end time.
  final spans = <RecordedSpan>[];

  /// Log records, retaining explicit bridge fields.
  final logs =
      <
        ({
          Object? span,
          String body,
          String severity,
          int number,
          BigInt time,
          Map<String, Object> attributes,
        })
      >[];

  /// Measurements received at the adapter boundary.
  final metrics = <num>[];

  /// Full raw measurements, before any SDK aggregation.
  final measurements = <MetricRecord>[];

  /// Callback contexts, observed independently of the span tree.
  final contexts = <Object?>[];

  /// Span tokens supplied while deriving callback contexts.
  final contextSpans = <Object>[];

  /// Span tokens supplied for completion.
  final endedSpans = <Object>[];

  /// Separate counts expose attempts after a signal was disabled.
  final attempts = <String, int>{};

  /// Adapter methods invoked by the bridge, in delivery order.
  final methods = <String>[];

  /// Clears records, preserving installation and failure state.
  void clear() {
    spans.clear();
    logs.clear();
    metrics.clear();
    measurements.clear();
    contexts.clear();
    contextSpans.clear();
    endedSpans.clear();
    attempts.clear();
    methods.clear();
  }

  @override
  Object? currentContext() {
    methods.add('currentContext');
    _check('currentContext');

    return Zone.current[#telemetryContext];
  }

  @override
  Object? contextWithSpan(Object? context, Object span) {
    methods.add('contextWithSpan');
    _check('contextWithSpan');
    contextSpans.add(span);

    return ignoreSpans ? context : (context, span);
  }

  @override
  Object startSpan(
    String name,
    Object? parent,
    Map<String, Object> attributes, {
    required BigInt startTimeUnixNanos,
  }) {
    methods.add('startSpan');
    _check('spans');
    if (ignoreSpans) return const Object();
    final span = RecordedSpan(
      name,
      parent,
      Map.of(attributes),
      startTimeUnixNanos,
    );
    spans.add(span);

    return span;
  }

  @override
  void endSpan(
    Object span,
    Map<String, Object> attributes, {
    required BigInt endTimeUnixNanos,
  }) {
    methods.add('endSpan');
    _check('endSpan');
    endedSpans.add(span);
    if (ignoreSpans) return;
    final record = span as RecordedSpan;
    record.attributes.addAll(attributes);
    record.end = endTimeUnixNanos;
  }

  @override
  void emitLog(
    Object? span,
    String severity,
    String body,
    Map<String, Object> attributes, {
    required BigInt timestampUnixNanos,
    required int severityNumber,
  }) {
    methods.add('emitLog');
    _check('logs');
    logs.add((
      span: span,
      body: body,
      severity: severity,
      number: severityNumber,
      time: timestampUnixNanos,
      attributes: Map.of(attributes),
    ));
  }

  @override
  void recordMetric(
    String name,
    String kind,
    String unit,
    String description,
    num value,
    Map<String, Object> attributes, {
    required Object? context,
  }) {
    methods.add('recordMetric');
    _check('metrics');
    metrics.add(value);
    measurements.add((
      name: name,
      kind: kind,
      unit: unit,
      description: description,
      value: value,
      attributes: Map.of(attributes),
      context: context,
    ));
  }

  @override
  R runInContext<R>(Object? context, R Function() body) {
    methods.add('runInContext');
    _check('beforeCallback');
    contexts.add(context);
    try {
      return runZoned(body, zoneValues: {#telemetryContext: context});
    } finally {
      _check('afterCallback');
    }
  }

  void _check(String signal) {
    attempts.update(signal, (n) => n + 1, ifAbsent: () => 1);
    if (failure == signal) throw StateError('adapter-$signal');
  }
}

/// A span handle and its immutable creation record.
final class RecordedSpan {
  /// Starts an in-memory span.
  RecordedSpan(this.name, this.parent, this.attributes, this.start);

  /// Template name from upstream.
  final String name;

  /// Explicit parent context.
  final Object? parent;

  /// Attributes at start plus those supplied at end.
  final Map<String, Object> attributes;

  /// Explicit epoch nanoseconds.
  final BigInt start;

  /// Explicit end, absent until closed.
  BigInt? end;
}

/// Requires a record before assertions inspect its fields.
T requireRecord<T>(T? value) {
  if (value == null) fail('Expected a recorded value');

  return value;
}

/// Requires the context shape supplied by RecordingAdapter.
(Object?, Object) recordedContext(Object? value) {
  if (value is! (Object?, Object)) fail('Expected a recorded span context');

  return value;
}

/// Raw SDK boundary, including the deliberately empty metric context.
typedef MetricRecord = ({
  String name,
  String kind,
  String unit,
  String description,
  num value,
  Map<String, Object> attributes,
  Object? context,
});

/// Selects one instrument without discarding its raw increments.
List<MetricRecord> measurements(RecordingAdapter adapter, String suffix) =>
    adapter.measurements.where((m) => m.name == 'monty.$suffix').toList();
