// The recursive `==`, `hashCode`, `toJson` and `dartValue` that the
// MontyValue containers had before the identity-aware walk, transcribed from
// the classes at cff9002 (lib/src/platform/monty_value_*.dart).
//
// It is the reference for the randomized equivalence test, so it shares
// nothing with monty_value_graph.dart: element hashes and equality go through
// package:collection's DeepCollectionEquality (wrapper objects for lists,
// MapEquality on the attribute maps themselves), exactly as the old classes
// called it, and only leaf classes (which this change does not
// touch) are asked for their own `==` and `hashCode`. Each map literal carries
// the type the old declared return type gave it.
import 'package:collection/collection.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:meta/meta.dart';

const _deepEq = DeepCollectionEquality();

/// Wraps a value so package:collection reaches the legacy operations.
@immutable
final class _L {
  const _L(this.v);

  final MontyValue v;

  @override
  int get hashCode => legacyHash(v);

  @override
  bool operator ==(Object other) => other is _L && legacyEquals(v, other.v);
}

/// Wraps a class type the same way.
@immutable
final class _LT {
  const _LT(this.t);

  final MontyClassType t;

  @override
  int get hashCode => _classTypeHash(t);

  @override
  bool operator ==(Object other) =>
      other is _LT && _classTypeEquals(t, other.t);
}

List<_L> _w(List<MontyValue> xs) => [for (final x in xs) _L(x)];

/// The legacy operations as an [Equality], for package:collection.
final class _LegacyEquality implements Equality<MontyValue> {
  const _LegacyEquality();

  @override
  bool equals(MontyValue e1, MontyValue e2) => legacyEquals(e1, e2);

  @override
  int hash(MontyValue e) => legacyHash(e);

  @override
  bool isValidKey(Object? o) => o is MontyValue;
}

/// `_deepEq` on an attribute map, as the old classes ran it: on the map
/// itself, so its own keys and lookups count (an identity map keeps two
/// equal keys apart), with values compared by the legacy operations.
// Keys are strings, for which DeepCollectionEquality is DefaultEquality.
const _attrsEq = MapEquality<String, MontyValue>(values: _LegacyEquality());

bool _isContainer(MontyValue v) =>
    v is MontyList ||
    v is MontyTuple ||
    v is MontySet ||
    v is MontyFrozenSet ||
    v is MontyDict ||
    v is MontyNamedTuple ||
    v is MontyClassInstance ||
    v is MontyDataclass;

/// `a == b` as the old classes computed it, with [a] the receiver.
bool legacyEquals(MontyValue a, MontyValue b) {
  if (!_isContainer(a)) return a == b; // leaf ==, unchanged
  if (identical(a, b)) return true;
  switch (a) {
    case MontyList(:final items):
      return b is MontyList && _deepEq.equals(_w(b.items), _w(items));
    case MontyTuple(:final items):
      return b is MontyTuple && _deepEq.equals(_w(b.items), _w(items));
    case MontySet(:final items):
      return b is MontySet && _multiset(items, b.items);
    case MontyFrozenSet(:final items):
      return b is MontyFrozenSet && _multiset(items, b.items);
    case MontyDict(:final pairs):
      if (b is! MontyDict || b.pairs.length != pairs.length) return false;
      final remaining = [for (final (k, v) in b.pairs) (_L(k), _L(v))];
      for (final (k, v) in pairs) {
        if (!remaining.remove((_L(k), _L(v)))) return false;
      }

      return remaining.isEmpty;
    case MontyNamedTuple(:final typeName, :final fieldNames, :final values):
      return b is MontyNamedTuple &&
          b.typeName == typeName &&
          _deepEq.equals(b.fieldNames, fieldNames) &&
          _deepEq.equals(_w(b.values), _w(values));
    case MontyClassInstance(:final classType, :final instanceId, :final attrs):
      return b is MontyClassInstance &&
          _classTypeEquals(b.classType, classType) &&
          b.instanceId == instanceId &&
          _attrsEq.equals(b.attrs, attrs);
    case MontyDataclass(
      :final name,
      :final typeId,
      :final fieldNames,
      :final attrs,
      :final frozen,
    ):
      return b is MontyDataclass &&
          b.name == name &&
          b.typeId == typeId &&
          _deepEq.equals(b.fieldNames, fieldNames) &&
          _attrsEq.equals(b.attrs, attrs) &&
          b.frozen == frozen;
    default:
      throw StateError('unreachable');
  }
}

bool _multiset(List<MontyValue> items, List<MontyValue> other) {
  if (other.length != items.length) return false;
  final remaining = _w(other);
  for (final item in items) {
    if (!remaining.remove(_L(item))) return false;
  }

  return remaining.isEmpty;
}

bool _classTypeEquals(MontyClassType b, MontyClassType a) =>
    identical(a, b) ||
    (b.name == a.name &&
        b.id == a.id &&
        b.hostDefined == a.hostDefined &&
        b.isDataclass == a.isDataclass &&
        _attrsEq.equals(b.attrs, a.attrs));

