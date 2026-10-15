// The recursive `==`, `toJson` and `dartValue` the MontyValue containers
// have, written out directly as Python's rules (C5D q4, AGY1 Q7, Q41): a
// named tuple equals a tuple of the same items, a set a frozenset of the
// same members, a set or dict built with repeats compares as Python's
// constructor would build it (members once; each key once, at its first
// position, with its last value), and a class proxy compares its class name,
// dataclass flag and attributes. Leaf classes are asked for their own `==`.
//
// It is the reference for the randomized equivalence test, so it shares
// nothing with monty_value_graph.dart: a plain recursion with quadratic
// matching, no hashing, no budget.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show MontyValueInternal;

bool _isContainer(MontyValue v) =>
    v is MontyList ||
    v is MontyTuple ||
    v is MontySet ||
    v is MontyFrozenSet ||
    v is MontyDict ||
    v is MontyNamedTuple ||
    v is MontyClassProxy;

List<MontyValue>? _tuple(MontyValue v) => switch (v) {
  MontyTuple(:final items) => items,
  MontyNamedTuple(:final values) => values,
  _ => null,
};

List<MontyValue>? _set(MontyValue v) => switch (v) {
  MontySet(:final items) || MontyFrozenSet(:final items) => items,
  _ => null,
};

bool _seq(List<MontyValue> a, List<MontyValue> b) {
  if (a.length != b.length) return false;
  for (final (i, x) in a.indexed) {
    final y = b.elementAtOrNull(i);
    if (y == null || !referenceEquals(x, y)) return false;
  }

  return true;
}

/// Python's set construction: each member once.
List<MontyValue> _distinct(List<MontyValue> xs) {
  final out = <MontyValue>[];
  for (final x in xs) {
    if (!out.any((o) => referenceEquals(o, x))) out.add(x);
  }

  return out;
}

/// Python's dict construction: each key once, first position, last value.
List<(MontyValue, MontyValue)> referenceEntries(
  List<(MontyValue, MontyValue)> ps,
) => _entries(ps);

List<(MontyValue, MontyValue)> _entries(List<(MontyValue, MontyValue)> ps) {
  final out = <(MontyValue, MontyValue)>[];
  for (final (k, v) in ps) {
    final i = out.indexWhere((o) => referenceEquals(o.$1, k));
    if (i < 0) {
      out.add((k, v));
    } else {
      out[i] = ((out.elementAtOrNull(i) ?? (k, v)).$1, v);
    }
  }

  return out;
}

bool _sameMembers(List<MontyValue> a, List<MontyValue> b) {
  final x = _distinct(a);
  final y = _distinct(b);

  return x.length == y.length &&
      x.every((e) => y.any((f) => referenceEquals(e, f)));
}

bool _sameEntries(
  List<(MontyValue, MontyValue)> a,
  List<(MontyValue, MontyValue)> b,
) {
  final x = _entries(a);
  final y = _entries(b);

  return x.length == y.length &&
      x.every(
        (p) => y.any(
          (q) => referenceEquals(p.$1, q.$1) && referenceEquals(p.$2, q.$2),
        ),
      );
}

List<(MontyValue, MontyValue)> _attrPairs(Map<String, MontyValue> m) => [
  for (final MapEntry(:key, :value) in m.entries) (MontyString(key), value),
];

/// `a == b` under the aligned rules.
bool referenceEquals(MontyValue a, MontyValue b) {
  if (identical(a, b)) return true;
  if (!_isContainer(a) || !_isContainer(b)) return a == b; // leaf ==
  if (a is MontyList) return b is MontyList && _seq(a.items, b.items);
  if ((_tuple(a), _tuple(b)) case (final x?, final y?)) return _seq(x, y);
  if ((_set(a), _set(b)) case (final x?, final y?)) return _sameMembers(x, y);
  if (a is MontyDict) return b is MontyDict && _sameEntries(a.pairs, b.pairs);
  if (a is MontyClassProxy && b is MontyClassProxy) {
    return a.classType.name == b.classType.name &&
        a.classType.isDataclass == b.classType.isDataclass &&
        _sameEntries(_attrPairs(a.attrs), _attrPairs(b.attrs));
  }

  return false;
}

