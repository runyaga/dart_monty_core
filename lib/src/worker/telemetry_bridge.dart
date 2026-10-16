part of 'telemetry.dart';

/// Isolates failures by signal and reports independently of the adapter.
final class TelemetryBridge {
  /// Captures the diagnostic zone at installation.
  TelemetryBridge(this._adapter, this._zone);

  final MontyTelemetry _adapter;
  final Zone _zone;
  final Set<String> _disabled = {};

  /// Whether contexts and spans can still be used.
  bool get spansEnabled => !_disabled.contains('spans');

  /// Captures ambient context, or null after a context failure.
  Object? currentContext() => _try('spans', _adapter.currentContext);

  /// Adds an open span to a captured context; disabled spans leave it alone.
  Object? contextWithSpan(Object? context, Object? span) {
    if (span == null || !spansEnabled) return context;
    final result = _try('spans', () => _adapter.contextWithSpan(context, span));

    return spansEnabled ? result : context;
  }

  /// Opens a span; timestamps belong to the recording operation.
  Object? start(String name, Object? parent, Map<String, Object> attributes) {
    final time = _now();

    return _try(
      'spans',
      () => _adapter.startSpan(
        name,
        parent,
        attributes,
        startTimeUnixNanos: time,
      ),
    );
  }

  /// Ends a previously opened span, unless that signal failed.
  void end(Object? span, Map<String, Object> attributes) {
    if (span == null) return;
    final time = _now();
    _try(
      'spans',
      () => _adapter.endSpan(span, attributes, endTimeUnixNanos: time),
    );
  }

  /// Logs keep working when the tracer fails, with an empty span context.
  void log(
    Object? span,
    String severity,
    String body,
    Map<String, Object> attributes,
  ) {
    final time = _now();
    _try(
      'logs',
      () => _adapter.emitLog(
        spansEnabled ? span : null,
        severity,
        body,
        attributes,
        timestampUnixNanos: time,
        severityNumber: severity == 'ERROR' ? 17 : 9,
      ),
    );
  }

  /// Raw metric boundary; R-3 supplies the pool's positive measurements.
  void recordMetric(
    String name,
    String kind,
    String unit,
    String description,
    num value,
    Map<String, Object> attributes,
  ) {
    _try(
      'metrics',
      () => _adapter.recordMetric(
        name,
        kind,
        unit,
        description,
        value,
        attributes,
        context: null,
      ),
    );
  }

  /// Never retries a callback or replaces its result with an adapter error.
  R invoke<R>(Object? context, R Function() body) {
    if (!spansEnabled) return body();
    final call = _Invocation(body);
    try {
      _adapter.runInContext(context, call.run);
    } on Object catch (error, stack) {
      if (!identical(error, call.error)) _fail('spans', error, stack);
    }

    return call.entered ? call.result() : call.run();
  }

  T? _try<T>(String signal, T? Function() body) {
    if (_disabled.contains(signal)) return null;
    try {
      return body();
    } on Object catch (error, stack) {
      _fail(signal, error, stack);

      return null;
    }
  }

  void _fail(String signal, Object error, StackTrace stack) {
    if (!_disabled.add(signal)) return;
    try {
      _zone.print(
        'Monty telemetry $signal disabled '
        '(${_adapter.runtimeType}): $error\n$stack',
      );
    } on Object {
      // A diagnostic must never escape, recurse through logging or retry.
    }
  }
}

BigInt _now() =>
    BigInt.from(DateTime.now().microsecondsSinceEpoch) * BigInt.from(1000);
