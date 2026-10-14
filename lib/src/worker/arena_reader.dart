/// Values from the worker: a monty-proto `Arena` to [MontyValue].
///
/// An arena is a flat list of nodes in post-order: a container holds the
/// indexes of its children, every child index is lower than its holder's, and
/// a value referenced twice is one node referenced twice. Like upstream's
/// Python decoder (monty-proto 1.1.0, `python/decode.rs`), the reader builds
/// every node once, in arena order, so a sub-list shared by two parents
/// decodes to one Dart object, and nesting depth costs no call stack.
///
/// It is exactly as strict as upstream, and no stricter. Upstream checks an
/// arena in three stages, and so does the reader, with upstream's messages:
///
/// 1. each node on its own (`arena_nodes.dart`), every node, reachable or
///    not;
/// 2. the references: every child below its holder, and every class
///    instance's class a class `type` node;
/// 3. the Python objects built from the nodes: dict keys and set members
///    hashable and collapsed as Python collapses them, named tuples with valid
///    names and lengths, timedeltas within 999999999 days
///    (`python_rules.dart`, `python_keys.dart`).
///
/// A failure in any stage is a [FormatException].
///
/// Every kind upstream emits decodes to the [MontyValue] class of the same
/// meaning, mapped as upstream's Python host maps it: `repr`, `cycle` and an
/// output `function` become [MontyString]; a builtin type or function
/// becomes [MontyOpaque]; a path is normalized as `PurePosixPath`; a
/// payload-less `UnicodeDecodeError`, `UnicodeEncodeError` or
/// `json.JSONDecodeError` value becomes a `ValueError`.
///
/// Three things have no [MontyValue] class yet, and reaching one from the
/// root asked for is an [UnsupportedError]: a `complex`, a class `type` node
/// as a value (as an instance's class it decodes normally), and a file
/// position an `int` cannot hold exactly on this platform. The rest of the
/// arena is still checked, and other roots still decode.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_nodes.dart';
import 'package:dart_monty_core/src/worker/host_objects.dart' show wrappedValue;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/python_keys.dart';
import 'package:dart_monty_core/src/worker/python_rules.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:fixnum/fixnum.dart';

/// Where class and instance nodes may resolve to objects the host
/// registered, instead of to proxies.
///
/// The reader calls `classType` with the id of every class `type` node and
/// `instance` with the id of every class instance node, in arena order, as
/// upstream's decoder consults its instance store. A [MontyValue] result is
/// what the node decodes to; for a class, only where it is reached as a
/// value. Any other non-null result is the host object registered for the
/// node, which is not yet a [MontyValue]: the node decodes as a proxy, and
/// [hostObjectOf] that proxy is the result. An instance whose class is
/// registered but which is not itself registered still decodes to a plain
/// proxy.
///
/// A registered object is hashable as a dict key or set member, by its own
/// `==` and `hashCode`.
typedef HostObjectLookup = ({
  Object? Function(String classId) classType,
  Object? Function(String instanceId) instance,
});

final Expando<Object> _hostObjects = Expando('host object');

/// The host object a decoded [value] stands for: the registered object its
/// instance node resolved to through a [HostObjectLookup], or null. Upstream
/// decodes such a node to the original object; until the host-object
/// wrappers join the [MontyValue] family, the node decodes to its proxy and
/// this recovers the object.
Object? hostObjectOf(MontyValue value) =>
    value is MontyClassInstance ? _hostObjects[value] : null;

/// Reads values out of one arena.
///
/// The whole arena is checked and built on the first read; two roots naming
/// the same node give the identical Dart object.
final class ArenaReader {
  /// Creates a reader over [arena]'s nodes, resolving registered objects
  /// through [hosts].
  ArenaReader(pb.Arena arena, {HostObjectLookup? hosts})
    : _nodes = arena.nodes,
      _hosts = hosts;

  final List<pb.MontyNode> _nodes;
  final HostObjectLookup? _hosts;

  /// Stages 1 and 2 passed.
  bool _checked = false;

  /// What each node built to, once stage 3 has run.
  List<Object>? _built;

  /// The failure of a stage that ran over the whole arena, thrown again on
  /// every later read.
  (Object, StackTrace)? _failure;

