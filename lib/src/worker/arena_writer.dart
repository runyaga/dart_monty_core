/// Values to the worker: [MontyValue] to a monty-proto `Arena`.
///
/// The writer emits nodes in post-order (every child before its holder) and
/// shares nodes exactly as upstream's Python encoder does
/// (monty-proto 1.1.0, `python/encode.rs`):
///
/// - a container (list, tuple, named tuple, dict, set, frozenset) or a class
///   instance is one node per Dart object, across every [ArenaWriter.add],
///   so an object passed in two places reaches Python as one object;
/// - a leaf (a scalar, a string, a date, an exception value, a file
///   handle) is a fresh node at each reference;
/// - the class of an instance is a node of its own, shared by class id while
///   the class has no attributes, and fresh otherwise.
///
/// It walks an explicit stack, so nesting depth is bounded by memory, not by
/// the Dart call stack.
///
/// It sends every kind the worker accepts as input except a host function,
/// whose node [functionNode] builds for the registry that owns callables.
/// Before emitting, it refuses with [ArgumentError] what upstream's encoder
/// or the worker's decoder would not accept, rather than letting protobuf
/// send something else: a cycle, a byte outside 0..255, a string with an
/// unpaired UTF-16 surrogate, a date, time or offset out of range, a
/// timedelta that is not normalized, an unknown exception, type or builtin
/// name, an invalid file mode or position, and a named tuple Python could not
/// build. Following upstream, an exception message with an unpaired surrogate
/// is converted lossily instead, and a time zone name with one is dropped.
///
/// [MontyDataclass] has no node (upstream folded it into the class
/// instance), and a [MontyOpaque] rendering of a function, `repr` or cycle
/// cannot be sent back; both throw [UnsupportedError] and [ArgumentError]
/// respectively.
///
/// Internal to the package; nothing here is exported.
library;

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_nodes.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/python_rules.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:fixnum/fixnum.dart';

/// The node for a host function the sandbox may call back, named [name].
pb.MontyNode functionNode(String name, {String? docstring}) => pb.MontyNode(
  function: pb.Function_(name: name, docstring: docstring),
);

/// Builds one arena from host values.
final class ArenaWriter {
  /// The arena built so far; put it in the message that carries the roots.
  final pb.Arena arena = pb.Arena();

  /// The node of each container already emitted.
  final Map<MontyValue, int> _containers = Map.identity();

  /// The node of each attribute-less class already emitted, by class id.
  final Map<String, int> _classes = {};

  /// Each key judged so far: the type Python cannot hash in it, or null.
  final Map<MontyValue, String?> _hashable = Map.identity();

  /// Adds [value] and returns its node index.
  ///
  /// Throws [ArgumentError] for a value upstream would refuse (see the
  /// library comment), including one that contains itself, and
  /// [UnsupportedError] for a [MontyDataclass]. A refused value may leave
  /// nodes for its children in [arena]; discard the writer.
  int add(MontyValue value) {
    final open = Set<MontyValue>.identity();
    final stack = <_Frame>[];
    var done = _step(value, open, stack);
    // `done` is null right after a frame was opened, so a frame is open.
    while (done == null || stack.isNotEmpty) {
      final frame = stack.removeLast();
      if (done != null) frame.ids.add(done);
      final next = frame.next;
      if (next != null) {
        stack.add(frame);
        done = _step(next, open, stack);
      } else {
        done = _complete(frame, open);
      }
    }

    return done;
  }

  /// Emits a leaf, finds an emitted container, or opens a frame for a
  /// container and returns null.
  int? _step(Object child, Set<MontyValue> open, List<_Frame> stack) {
    if (child is MontyClassType) return _enterClass(child, stack);
    final v = child as MontyValue;
    if (_containers[v] case final id?) return id;
    final container = _container(v);
    if (container == null) return _emit(_leaf(v));
    final (children, build) = container;
    if (!open.add(v)) {
      throw ArgumentError.value(
        v,
        'value',
        'contains itself; a cycle cannot be sent to the worker',
      );
    }
    if (v case MontyNamedTuple(:final typeName, :final fieldNames)) {
      _checkNamedTuple(v, typeName, fieldNames);
    }
    _checkHashable(v);
    stack.add(_Frame(v, children, build));

    return null;
  }

