part of 'telemetry_values.dart';

Rendered _json(void Function(_TelemetryJson) encode) {
  final writer = _TelemetryJson();
  try {
    encode(writer);
  } on _JsonLimit {
    return (value: writer.buffer.toString(), cut: true);
  }

  return (value: writer.buffer.toString(), cut: false);
}

/// Matches serde's whole-write cap, including partial invalid JSON on a cut.
final class _TelemetryJson {
  final buffer = StringBuffer();
  int _bytes = 0;

  void write(String text) {
    // A UTF-16 length above the remaining byte limit cannot fit in UTF-8.
    final remaining = telemetryAttributeLimit - _bytes;
    if (text.length > remaining) throw _JsonLimit.exceeded;
    final length = utf8.encode(text).length;
    if (length > remaining) throw _JsonLimit.exceeded;
    _bytes += length;
    buffer.write(text);
  }

  void string(String text) {
    write('"');
    var start = 0;
    for (var i = 0; i < text.length; i++) {
      final unit = text.codeUnitAt(i);
      if (unit >= 32 && unit != 34 && unit != 92) continue;
      if (i > start) _slice(text, start, i);
      final escaped = jsonEncode(String.fromCharCode(unit));
      write(escaped.substring(1, escaped.length - 1));
      start = i + 1;
    }
    if (start < text.length) _slice(text, start, text.length);
    write('"');
  }

  void scalar(Object? value) {
    if (value is String) {
      string(value);
    } else {
      write('$value');
    }
  }

  void sequence(Iterable<void Function()> items) {
    write('[');
    var first = true;
    for (final item in items) {
      if (!first) write(',');
      first = false;
      item();
    }
    write(']');
  }

  void object(Iterable<(String, void Function())> entries) {
    write('{');
    var first = true;
    for (final (key, value) in entries) {
      if (!first) write(',');
      first = false;
      string(key);
      write(':');
      value();
    }
    write('}');
  }

  void _slice(String text, int start, int end) {
    if (end - start > telemetryAttributeLimit - _bytes) {
      throw _JsonLimit.exceeded;
    }
    write(text.substring(start, end));
  }
}

final class _ArenaJson {
  const _ArenaJson(this.nodes, this.writer);
  final List<pb.MontyNode> nodes;
  final _TelemetryJson writer;

  void node(int id, [int holder = 0x100000000, int depth = 0]) {
    final value = id < holder ? nodes.elementAtOrNull(id) : null;
    if (value == null) return writer.string('<invalid>');
    if (depth > 64) return writer.string('<too deep>');
    final children = _children(value);
    if (children != null) return sequence(children, id, depth + 1);
    _value(value, id, depth);
  }

  void sequence(Iterable<int> ids, [int holder = 0x100000000, int depth = 0]) =>
      writer.sequence(
        ids.map(
          (id) =>
              () => node(id, holder, depth),
        ),
      );

  void pairs(
    Iterable<pb.NodePair> entries, [
    int holder = 0x100000000,
    int depth = 0,
  ]) => writer.object(
    entries.map(
      (entry) => (
        _key(entry.key, holder, depth),
        () => node(entry.value, holder, depth),
      ),
    ),
  );

  void instance(pb.ClassInstanceNode value, int holder, int depth) {
    final classId = value.classType;
    final type = classId < holder ? nodes.elementAtOrNull(classId) : null;
    writer.object([
      (
        'type',
        () {
          if (type != null &&
              type.whichKind() == pb.MontyNode_Kind.type &&
              type.type.origin != originBuiltin) {
            classType(type.type, classId, depth + 1);
          } else {
            writer.string('<invalid>');
          }
        },
      ),
      ('id', () => writer.string(uuidString(value.instanceId.data))),
      ('attrs', () => pairs(value.attrs.pairs, holder, depth)),
    ]);
  }

  void classType(pb.Type type, int holder, int depth) => writer.object([
    ('name', () => writer.string(type.name)),
    ('id', () => writer.string(uuidString(type.id.data))),
    ('host_defined', () => writer.scalar(type.origin == originHost)),
    ('is_dataclass', () => writer.scalar(type.isDataclass)),
    ('attrs', () => pairs(type.attrs.pairs, holder, depth)),
  ]);

  void _value(pb.MontyNode value, int id, int depth) {
    switch (value.whichKind()) {
      case pb.MontyNode_Kind.dict:
        pairs(value.dict.pairs, id, depth + 1);
      case pb.MontyNode_Kind.classInstance:
        instance(value.classInstance, id, depth + 1);
      case pb.MontyNode_Kind.type when value.type.origin != originBuiltin:
        classType(value.type, id, depth + 1);
      case pb.MontyNode_Kind.float:
        _float(value);
      case pb.MontyNode_Kind.timedelta:
        _duration(value.timedelta);
      case pb.MontyNode_Kind.bigint:
        _bigint(value);
      case _:
        writer.scalar(_leaf(value));
    }
  }