  /// The value rooted at node [index].
  ///
  /// Throws [FormatException] for an arena upstream rejects, or an [index]
  /// outside it, and [UnsupportedError] for a value that holds one of the
  /// kinds with no class yet.
  MontyValue operator [](int index) {
    if (_failure case (final error, final stack)) {
      Error.throwWithStackTrace(error, stack);
    }
    _guarded(() {
      if (!_checked) {
        _nodes.forEach(checkNode);
        for (var i = 0; i < _nodes.length; i++) {
          _checkReferences(i);
        }
        _checked = true;
      }
    });
    if (index < 0 || index >= _nodes.length) {
      throw FormatException(
        'invalid value for Arena: value root $index is out of range for an '
        'arena of ${_nodes.length} nodes',
      );
    }
    final built = _built ??= _guarded<List<Object>>(
      () => _Builder(_nodes, _hosts, {}).build(),
    );

    final value = _valueIn(built, index);
    if (value is _Staged) throw UnsupportedError(value.message);

    return value as MontyValue;
  }

  T _guarded<T>(T Function() stage) {
    try {
      return stage();
    } on Object catch (error, stack) {
      _failure = (error, stack);
      rethrow;
    }
  }

  /// Stage 2 for node [i]: upstream's `MontyGraph::check_node`.
  void _checkReferences(int i) {
    final node = _nodeAt(_nodes, i);
    for (final child in _children(node)) {
      if (child >= i) {
        throw FormatException(
          'invalid value for Arena: value node $i references node $child, '
          'which is not below it',
        );
      }
    }
    if (node.whichKind() == pb.MontyNode_Kind.classInstance &&
        !_isClassNode(_nodeAt(_nodes, node.classInstance.classType))) {
      throw FormatException(
        'invalid value for Arena: class instance node $i does not point at a '
        'class type',
      );
    }
  }
}

/// Node [i] of [built] as a value: a class node as a value is its registered
/// object, or staged.
Object _valueIn(List<Object> built, int i) =>
    switch (built.elementAtOrNull(i)) {
      _ClassNode(:final asValue) => asValue,
      final other => other ?? (throw StateError('node $i is not built')),
    };

/// Node [i] of [nodes], whose index the arena has checked.
pb.MontyNode _nodeAt(List<pb.MontyNode> nodes, int i) =>
    nodes.elementAtOrNull(i) ?? (throw StateError('node $i is not checked'));

Never _unchecked(_Builder _, pb.MontyNode n) => throw StateError('$n');

bool _isClassNode(pb.MontyNode node) =>
    node.whichKind() == pb.MontyNode_Kind.type &&
    node.type.origin != originBuiltin;

/// A node's children in upstream's `for_each_child` order.
List<int> _children(pb.MontyNode node) => switch (node.whichKind()) {
  pb.MontyNode_Kind.list => node.list.items,
  pb.MontyNode_Kind.tuple => node.tuple.items,
  pb.MontyNode_Kind.set => node.set.items,
  pb.MontyNode_Kind.frozenSet => node.frozenSet.items,
  pb.MontyNode_Kind.namedTuple => node.namedTuple.values,
  pb.MontyNode_Kind.dict => _flat(node.dict.pairs),
  pb.MontyNode_Kind.type when node.type.origin != originBuiltin => _flat(
    node.type.attrs.pairs,
  ),
  pb.MontyNode_Kind.classInstance => [
    node.classInstance.classType,
    ..._flat(node.classInstance.attrs.pairs),
  ],
  _ => const [],
};

List<int> _flat(List<pb.NodePair> pairs) => [
  for (final p in pairs) ...[p.key, p.value],
];

/// A value that holds a kind with no [MontyValue] class yet.
final class _Staged {
  const _Staged(this.message);

  final String message;
}

/// A class `type` node: the class an instance names, and what the node is
/// when reached as a value.
final class _ClassNode {
  const _ClassNode(this.meta, this.asValue);

  /// [MontyClassType], or [_Staged] when its attributes hold a staged kind.
  final Object meta;

  /// The registered object, or [_Staged] until there is a class for a class
  /// type value.
  final Object asValue;
}

/// Stage 3: every node to its value, in arena order.
final class _Builder {
  _Builder(this._nodes, this._hosts, this._registered)
    : _keys = PythonKeys(_nodes, _registered);

  final List<pb.MontyNode> _nodes;
  final HostObjectLookup? _hosts;
  final List<Object> _built = [];

  /// The registered object each class or instance node resolved to: the
  /// host object itself, so two nodes for one object are one key.
  final Map<int, Object> _registered;