int _classTypeHash(MontyClassType t) => Object.hash(
  t.name,
  t.id,
  t.hostDefined,
  t.isDataclass,
  _attrsEq.hash(t.attrs),
);

/// `v.hashCode` as the old classes computed it.
int legacyHash(MontyValue v) => switch (v) {
  MontyList(:final items) ||
  MontyTuple(:final items) => _deepEq.hash(_w(items)),
  MontySet(:final items) || MontyFrozenSet(:final items) => items.fold(
    0,
    (acc, e) => acc + legacyHash(e),
  ),
  MontyDict(:final pairs) => pairs.fold(
    0,
    (acc, p) => acc + Object.hash(_L(p.$1), _L(p.$2)),
  ),
  MontyNamedTuple(:final typeName, :final fieldNames, :final values) =>
    Object.hash(typeName, _deepEq.hash(fieldNames), _deepEq.hash(_w(values))),
  MontyClassInstance(:final classType, :final instanceId, :final attrs) =>
    Object.hash(_LT(classType), instanceId, _attrsEq.hash(attrs)),
  MontyDataclass(
    :final name,
    :final typeId,
    :final fieldNames,
    :final attrs,
    :final frozen,
  ) =>
    Object.hash(
      name,
      typeId,
      _deepEq.hash(fieldNames),
      _attrsEq.hash(attrs),
      frozen,
    ),
  _ => v.hashCode,
};

// MontyDict.ofStrings(attrs).toJson(): the pairs collapse through
// asStringMap first, so a value overwritten by a repeated key (an identity
// map) is never projected.
Map<String, Object?> _attrsJson(Map<String, MontyValue> attrs) => {
  '__type': 'dict',
  'value': (MontyDict.ofStrings(attrs).asStringMap ?? const {}).map(
    (k, v) => MapEntry(k, legacyToJson(v)),
  ),
};

/// `v.toJson()` as the old classes computed it.
Object? legacyToJson(MontyValue v) => switch (v) {
  MontyList(:final items) => items.map(legacyToJson).toList(),
  MontyTuple(:final items) => <String, Object?>{
    '__type': 'tuple',
    'value': items.map(legacyToJson).toList(),
  },
  MontySet(:final items) => <String, Object?>{
    '__type': 'set',
    'value': items.map(legacyToJson).toList(),
  },
  MontyFrozenSet(:final items) => <String, Object?>{
    '__type': 'frozenset',
    'value': items.map(legacyToJson).toList(),
  },
  MontyDict(:final pairs) => switch (v.asStringMap) {
    final strings? => <String, Object?>{
      '__type': 'dict',
      'value': strings.map((k, x) => MapEntry(k, legacyToJson(x))),
    },
    null => <String, Object?>{
      '__type': 'dict',
      'entries': [
        for (final (k, x) in pairs) [legacyToJson(k), legacyToJson(x)],
      ],
    },
  },
  MontyNamedTuple(:final typeName, :final fieldNames, :final values) =>
    <String, Object?>{
      '__type': 'namedtuple',
      'type_name': typeName,
      'field_names': fieldNames,
      'values': values.map(legacyToJson).toList(),
    },
  MontyClassInstance(:final classType, :final instanceId, :final attrs) =>
    <String, Object?>{
      '__type': 'class_instance',
      // Untyped in the old code, so inferred from its values.
      'class_type': <String, Object>{
        'name': classType.name,
        'id': classType.id,
        'host_defined': classType.hostDefined,
        'is_dataclass': classType.isDataclass,
        'attrs': _attrsJson(classType.attrs),
      },
      'instance_id': instanceId,
      'attrs': _attrsJson(attrs),
    },
  MontyDataclass(
    :final name,
    :final typeId,
    :final fieldNames,
    :final attrs,
    :final frozen,
  ) =>
    <String, Object?>{
      '__type': 'dataclass',
      'name': name,
      'type_id': typeId,
      'field_names': fieldNames,
      'attrs': _attrsJson(attrs),
      'frozen': frozen,
    },
  _ => v.toJson(),
};

/// `v.dartValue` as the old classes computed it.
Object? legacyDartValue(MontyValue v) => switch (v) {
  MontyList(:final items) ||
  MontyTuple(:final items) ||
  MontySet(:final items) ||
  MontyFrozenSet(:final items) => items.map(legacyDartValue).toList(),
  MontyDict(:final pairs) => switch (v.asStringMap) {
    final strings? => strings.map((k, x) => MapEntry(k, legacyDartValue(x))),
    null => [
      for (final (k, x) in pairs) [legacyDartValue(k), legacyDartValue(x)],
    ],
  },
  MontyNamedTuple() ||
  MontyClassInstance() ||
  MontyDataclass() => legacyToJson(v),
  _ => v.dartValue,
};

/// `dartAttrs` as the old classes computed it.
Map<String, Object?> legacyDartAttrs(Map<String, MontyValue> attrs) =>
    attrs.map((k, v) => MapEntry(k, legacyDartValue(v)));
