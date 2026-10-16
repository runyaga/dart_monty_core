/// Attribute encodings from upstream 1.1.0 tracing.rs (not protobuf JSON).
library;

import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry_scalars.dart';
import 'package:dart_monty_core/src/worker/telemetry_values.dart';
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart' show GeneratedMessage;

/// Configuration's unsigned values deliberately retain their debug strings.
TelemetryAttributes configureAttributes(pb.Configure configure, int? pid) {
  final attributes =
      TelemetryAttributes({
          'type_check': configure.typeCheck,
          'assert_message_annotations': '${configure.assertMessageAnnotations}',
          'worker_pid': ?pid,
        })
        ..text('script_name', configure.scriptName)
        ..text('monty_version', configure.montyVersion);
  if (configure.hasTypeCheckStubs()) {
    attributes.text('type_check_stubs', configure.typeCheckStubs);
  }
  final limits = configure.limits;
  final fields = {
    'max_feed_duration_micros': limits.hasMaxFeedDurationMicros()
        ? limits.maxFeedDurationMicros
        : null,
    'max_turn_duration_micros': limits.hasMaxTurnDurationMicros()
        ? limits.maxTurnDurationMicros
        : null,
    'max_memory_bytes': limits.hasMaxMemoryBytes()
        ? limits.maxMemoryBytes
        : null,
    'gc_interval': limits.hasGcInterval() ? limits.gcInterval : null,
    'max_recursion_depth': limits.hasMaxRecursionDepth()
        ? limits.maxRecursionDepth
        : null,
    'max_suspensions': limits.hasMaxSuspensions()
        ? limits.maxSuspensions
        : null,
  };
  for (final MapEntry(:key, :value) in fields.entries) {
    if (value != null) attributes.values[key] = value.toStringUnsigned();
  }

  return attributes;
}

/// Execution spans retain Python language metadata, per D-089.
TelemetryAttributes feedAttributes(pb.Feed feed) {
  final attributes = TelemetryAttributes({
    'code.language': 'python',
    'sandbox.execution.code.attribute': 'code',
    'sandbox.execution.language': 'python',
    'skip_type_check': feed.skipTypeCheck,
  })..text('code', feed.code);
  if (feed.inputs.isNotEmpty) attributes.add('inputs', telemetryInputs(feed));

  return attributes;
}

/// Span creation uses unsigned debug strings; logs and span.record use i64.
TelemetryAttributes eventTiming(pb.ChildEvent event, {bool signed = false}) {
  Object value(Int64 micros) =>
      signed ? _signedCount(micros) : micros.toStringUnsigned();

  return TelemetryAttributes({
    'total_execution_micros': value(event.totalExecutionMicros),
    if (event.hasMaxFeedDurationMicros())
      'max_feed_duration_micros': value(event.maxFeedDurationMicros),
  });
}

Object _signedCount(Int64 value) => telemetryInteger(
  BigInt.parse('${value.isNegative ? Int64.MAX_VALUE : value}'),
);

/// OS function names are the wire's snake-case names, not Python aliases.
void osAttributes(pb.OsCall call, TelemetryAttributes attributes) {
  final kind = call.whichCall();
  attributes.values['call_id'] = '${call.callId}';
  attributes.position(call.hasPosition() ? call.position : null);
  attributes.values['function'] = kind == pb.OsCall_Call.notSet
      ? '<missing>'
      : _snake(kind.name);
  if (kind == pb.OsCall_Call.notSet) return;
  // The oneof's fields occupy tags 2 through 30, in enum order.
  final value = call.getField(kind.index + 2);
  if (value is String) {
    attributes.text('args.path', value);
  } else if (kind == pb.OsCall_Call.getenv) {
    final getenv = call.getenv;
    attributes.text('args.key', getenv.key);
    final rendered = telemetryValue(call.values, getenv.default_2);
    attributes.add('args.default', (
      value: telemetryScalarText(rendered.value),
      cut: rendered.cut,
    ));
  } else if (kind == pb.OsCall_Call.dateTimeNow) {
    final now = call.dateTimeNow;
    if (!now.hasTz()) return;
    attributes.values['args.tz_offset_seconds'] = now.tz.offsetSeconds;
    if (now.tz.hasName()) attributes.text('args.tz_name', now.tz.name);
  } else if (value is GeneratedMessage) {
    _osFields(value, attributes);
  }
}