  /// The proxy each host object decoded to, so two nodes for one object
  /// are one Dart object, as upstream's are the one original object.
  final Map<Object, MontyClassInstance> _carriers = Map.identity();
  final PythonKeys _keys;

  List<Object> build() {
    for (final node in _nodes) {
      _built.add((_kinds[node.whichKind()] ?? _unchecked)(this, node));
    }

    return _built;
  }

  Object _value(int i) => _valueIn(_built, i);

  /// A builtin type is opaque; a class type is a class node.
  Object _type(pb.Type type) => type.origin == originBuiltin
      ? MontyOpaque(MontyOpaqueKind.type, type.name)
      : _classNode(type);

  /// A list of the values of [ids], or the first staged one among them.
  Object _items(List<int> ids, MontyValue Function(List<MontyValue>) make) {
    final items = <MontyValue>[];
    for (final id in ids) {
      switch (_value(id)) {
        case final MontyValue v:
          items.add(v);
        case final staged:
          return staged;
      }
    }

    return make(List.unmodifiable(items));
  }

  /// [ids] without the members Python's set construction drops: each one
  /// equal to an earlier one.
  List<int> _unique(List<int> ids) {
    final seen = <int>{};

    return [
      for (final id in ids)
        if (seen.add(_keys.keyOf(id))) id,
    ];
  }

  /// A dict as Python builds it: a key equal to an earlier one keeps the
  /// earlier key and its place, and takes the later value.
  Object _dict(List<pb.NodePair> pairs) {
    // Python key -> (the first key node, the last value node), in order.
    final entries = <int, (int, int)>{};
    for (final p in pairs) {
      entries.update(
        _keys.keyOf(p.key),
        (entry) => (entry.$1, p.value),
        ifAbsent: () => (p.key, p.value),
      );
    }
    final out = <(MontyValue, MontyValue)>[];
    for (final (key, value) in entries.values) {
      final k = _value(key);
      if (k is _Staged) return k;
      final v = _value(value);
      if (v is _Staged) return v;
      out.add((k as MontyValue, v as MontyValue));
    }

    return MontyDict(List.unmodifiable(out));
  }

  Object _namedTuple(pb.NamedTupleNode node) {
    final error = namedTupleError(
      node.typeName,
      node.fieldNames,
      node.values.length,
    );
    if (error != null) throw FormatException(error);

    return _items(
      node.values,
      (values) => MontyNamedTuple(
        typeName: node.typeName,
        fieldNames: List.unmodifiable(node.fieldNames),
        values: values,
      ),
    );
  }

  _ClassNode _classNode(pb.Type type) {
    final id = uuidString(type.id.data);
    final found = _hosts?.classType(id);
    final host = _register(found is MontyValue ? found : null);
    final attrs = _attrs(type.attrs.pairs);
    final meta = attrs is _Staged
        ? attrs
        : MontyClassType(
            name: type.name,
            id: id,
            hostDefined: type.origin == originHost,
            isDataclass: type.isDataclass,
            attrs: attrs as Map<String, MontyValue>,
          );

    return _ClassNode(
      meta,
      host ??
          _Staged(
            'the worker sent the class "${type.name}" as a value; this '
            'version of the package has no class for a class type value',
          ),
    );
  }

  Object _instance(pb.ClassInstanceNode node) {
    final id = uuidString(node.instanceId.data);
    final found = _hosts?.instance(id);
    if (found is MontyValue) return _registered[_built.length] = found;
    // Stage 2 made the instance's class a class node, built before it.
    final classNode = _built.elementAtOrNull(node.classType);
    final meta = classNode is _ClassNode ? classNode.meta : null;
    final attrs = _attrs(node.attrs.pairs);
    if (found != null) return _hostInstance(found, node, meta, attrs);
    if (meta is! MontyClassType) return meta ?? (throw StateError('$node'));
    if (attrs is _Staged) return attrs;

    return MontyClassInstance(
      classType: meta,
      instanceId: id,
      attrs: attrs as Map<String, MontyValue>,
    );
  }