  /// An instance's class: one node per id while it has no attributes, as
  /// upstream's encoder keeps them; one per reference otherwise, since class
  /// metadata reached through an instance carries no identity of its own.
  int? _enterClass(MontyClassType type, List<_Frame> stack) {
    final shared = type.attrs.isEmpty ? _classes[_classKey(type)] : null;
    if (shared != null) return shared;
    stack.add(
      _Frame(type, _attrChildren(type.attrs), (ids) => _classNode(type, ids)),
    );

    return null;
  }

  /// A class's id as the uuid it names, whatever the hex digits' case.
  String _classKey(MontyClassType type) => type.id.toLowerCase();

  /// Refuses a dict, set or frozenset with a key or member Python could not
  /// hash, as Python's constructor would.
  void _checkHashable(MontyValue v) {
    final keys = switch (v) {
      MontyDict(:final pairs) => [for (final (k, _) in pairs) k],
      MontySet(:final items) || MontyFrozenSet(:final items) => items,
      _ => const <MontyValue>[],
    };
    for (final key in keys) {
      if (_unhashable(key) case final type?) {
        throw ArgumentError.value(
          v,
          'value',
          "TypeError: unhashable type: '$type'",
        );
      }
    }
  }

  /// The type of the first value in [key] Python cannot hash, or null.
  ///
  /// Tuples, named tuples and frozensets are hashable when their members
  /// are; each one is judged once per writer.
  String? _unhashable(MontyValue key) {
    // A value reached again through itself is a cycle, which add() refuses
    // on its own; here it is skipped.
    final visiting = Set<MontyValue>.identity();
    bool judged(MontyValue? m) =>
        m != null && (_hashable.containsKey(m) || visiting.contains(m));
    final stack = [if (!_hashable.containsKey(key)) key];
    final cursors = [0];
    for (var v = stack.lastOrNull; v != null; v = stack.lastOrNull) {
      final members = _hashMembers(v);
      var at = cursors.removeLast();
      while (judged(members.elementAtOrNull(at))) {
        at++;
      }
      final next = members.elementAtOrNull(at);
      if (next != null) {
        visiting.add(v);
        cursors.addAll([at, 0]);
        stack.add(next);
      } else {
        _hashable[v] =
            _unhashableType(v) ??
            members.map((m) => _hashable[m]).nonNulls.firstOrNull;
        visiting.remove(v);
        stack.removeLast();
      }
    }

    return _hashable[key];
  }

  int _complete(_Frame frame, Set<MontyValue> open) {
    final id = _emit(frame.build(frame.ids));
    switch (frame.source) {
      case final MontyClassType type when type.attrs.isEmpty:
        _classes.putIfAbsent(_classKey(type), () => id);
      case final MontyValue v:
        _containers[v] = id;
        open.remove(v);
    }

    return id;
  }

  pb.MontyNode _classNode(MontyClassType type, List<int> ids) {
    _checkText(type, type.name, 'class name');
    final node = pb.Type(
      name: _nzs(type.name),
      id: _uuid(type, type.id),
      origin: type.hostDefined ? originHost : originSandbox,
      isDataclass: type.isDataclass ? true : null,
    );
    if (ids.isNotEmpty) node.attrs = _pairs(ids);

    return pb.MontyNode(type: node);
  }

  int _emit(pb.MontyNode node) {
    arena.nodes.add(node);
    arena.nodeCount = arena.nodes.length;

    return arena.nodes.length - 1;
  }
}

/// A container or class being emitted: its children, and the nodes of those
/// emitted so far.
final class _Frame {
  _Frame(this.source, this.children, this.build);

  /// The container value, or a [MontyClassType].
  final Object source;

  /// [MontyValue]s and [MontyClassType]s, in emission order.
  final List<Object> children;
  final List<int> ids = [];

  /// The node, given the children's node indexes.
  final pb.MontyNode Function(List<int> ids) build;

  /// The child to emit next, or null when all are.
  Object? get next => children.elementAtOrNull(ids.length);
}

