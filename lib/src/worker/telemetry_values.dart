/// Upstream tracing_json.rs: bounded, tolerant rendering directly from arenas.
library;

import 'dart:convert';

import 'package:dart_monty_core/src/platform/double_text.dart';
import 'package:dart_monty_core/src/worker/arena_nodes.dart'
    show originBuiltin, originHost;
import 'package:dart_monty_core/src/worker/arena_nodes.dart' show uuidString;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/python_rules.dart'
    show parseFileMode, pythonRepr;
import 'package:dart_monty_core/src/worker/wire_scalars.dart';

part 'telemetry_json.dart';
part 'telemetry_repr.dart';

/// Upstream's per-attribute UTF-8 byte limit.
const int telemetryAttributeLimit = 64 * 1024;

/// Value and whether any rendering was truncated.
typedef Rendered = ({Object value, bool cut});

/// Caps raw text on a UTF-8 boundary without copying its unbounded suffix.
Rendered telemetryText(String text) => _text(text, telemetryAttributeLimit);

Rendered _text(String text, int limit) {
  var bytes = 0;
  var units = 0;
  for (final rune in text.runes) {
    final width = rune <= 0x7f
        ? 1
        : rune <= 0x7ff
        ? 2
        : rune <= 0xffff
        ? 3
        : 4;
    if (bytes + width > limit) {
      return (value: text.substring(0, units), cut: true);
    }
    bytes += width;
    units += rune > 0xffff ? 2 : 1;
  }
  return (value: text, cut: false);
}

/// Scalars keep their OTel types; compound values are bounded JSON text.
Rendered telemetryValue(pb.Arena arena, int id) {
  final node = arena.nodes.elementAtOrNull(id);
  if (node == null) return (value: '<missing>', cut: false);
  return switch (node.whichKind()) {
    pb.MontyNode_Kind.boolean => (value: node.boolean, cut: false),
    pb.MontyNode_Kind.int_5 => (value: intOfNode(node).toInt(), cut: false),
    pb.MontyNode_Kind.float => (value: _finite(floatOfNode(node)), cut: false),
    pb.MontyNode_Kind.str => telemetryText(node.str),
    pb.MontyNode_Kind.bytes => telemetryBytes(node.bytes),
    _ => _json((writer) => _ArenaJson(arena.nodes, writer).node(id)),
  };
}

/// Python bytes repr content, without b and quotes, as Logfire records it.
Rendered telemetryBytes(List<int> bytes) {
  final head = bytes.take(telemetryAttributeLimit).toList();
  final rendered = telemetryText(_bytesContent(head));
  return (
    value: rendered.value,
    cut: rendered.cut || head.length < bytes.length,
  );
}

Object _finite(double value) => value.isFinite
    ? value
    : value.isNaN
    ? 'nan'
    : value > 0
    ? 'inf'
    : '-inf';

/// Root references as a JSON sequence.
Rendered telemetrySequence(pb.Arena arena, Iterable<int> ids) =>
    _json((writer) => _ArenaJson(arena.nodes, writer).sequence(ids));

/// Root references as a JSON dict, including non-string keys.
Rendered telemetryPairs(pb.Arena arena, Iterable<pb.NodePair> pairs) =>
    _json((writer) => _ArenaJson(arena.nodes, writer).pairs(pairs));

/// Named feed inputs as a JSON object.
Rendered telemetryInputs(pb.Feed feed) => _json((writer) {
  final arena = _ArenaJson(feed.values.nodes, writer);
  writer.object(
    feed.inputs.map((input) => (input.name, () => arena.node(input.value))),
  );
});

/// A bounded JSON list of requirements or call ids.
Rendered telemetryList(Iterable<Object> values) => _json(
  (writer) => writer.sequence(
    values.map(
      (value) =>
          () => writer.scalar(value),
    ),
  ),
);

/// Host results are typed values, or upstream's descriptive text.
Rendered telemetryResult(pb.ExtFunctionResult result, pb.Arena arena) =>
    switch (result.whichKind()) {
      pb.ExtFunctionResult_Kind.returnValue => telemetryValue(
        arena,
        result.returnValue,
      ),
      pb.ExtFunctionResult_Kind.error => telemetryRaised(result.error),
      pb.ExtFunctionResult_Kind.future => (
        value: 'future ${result.future}',
        cut: false,
      ),
      pb.ExtFunctionResult_Kind.notFound => telemetryText(
        'not found: ${result.notFound}',
      ),
      pb.ExtFunctionResult_Kind.notHandled => (
        value: 'not handled',
        cut: false,
      ),
      pb.ExtFunctionResult_Kind.notSet => (value: '<missing>', cut: false),
    };

/// Host-raised exception text.
Rendered telemetryRaised(pb.RaisedException error) => telemetryJoined([
  'raise ',
  error.excType,
  if (error.hasMessage()) ...[': ', error.message],
]);

/// Capped formatted text, without materializing unbounded intermediate strings.
Rendered telemetryJoined(Iterable<String> parts) {
  final output = StringBuffer();
  var remaining = telemetryAttributeLimit;
  for (final part in parts) {
    final rendered = _text(part, remaining);
    final text = rendered.value as String;
    output.write(text);
    if (rendered.cut) return (value: output.toString(), cut: true);
    remaining -= utf8.encode(text).length;
  }
  return (value: output.toString(), cut: false);
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