  /// The node of a registered host object [found]: one proxy per wrapped
  /// object, keyed by that object, whatever the node's attributes. Upstream
  /// decodes it to the original object without reading them, so a staged
  /// attribute leaves the proxy without attributes instead of failing.
  MontyClassInstance _hostInstance(
    Object found,
    pb.ClassInstanceNode node,
    Object? meta,
    Object attrs,
  ) {
    final key = wrappedValue(found);
    _registered[_built.length] = key;
    if (_carriers[key] case final carrier?) return carrier;
    final type = _nodeAt(_nodes, node.classType).type;
    final proxy = MontyClassInstance(
      classType: meta is MontyClassType
          ? meta
          : MontyClassType(
              name: type.name,
              id: uuidString(type.id.data),
              hostDefined: type.origin == originHost,
              isDataclass: type.isDataclass,
              attrs: const {},
            ),
      instanceId: uuidString(node.instanceId.data),
      attrs: attrs is Map<String, MontyValue> ? attrs : const {},
    );
    _hostObjects[proxy] = found;

    return _carriers[key] = proxy;
  }

  /// [host], recorded as what the node being built resolved to.
  MontyValue? _register(MontyValue? host) {
    if (host != null) _registered[_built.length] = host;

    return host;
  }

  /// Attribute pairs as upstream's `attrs_dict` reads them: only pairs whose
  /// key node is a `str` count, and a repeated name takes the later value.
  Object _attrs(List<pb.NodePair> pairs) {
    // Each name's last value node first: an overwritten value never reaches
    // the result, so it cannot stage it.
    final last = <String, int>{};
    for (final p in pairs) {
      final key = _nodeAt(_nodes, p.key);
      if (key.whichKind() == pb.MontyNode_Kind.str) last[key.str] = p.value;
    }
    final attrs = <String, MontyValue>{};
    for (final MapEntry(:key, value: node) in last.entries) {
      switch (_value(node)) {
        case final MontyValue v:
          attrs[key] = v;
        case final staged:
          return staged;
      }
    }

    return Map<String, MontyValue>.unmodifiable(attrs);
  }
}

MontyValue _datetime(pb.DateTime d) => MontyDateTime(
  year: d.year,
  month: d.month,
  day: d.day,
  hour: d.hour,
  minute: d.minute,
  second: d.second,
  microsecond: d.microsecond,
  offsetSeconds: d.hasOffsetSeconds() ? d.offsetSeconds : null,
  timezoneName: d.hasTimezoneName() ? d.timezoneName : null,
);

MontyValue _time(pb.Time t) => MontyTime(
  hour: t.hour,
  minute: t.minute,
  second: t.second,
  microsecond: t.microsecond,
  offsetSeconds: t.hasOffsetSeconds() ? t.offsetSeconds : null,
  timezoneName: t.hasTimezoneName() ? t.timezoneName : null,
  fold: t.fold,
);

/// The largest file position an `int` holds exactly on this platform:
/// 2^63-1, or 2^53 on dart2js, where an `int` is a double and the integers
/// above 2^53 it can hold are no longer contiguous.
final BigInt _maxPosition = BigInt.parse(
  _webInts ? '9007199254740992' : '9223372036854775807',
);

/// dart2js, where an `int` is a double.
const bool _webInts = identical(1, 1.0);

/// The largest magnitude every backend holds exactly in a Dart `int`.
///
/// Beyond it an integer decodes as [MontyBigInt], as on the JSON path, so a
/// value's Dart type does not depend on the compiler.
final BigInt _exactIntLimit = BigInt.one << 53;

/// An unsigned 64-bit wire field as Python's `int`: [MontyInt] up to 2^53,
/// [MontyBigInt] beyond.
MontyValue unsignedValue(Int64 v) =>
    _intValue(BigInt.parse(v.toStringUnsigned()));

/// [MontyInt] within ±2^53, [MontyBigInt] beyond: the rule the JSON path
/// already follows.
MontyValue _intValue(BigInt v) =>
    v.abs() <= _exactIntLimit ? MontyInt(v.toInt()) : MontyBigInt(v);