/// A container [v]'s children and how to build its node from their
/// indexes, or null for a leaf.
(List<Object>, pb.MontyNode Function(List<int>))? _container(MontyValue v) =>
    switch (v) {
      MontyList(:final items) => (
        items,
        (ids) => pb.MontyNode(list: pb.Indexes(items: ids)),
      ),
      MontyTuple(:final items) => (
        items,
        (ids) => pb.MontyNode(tuple: pb.Indexes(items: ids)),
      ),
      MontySet(:final items) => (
        items,
        (ids) => pb.MontyNode(set: pb.Indexes(items: ids)),
      ),
      MontyFrozenSet(:final items) => (
        items,
        (ids) => pb.MontyNode(frozenSet: pb.Indexes(items: ids)),
      ),
      MontyNamedTuple(:final typeName, :final fieldNames, :final values) => (
        values,
        (ids) => pb.MontyNode(
          namedTuple: pb.NamedTupleNode(
            typeName: typeName,
            fieldNames: fieldNames,
            values: ids,
          ),
        ),
      ),
      MontyDict(:final pairs) => (
        [
          for (final (k, x) in pairs) ...[k, x],
        ],
        (ids) => pb.MontyNode(dict: _pairs(ids)),
      ),
      MontyClassInstance(:final classType, :final instanceId, :final attrs) => (
        [classType, ..._attrChildren(attrs)],
        (ids) => pb.MontyNode(
          classInstance: pb.ClassInstanceNode(
            classType: _nz(ids.firstOrNull ?? 0),
            instanceId: _uuid(v, instanceId),
            attrs: _pairs(ids.skip(1)),
          ),
        ),
      ),
      _ => null,
    };

/// The members a hashable container's hash depends on.
List<MontyValue> _hashMembers(MontyValue v) => switch (v) {
  MontyTuple(:final items) || MontyFrozenSet(:final items) => items,
  MontyNamedTuple(:final values) => values,
  _ => const [],
};

/// The Python type name of [v] when it cannot be hashed at all.
String? _unhashableType(MontyValue v) => switch (v) {
  MontyList() => 'list',
  MontyDict() => 'dict',
  MontySet() => 'set',
  MontyClassInstance() => 'MontyClassProxy',
  _ => null,
};

/// Attributes as children: each name as the `str` it is sent as, then its
/// value.
List<Object> _attrChildren(Map<String, MontyValue> attrs) => [
  for (final MapEntry(:key, :value) in attrs.entries) ...[
    MontyString(key),
    value,
  ],
];

pb.NodePairs _pairs(Iterable<int> ids) => pb.NodePairs(
  pairs: [
    for (final [key, value] in ids.slices(2))
      pb.NodePair(key: _nz(key), value: _nz(value)),
  ],
);

void _checkNamedTuple(
  MontyNamedTuple v,
  String typeName,
  List<String> fieldNames,
) {
  for (final name in [typeName, ...fieldNames]) {
    _checkText(v, name, 'named tuple name');
  }
  final error = namedTupleError(typeName, fieldNames, v.values.length);
  if (error != null) throw ArgumentError.value(v, 'value', error);
}

/// The node for a leaf [v].
pb.MontyNode _leaf(MontyValue v) =>
    _singletonLeaf(v) ??
    _numberLeaf(v) ??
    _textLeaf(v) ??
    _temporalLeaf(v) ??
    _otherLeaf(v);

pb.MontyNode? _singletonLeaf(MontyValue v) => switch (v) {
  MontyNone() => pb.MontyNode(none: pb.Unit()),
  MontyEllipsis() => pb.MontyNode(ellipsis: pb.Unit()),
  MontyNotImplemented() => pb.MontyNode(notImplemented: pb.Unit()),
  _ => null,
};

pb.MontyNode? _numberLeaf(MontyValue v) => switch (v) {
  MontyBool(:final value) => pb.MontyNode(boolean: value),
  MontyInt(:final value) => intNode(value),
  MontyBigInt(:final value) => bigIntNode(value),
  final MontyFloat f => montyFloatNode(f),
  _ => null,
};

pb.MontyNode? _textLeaf(MontyValue v) => switch (v) {
  MontyString(:final value) => pb.MontyNode(str: _checkText(v, value, 'str')),
  MontyBytes(:final value) => pb.MontyNode(bytes: _checkBytes(v, value)),
  MontyPath(:final value) => pb.MontyNode(path: _checkText(v, value, 'path')),
  _ => null,
};