  void _float(pb.MontyNode value) {
    final number = floatOfNode(value);
    if (number.isFinite) {
      writer.write(_serdeFloat(number));
    } else {
      writer.string(_finite(number) as String);
    }
  }

  void _duration(pb.TimeDelta delta) {
    final seconds =
        delta.days * 86400.0 + delta.seconds + delta.microseconds / 1e6;
    writer.write(_serdeFloat(seconds));
  }

  void _bigint(pb.MontyNode value) {
    final integer = bigIntOfNode(value.bigint);
    if (integer >= -(BigInt.one << 127) && integer < BigInt.one << 127) {
      writer.write('$integer');
    } else {
      writer.string('$integer');
    }
  }

  String _key(int id, int holder, int depth) {
    final key = id < holder ? nodes.elementAtOrNull(id) : null;
    if (key != null && key.whichKind() == pb.MontyNode_Kind.str) {
      return key.str;
    }
    final encoded = _json(
      (sink) => _ArenaJson(nodes, sink).node(id, holder, depth),
    );
    if (encoded.cut) throw _JsonLimit.exceeded;

    return encoded.value as String;
  }
}

Iterable<int>? _children(pb.MontyNode value) => switch (value.whichKind()) {
  pb.MontyNode_Kind.list => value.list.items,
  pb.MontyNode_Kind.tuple => value.tuple.items,
  pb.MontyNode_Kind.set => value.set.items,
  pb.MontyNode_Kind.frozenSet => value.frozenSet.items,
  pb.MontyNode_Kind.namedTuple => value.namedTuple.values,
  _ => null,
};

Object? _leaf(pb.MontyNode node) => switch (node.whichKind()) {
  pb.MontyNode_Kind.none => null,
  pb.MontyNode_Kind.boolean => node.boolean,
  pb.MontyNode_Kind.int_5 => intOfNode(node),
  pb.MontyNode_Kind.str => node.str,
  pb.MontyNode_Kind.bytes => _bytesContent(
    node.bytes.take(telemetryAttributeLimit).toList(),
  ),
  _ => _temporalLeaf(node),
};

Object? _temporalLeaf(pb.MontyNode node) => switch (node.whichKind()) {
  pb.MontyNode_Kind.date => _date(
    node.date.year,
    node.date.month,
    node.date.day,
  ),
  pb.MontyNode_Kind.time => _time(node.time),
  pb.MontyNode_Kind.datetime => _datetime(node.datetime),
  pb.MontyNode_Kind.timezone => _timezone(node.timezone),
  _ => _displayLeaf(node),
};

Object? _displayLeaf(pb.MontyNode node) => switch (node.whichKind()) {
  pb.MontyNode_Kind.exception => node.exception.arg,
  pb.MontyNode_Kind.path => node.path,
  pb.MontyNode_Kind.cycle => '<circular reference>',
  pb.MontyNode_Kind.repr => node.repr,
  pb.MontyNode_Kind.ellipsis => 'Ellipsis',
  pb.MontyNode_Kind.notImplemented => 'NotImplemented',
  _ => _objectLeaf(node),
};

Object? _objectLeaf(pb.MontyNode node) => switch (node.whichKind()) {
  pb.MontyNode_Kind.builtinFunction =>
    '<built-in function ${node.builtinFunction}>',
  pb.MontyNode_Kind.function => "<function '${node.function.name}' external>",
  pb.MontyNode_Kind.type => "<class '${node.type.name}'>",
  pb.MontyNode_Kind.complex => _complex(node.complex),
  pb.MontyNode_Kind.fileHandle => _file(node.fileHandle),
  _ => '<invalid>',
};

String _pad(int n, [int width = 2]) => n.toString().padLeft(width, '0');
String _date(int y, int m, int d) => '${_pad(y, 4)}-${_pad(m)}-${_pad(d)}';
String _time(pb.Time time) =>
    '${_pad(time.hour)}:${_pad(time.minute)}:${_pad(time.second)}'
    '${time.microsecond == 0 ? '' : '.${_pad(time.microsecond, 6)}'}'
    '${time.hasOffsetSeconds() ? _offset(time.offsetSeconds) : ''}';
String _datetime(pb.DateTime dt) {
  final clock = pb.Time(
    hour: dt.hour,
    minute: dt.minute,
    second: dt.second,
    microsecond: dt.microsecond,
    offsetSeconds: dt.hasOffsetSeconds() ? dt.offsetSeconds : null,
  );

  return '${_date(dt.year, dt.month, dt.day)}T${_time(clock)}';
}

String _offset(int seconds) {
  final absolute = seconds.abs();
  final sign = seconds < 0 ? '-' : '+';
  final hours = _pad(absolute ~/ 3600);
  final minutes = _pad(absolute % 3600 ~/ 60);
  final tail = absolute % 60 == 0 ? '' : ':${_pad(absolute % 60)}';

  return '$sign$hours:$minutes$tail';
}

enum _JsonLimit implements Exception { exceeded }