/// [d] as a string-keyed map: each key
/// at its first position with its last value, or `null` when a key is not a
/// [MontyString].
Map<String, MontyValue>? _asStringMap(MontyDict d) {
  final out = <String, MontyValue>{};
  for (final (k, v) in d.pairs) {
    if (k is! MontyString) return null;
    out[k.value] = v;
  }

  return out;
}

// The attribute projection: the pairs collapse through a string-keyed
// map first, so a value overwritten by a repeated key (an identity map) is
// never projected.
Map<String, Object?> _attrsJson(Map<String, MontyValue> attrs) => {
  '__type': 'dict',
  'value': <String, MontyValue>{
    for (final MapEntry(:key, :value) in attrs.entries) key: value,
  }.map((k, v) => MapEntry(k, referenceToJson(v))),
};

/// `v.toJson()`.
Object? referenceToJson(MontyValue v) => switch (v) {
  MontyList(:final items) => items.map(referenceToJson).toList(),
  MontyTuple(:final items) => <String, Object?>{
    '__type': 'tuple',
    'value': items.map(referenceToJson).toList(),
  },
  MontySet(:final items) => <String, Object?>{
    '__type': 'set',
    'value': items.map(referenceToJson).toList(),
  },
  MontyFrozenSet(:final items) => <String, Object?>{
    '__type': 'frozenset',
    'value': items.map(referenceToJson).toList(),
  },
  MontyDict(:final pairs) => switch (_asStringMap(v)) {
    final strings? => <String, Object?>{
      '__type': 'dict',
      'value': strings.map((k, x) => MapEntry(k, referenceToJson(x))),
    },
    null => <String, Object?>{
      '__type': 'dict',
      'entries': [
        for (final (k, x) in pairs) [referenceToJson(k), referenceToJson(x)],
      ],
    },
  },
  MontyNamedTuple(:final typeName, :final fieldNames, :final values) =>
    <String, Object?>{
      '__type': 'namedtuple',
      'type_name': typeName,
      'field_names': fieldNames,
      'values': values.map(referenceToJson).toList(),
    },
  MontyClassProxy(:final classType, :final instanceId, :final attrs) =>
    <String, Object?>{
      '__type': 'class_instance',
      // Untyped in the old code, so inferred from its values.
      'class_type': <String, Object>{
        '__type': 'class_type',
        'name': classType.name,
        'id': classType.id,
        'host_defined': classType.hostDefined,
        'is_dataclass': classType.isDataclass,
        'attrs': _attrsJson(classType.attrs),
      },
      'instance_id': instanceId,
      'attrs': _attrsJson(attrs),
    },
  _ => v.toJson(),
};

/// `v.dartValue`.
Object? referenceDartValue(MontyValue v) => switch (v) {
  MontyList(:final items) ||
  MontyTuple(:final items) ||
  MontySet(:final items) ||
  MontyFrozenSet(:final items) => items.map(referenceDartValue).toList(),
  MontyDict(:final pairs) => switch (_asStringMap(v)) {
    final strings? => strings.map((k, x) => MapEntry(k, referenceDartValue(x))),
    null => [
      for (final (k, x) in pairs)
        [referenceDartValue(k), referenceDartValue(x)],
    ],
  },
  MontyNamedTuple() || MontyClassProxy() => referenceToJson(v),
  _ => v.dartValue,
};

/// `dartAttrs`.
Map<String, Object?> referenceDartAttrs(Map<String, MontyValue> attrs) =>
    attrs.map((k, v) => MapEntry(k, referenceDartValue(v)));