pb.MontyNode? _temporalLeaf(MontyValue v) => switch (v) {
  MontyDate(:final year, :final month, :final day) => pb.MontyNode(
    date: _check(v, () => checkDate(year, month, day, 'Date'), () {
      return pb.Date(year: _nz(year), month: _nz(month), day: _nz(day));
    }),
  ),
  final MontyDateTime d => pb.MontyNode(datetime: _datetime(d)),
  final MontyTime t => pb.MontyNode(time: _time(t)),
  final MontyTimeDelta td => pb.MontyNode(timedelta: _timedelta(td)),
  MontyTimeZone(:final offsetSeconds, :final name) => pb.MontyNode(
    timezone: _check(
      v,
      () => checkOffset(offsetSeconds, 'TimeZone.offset_seconds'),
      () =>
          pb.TimeZone(offsetSeconds: _nz(offsetSeconds), name: _zoneName(name)),
    ),
  ),
  _ => null,
};

pb.MontyNode _otherLeaf(MontyValue v) => switch (v) {
  final MontyExceptionValue e => pb.MontyNode(exception: _exception(e)),
  final MontyOpaque o => _opaque(o),
  final MontyFileHandle h => pb.MontyNode(fileHandle: _fileHandle(h)),
  // MontyDataclass is the only other leaf.
  _ => throw UnsupportedError(
    'a ${v.runtimeType} cannot be sent to the worker: it has no node; send a '
    'MontyClassInstance',
  ),
};

pb.DateTime _datetime(MontyDateTime d) => _check(
  d,
  () {
    checkZoneName(
      hasOffset: d.offsetSeconds != null,
      hasName: d.timezoneName != null,
      message: 'DateTime',
    );
    checkDate(d.year, d.month, d.day, 'DateTime');
    checkClock(d.hour, d.minute, d.second, d.microsecond, 'DateTime');
    if (d.offsetSeconds case final offset?) {
      checkOffset(offset, 'DateTime.offset_seconds');
    }
  },
  () => pb.DateTime(
    year: _nz(d.year),
    month: _nz(d.month),
    day: _nz(d.day),
    hour: _nz(d.hour),
    minute: _nz(d.minute),
    second: _nz(d.second),
    microsecond: _nz(d.microsecond),
    offsetSeconds: d.offsetSeconds,
    timezoneName: _zoneName(d.timezoneName),
  ),
);

pb.Time _time(MontyTime t) => _check(
  t,
  () {
    checkZoneName(
      hasOffset: t.offsetSeconds != null,
      hasName: t.timezoneName != null,
      message: 'Time',
    );
    checkClock(t.hour, t.minute, t.second, t.microsecond, 'Time');
    if (t.offsetSeconds case final offset?) {
      checkOffset(offset, 'Time.offset_seconds');
    }
    checkFold(t.fold);
  },
  () => pb.Time(
    hour: _nz(t.hour),
    minute: _nz(t.minute),
    second: _nz(t.second),
    microsecond: _nz(t.microsecond),
    offsetSeconds: t.offsetSeconds,
    timezoneName: _zoneName(t.timezoneName),
    fold: _nz(t.fold),
  ),
);

pb.TimeDelta _timedelta(MontyTimeDelta td) => _check(
  td,
  () {
    checkNormalized(td.seconds, 86400, 'TimeDelta.seconds');
    checkNormalized(td.microseconds, 1000000, 'TimeDelta.microseconds');
    if (td.days.abs() > maxTimedeltaDays) {
      invalidNode(
        'OverflowError: days=${td.days}; must have magnitude <= '
        '$maxTimedeltaDays',
      );
    }
  },
  () => pb.TimeDelta(
    days: _nz(td.days),
    seconds: _nz(td.seconds),
    microseconds: _nz(td.microseconds),
  ),
);

/// An exception value as upstream's `exception_arg` reads its argument: the
/// message as it is, or, when it has an unpaired surrogate, `str(exc)`
/// converted lossily. A `KeyError`'s `str` is the `repr` of its key, which
/// escapes the surrogate. No message is `str(exc)` of an argument-less
/// exception, `''`: upstream always sends an argument.
pb.Exception _exception(MontyExceptionValue e) {
  if (!exceptionTypeNames.contains(e.excType)) {
    throw ArgumentError.value(
      e,
      'value',
      'unknown exception type ${rustDebug(e.excType)}',
    );
  }
  final message = switch (e.message) {
    final m? when hasUnpairedSurrogate(m) =>
      e.excType == 'KeyError' ? pythonRepr(m) : lossyString(m),
    final m => m ?? '',
  };

  return pb.Exception(excType: e.excType, arg: message);
}