/// How each kind builds, its children being built.
final Map<pb.MontyNode_Kind, Object Function(_Builder, pb.MontyNode)> _kinds = {
  pb.MontyNode_Kind.none: (_, _) => const MontyNone(),
  pb.MontyNode_Kind.ellipsis: (_, _) => const MontyEllipsis(),
  pb.MontyNode_Kind.notImplemented: (_, _) => const MontyNotImplemented(),
  pb.MontyNode_Kind.boolean: (b, n) => MontyBool(n.boolean),
  pb.MontyNode_Kind.int_5: (b, n) => _intValue(intOfNode(n)),
  pb.MontyNode_Kind.bigint: (b, n) => _intValue(bigIntOfNode(n.bigint)),
  pb.MontyNode_Kind.float: (_, n) => montyFloatOf(n),
  pb.MontyNode_Kind.complex: (_, _) => const _Staged(
    'the worker sent a "complex" value; this version of the package has '
    'no class for it',
  ),
  pb.MontyNode_Kind.str: (b, n) => MontyString(n.str),
  pb.MontyNode_Kind.bytes: (b, n) =>
      MontyBytes(Uint8List.fromList(n.bytes).asUnmodifiableView()),
  pb.MontyNode_Kind.list: (b, n) => b._items(n.list.items, MontyList.new),
  pb.MontyNode_Kind.tuple: (b, n) => b._items(n.tuple.items, MontyTuple.new),
  pb.MontyNode_Kind.namedTuple: (b, n) => b._namedTuple(n.namedTuple),
  pb.MontyNode_Kind.dict: (b, n) => b._dict(n.dict.pairs),
  pb.MontyNode_Kind.set: (b, n) =>
      b._items(b._unique(n.set.items), MontySet.new),
  pb.MontyNode_Kind.frozenSet: (b, n) =>
      b._items(b._unique(n.frozenSet.items), MontyFrozenSet.new),
  pb.MontyNode_Kind.date: (b, n) =>
      MontyDate(year: n.date.year, month: n.date.month, day: n.date.day),
  pb.MontyNode_Kind.datetime: (b, n) => _datetime(n.datetime),
  pb.MontyNode_Kind.time: (b, n) => _time(n.time),
  pb.MontyNode_Kind.timedelta: (b, n) => _timedelta(n.timedelta),
  pb.MontyNode_Kind.timezone: (b, n) => MontyTimeZone(
    offsetSeconds: n.timezone.offsetSeconds,
    name: n.timezone.hasName() ? n.timezone.name : null,
  ),
  pb.MontyNode_Kind.exception: (b, n) => _exception(n.exception),
  pb.MontyNode_Kind.type: (b, n) => b._type(n.type),
  pb.MontyNode_Kind.classInstance: (b, n) => b._instance(n.classInstance),
  pb.MontyNode_Kind.builtinFunction: (b, n) =>
      _builtinFunction(n.builtinFunction),
  pb.MontyNode_Kind.function: (b, n) => MontyString(n.function.name),
  pb.MontyNode_Kind.repr: (b, n) => MontyString(n.repr),
  pb.MontyNode_Kind.cycle: (b, n) => MontyString(n.cycle),
  pb.MontyNode_Kind.path: (b, n) => MontyPath(purePosixPath(n.path)),
  pb.MontyNode_Kind.fileHandle: (b, n) => _fileHandle(n.fileHandle),
};

/// `type` is the type `type`; every other builtin function is a proxy.
MontyValue _builtinFunction(String name) => name == 'type'
    ? const MontyOpaque(MontyOpaqueKind.type, 'type')
    : MontyOpaque(MontyOpaqueKind.builtin, name);

MontyValue _timedelta(pb.TimeDelta td) {
  if (td.days.abs() > maxTimedeltaDays) {
    throw FormatException(
      'OverflowError: days=${td.days}; must have magnitude <= '
      '$maxTimedeltaDays',
    );
  }

  return MontyTimeDelta(
    days: td.days,
    seconds: td.seconds,
    microseconds: td.microseconds,
  );
}

/// An exception value as upstream's `exc_monty_to_py` builds it: an absent
/// argument is an empty message, and the three types whose real classes
/// need a payload a value node does not carry become `ValueError`.
MontyValue _exception(pb.Exception e) => MontyExceptionValue(
  excType: switch (e.excType) {
    'UnicodeDecodeError' ||
    'UnicodeEncodeError' ||
    'json.JSONDecodeError' => 'ValueError',
    final name => name,
  },
  message: e.hasArg() ? e.arg : '',
);

Object _fileHandle(pb.FileHandle handle) {
  final position = BigInt.parse(handle.position.toStringUnsigned());
  if (position > _maxPosition) {
    return _Staged(
      'the worker sent a file position of $position, which an int cannot '
      'hold exactly on this platform',
    );
  }

  return MontyFileHandle(
    path: handle.path,
    mode: canonicalFileMode(handle.mode) ?? handle.mode,
    position: position.toInt(),
  );
}