void _osFields(GeneratedMessage message, TelemetryAttributes attributes) {
  for (final field in message.info_.fieldInfo.values) {
    final value = message.getField(field.tagNumber);
    final key = 'args.${_snake(field.name)}';
    switch (value) {
      case String():
        attributes.text(key, value);
      case List<int>():
        attributes.add(key, telemetryBytes(value));
      case Int64():
        attributes.values[key] = value.toStringUnsigned();
      case bool() || int() || double():
        attributes.values[key] = value as Object;
      case _:
        break;
    }
  }
}

String _snake(String name) => name.replaceAllMapped(
  RegExp('[A-Z]'),
  (m) => '_${m.group(0)?.toLowerCase() ?? ''}',
);

/// Error records keep traceback and structured exception payloads.
TelemetryAttributes errorAttributes(pb.ChildEvent event) {
  final error = event.error;
  final exception = error.exception;
  final attributes = eventTiming(event, signed: true)
    ..text('exc_type', error.hasException() ? exception.excType : '<missing>');
  if (exception.hasMessage()) attributes.text('exc_message', exception.message);
  if (exception.traceback.isNotEmpty) {
    attributes.add(
      'traceback',
      telemetryJoined(_traceback(exception.traceback)),
    );
  }
  _exceptionData(exception.data, attributes);

  return attributes;
}

Iterable<String> _traceback(List<pb.StackFrame> frames) sync* {
  var first = true;
  for (final frame in frames) {
    if (!first) yield '\n';
    first = false;
    yield frame.filename;
    yield ':${frame.start.line} in ';
    yield frame.hasFrameName() ? frame.frameName : '<module>';
  }
}

void _exceptionData(pb.ExcData data, TelemetryAttributes attributes) {
  switch (data.whichKind()) {
    case pb.ExcData_Kind.unicode:
      final unicode = data.unicode;
      attributes
        ..text('exc_data.encoding', unicode.encoding)
        ..text('exc_data.reason', unicode.reason);
      attributes.values['exc_data.start'] = unicode.start.toStringUnsigned();
      attributes.values['exc_data.end'] = unicode.end.toStringUnsigned();
      attributes.add('exc_data.object', switch (unicode.whichObject()) {
        pb.UnicodeErrorData_Object.objectBytes => telemetryBytes(
          unicode.objectBytes,
        ),
        pb.UnicodeErrorData_Object.objectStr => telemetryText(
          unicode.objectStr,
        ),
        pb.UnicodeErrorData_Object.notSet => (value: '<missing>', cut: false),
      });
    case pb.ExcData_Kind.json:
      final json = data.json;
      attributes.text('exc_data.msg', json.msg);
      if (json.hasDoc()) attributes.text('exc_data.doc', json.doc);
      if (json.hasPos()) {
        attributes.values['exc_data.pos'] = json.pos.toStringUnsigned();
      }
      if (json.hasLineno()) {
        attributes.values['exc_data.lineno'] = json.lineno.toStringUnsigned();
      }
      if (json.hasColno()) {
        attributes.values['exc_data.colno'] = json.colno.toStringUnsigned();
      }
    case pb.ExcData_Kind.notSet:
      break;
  }
}

/// An attribute builder that propagates truncation exactly once.
final class TelemetryAttributes {
  /// Starts with the scalar attributes whose encodings need no rendering.
  TelemetryAttributes([Map<String, Object> initial = const {}])
    : values = Map.of(initial);

  /// Completed attributes (only scalar OTel types).
  final Map<String, Object> values;

  /// Adds a rendered value and its cap flag.
  void add(String key, Rendered value) {
    values[key] = value.value;
    if (value.cut) values['length_limit_exceeded'] = true;
  }

  /// Adds capped raw text.
  void text(String key, String value) => add(key, telemetryText(value));

  /// Adds source offsets as signed integers, not unsigned debug strings.
  void position(pb.SourceRange? range) {
    if (range == null) return;
    text('sandbox.code.file.path', range.filename);
    values['sandbox.code.offset.start'] = range.start;
    values['sandbox.code.offset.end'] = range.end;
  }
}