/// A builtin type or function crosses back as the builtin it names; the
/// other renderings name nothing the sandbox can rebuild.
pb.MontyNode _opaque(MontyOpaque o) => switch (o.kind) {
  MontyOpaqueKind.type when builtinTypeNames.contains(o.text) => pb.MontyNode(
    type: pb.Type(name: o.text, origin: originBuiltin),
  ),
  MontyOpaqueKind.builtin when builtinFunctionNames.contains(o.text) =>
    pb.MontyNode(builtinFunction: o.text),
  MontyOpaqueKind.type || MontyOpaqueKind.builtin => throw ArgumentError.value(
    o,
    'value',
    'unknown ${o.kind == MontyOpaqueKind.type ? 'type name' : 'builtin '
              'function'} ${rustDebug(o.text)}',
  ),
  MontyOpaqueKind.function ||
  MontyOpaqueKind.repr ||
  MontyOpaqueKind.cycle => throw ArgumentError.value(
    o,
    'value',
    'a ${o.kind.wireTag} rendering cannot be sent back to the worker: it '
        'names nothing the sandbox can rebuild',
  ),
};

/// The largest file position the wire's `uint64` carries.
final BigInt _maxPosition = (BigInt.one << 64) - BigInt.one;

pb.FileHandle _fileHandle(MontyFileHandle h) {
  final mode = canonicalFileMode(h.mode);
  if (mode == null) {
    throw ArgumentError.value(
      h,
      'value',
      'invalid file mode ${rustDebug(h.mode)}',
    );
  }
  final position = BigInt.from(h.position);
  if (position.isNegative || position > _maxPosition) {
    throw ArgumentError.value(
      h,
      'value',
      'file position ${h.position} is outside 0..2^64-1',
    );
  }

  return pb.FileHandle(
    path: _nzs(_checkText(h, h.path, 'file path')),
    mode: mode,
    position: position == BigInt.zero
        ? null
        : Int64.parseInt(position.toUnsigned(64).toString()),
  );
}

/// [name], or null when it is absent or has no UTF-8 form: upstream's
/// `timezone.__getinitargs__()` reading drops such a name and keeps the
/// offset.
String? _zoneName(String? name) =>
    name == null || hasUnpairedSurrogate(name) ? null : name;

final RegExp _canonicalUuid = RegExp(
  r'^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$',
  caseSensitive: false,
);

pb.Uuid _uuid(Object holder, String id) {
  // Only the canonical 8-4-4-4-12 form, so that lower-casing it gives one
  // spelling per uuid (the class-sharing key).
  if (!_canonicalUuid.hasMatch(id)) {
    throw ArgumentError.value(holder, 'value', 'id "$id" is not a uuid');
  }

  final hex = id.replaceAll('-', '');

  return pb.Uuid(
    data: [
      for (final pair in hex.split('').slices(2))
        int.parse(pair.join(), radix: 16),
    ],
  );
}

/// [text], after checking it has a UTF-8 form.
String _checkText(Object holder, String text, String what) {
  if (hasUnpairedSurrogate(text)) {
    throw ArgumentError.value(
      holder,
      'value',
      'the $what has an unpaired UTF-16 surrogate, which has no UTF-8 form',
    );
  }

  return text;
}

List<int> _checkBytes(MontyBytes holder, List<int> bytes) {
  for (final (i, b) in bytes.indexed) {
    if (b < 0 || b > 255) {
      throw ArgumentError.value(
        holder,
        'value',
        'byte $b at index $i is outside 0..255',
      );
    }
  }

  return bytes;
}

/// The node [build] makes once [rules] pass; a rule they break is an
/// [ArgumentError] carrying the worker's message for it.
T _check<T>(MontyValue holder, void Function() rules, T Function() build) {
  try {
    rules();
  } on FormatException catch (e) {
    throw ArgumentError.value(holder, 'value', e.message);
  }

  return build();
}

/// [v], or null at zero: proto3 omits a default, as prost does.
int? _nz(int v) => v == 0 ? null : v;

String? _nzs(String v) => v.isEmpty ? null : v;
