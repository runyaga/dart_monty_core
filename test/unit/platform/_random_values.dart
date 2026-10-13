// Random MontyValue graphs for the equivalence tests: trees, and DAGs that
// reuse earlier nodes. Deterministic for a given Random seed.
import 'dart:math';

import 'package:dart_monty_core/dart_monty_core.dart';

/// Builds random values. With [share] true, containers may reuse a node
/// built earlier, so the result is a DAG.
final class RandomValues {
  RandomValues(this.r, {this.share = false});

  final Random r;
  final bool share;
  final List<MontyValue> _pool = [];

  static const _classA = MontyClassType(
    name: 'A',
    id: '00000000-0000-0000-0000-00000000000a',
    hostDefined: false,
    isDataclass: true,
    attrs: {'k': MontyInt(1)},
  );

  /// One of [options], chosen by [r] (one `nextInt` draw).
  T pick<T>(List<T> options) {
    var i = r.nextInt(options.length);
    for (final o in options) {
      if (i-- == 0) return o;
    }

    throw StateError('no options');
  }

  MontyValue scalar() => switch (r.nextInt(14)) {
    0 => MontyInt(r.nextInt(3)),
    1 => MontyString(pick(['a', 'b', ''])),
    2 => const MontyNone(),
    3 => MontyFloat(
      pick([0.0, -0.0, 1.5, 1.0, double.nan, double.infinity]),
    ),
    4 => MontyBool(r.nextBool()),
    5 => MontyBigInt(BigInt.from(r.nextInt(3))),
    6 => MontyBigInt(BigInt.parse('1${'0' * 30}') + BigInt.from(r.nextInt(2))),
    7 => MontyBytes([for (var i = 0; i < r.nextInt(3); i++) r.nextInt(3)]),
    8 => MontyExceptionValue(
      excType: pick(['ValueError', 'KeyError']),
      message: r.nextBool() ? null : 'm',
    ),
    9 => MontyPath(pick(['a/b', 'c'])),
    10 => MontyDate(year: 2024, month: 1, day: r.nextInt(2) + 1),
    11 => const MontyEllipsis(),
    12 => MontyTimeZone(offsetSeconds: r.nextInt(2) * 3600, name: 'z'),
    _ => MontyOpaque(MontyOpaqueKind.repr, pick(['<x>', '<y>'])),
  };

  MontyValue value(int depth) {
    if (share && _pool.isNotEmpty && r.nextInt(4) == 0) {
      return pick(_pool);
    }
    final v = depth == 0 ? scalar() : _container(depth);
    if (share && depth > 0) _pool.add(v);

    return v;
  }

  List<MontyValue> _items(int depth) => [
    for (var i = 0; i < r.nextInt(4); i++) value(depth - 1),
  ];

  Map<String, MontyValue> _attrs(int depth) => {
    for (var i = 0; i < r.nextInt(3); i++) 'a$i': value(depth - 1),
  };

  MontyValue _container(int depth) => switch (r.nextInt(12)) {
    0 || 1 => scalar(),
    2 => MontyList(_items(depth)),
    3 => MontyTuple(_items(depth)),
    // Set elements are hashable values: scalars and tuples of them, with an
    // occasional duplicate, which the old multiset comparison accepted.
    4 => MontySet(_setItems(depth)),
    5 => MontyFrozenSet(_setItems(depth)),
    6 || 7 => MontyDict([
      for (var i = 0, n = _size(depth); i < n; i++) (_key(), value(depth - 1)),
    ]),
    8 => MontyNamedTuple(
      typeName: pick(['P', 'Q']),
      fieldNames: const ['x', 'y'],
      values: [value(depth - 1), value(depth - 1)],
    ),
    9 => MontyClassInstance(
      classType: r.nextBool()
          ? _classA
          : MontyClassType(
              name: 'B',
              id: '00000000-0000-0000-0000-00000000000b',
              hostDefined: r.nextBool(),
              isDataclass: false,
              attrs: _attrs(depth),
            ),
      instanceId: pick(['i1', 'i2']),
      attrs: _attrs(depth),
    ),
    10 => MontyDataclass(
      name: 'D',
      typeId: r.nextInt(2),
      fieldNames: const ['a0', 'a1'],
      attrs: _attrs(depth),
      frozen: r.nextBool(),
    ),
    _ => MontyList([value(depth - 1), value(depth - 1)]),
  };

  MontyValue _key() {
    if (r.nextInt(3) == 0) return _pair();

    return r.nextBool() ? MontyString(pick(['a', 'b', 'c'])) : scalar();
  }

  /// Mostly 0-3 elements; near the leaves, sometimes 9-12, past the size
  /// below which sets and dicts are matched by scanning instead of hashing.
  int _size(int depth) =>
      depth <= 1 && r.nextInt(4) == 0 ? r.nextInt(4) + 9 : r.nextInt(4);

  List<MontyValue> _setItems(int depth) => [
    for (var i = 0, n = _size(depth); i < n; i++)
      if (r.nextInt(3) == 0) _pair() else scalar(),
  ];

  /// A hashable tuple of two scalars.
  MontyTuple _pair() => MontyTuple([for (var i = 0; i < 2; i++) scalar()]);
}

/// A copy with no node shared with [v], and no sharing inside it: the tree
/// expansion of a DAG. Sets and dicts are reversed, which equality ignores.
MontyValue cloneReversed(MontyValue v) => switch (v) {
  MontyList(:final items) => MontyList([
    for (final c in items) cloneReversed(c),
  ]),
  MontyTuple(:final items) => MontyTuple([
    for (final c in items) cloneReversed(c),
  ]),
  MontySet(:final items) => MontySet([
    for (final c in items.reversed) cloneReversed(c),
  ]),
  MontyFrozenSet(:final items) => MontyFrozenSet([
    for (final c in items.reversed) cloneReversed(c),
  ]),
  MontyDict(:final pairs) => MontyDict([
    for (final (k, x) in pairs.reversed) (cloneReversed(k), cloneReversed(x)),
  ]),
  MontyNamedTuple(:final typeName, :final fieldNames, :final values) =>
    MontyNamedTuple(
      typeName: typeName,
      fieldNames: [...fieldNames],
      values: [for (final c in values) cloneReversed(c)],
    ),
  MontyClassInstance(:final classType, :final instanceId, :final attrs) =>
    MontyClassInstance(
      classType: MontyClassType(
        name: classType.name,
        id: classType.id,
        hostDefined: classType.hostDefined,
        isDataclass: classType.isDataclass,
        attrs: _cloneAttrs(classType.attrs),
      ),
      instanceId: instanceId,
      attrs: _cloneAttrs(attrs),
    ),
  MontyDataclass(
    :final name,
    :final typeId,
    :final fieldNames,
    :final attrs,
    :final frozen,
  ) =>
    MontyDataclass(
      name: name,
      typeId: typeId,
      fieldNames: [...fieldNames],
      attrs: _cloneAttrs(attrs),
      frozen: frozen,
    ),
  MontyInt(:final value) => MontyInt(value),
  MontyString(:final value) => MontyString(value),
  MontyFloat(:final value) => MontyFloat(value),
  MontyBigInt(:final value) => MontyBigInt(value),
  MontyBytes(:final value) => MontyBytes([...value]),
  _ => v,
};

Map<String, MontyValue> _cloneAttrs(Map<String, MontyValue> m) => {
  for (final MapEntry(:key, :value) in m.entries) key: cloneReversed(value),
};

/// A copy of [v] with one leaf replaced by a different one, chosen by [r].
/// Usually unequal to [v]; the tests do not assume it.
MontyValue mutate(MontyValue v, Random r) {
  MontyValue go(MontyValue x) => switch (x) {
    MontyList(:final items) when items.isNotEmpty => MontyList(_one(items)),
    MontyTuple(:final items) when items.isNotEmpty => MontyTuple(_one(items)),
    MontySet(:final items) when items.isNotEmpty => MontySet(_one(items)),
    MontyFrozenSet(:final items) when items.isNotEmpty => MontyFrozenSet(
      _one(items),
    ),
    MontyDict(:final pairs) when pairs.isNotEmpty => MontyDict([
      for (final (i, (k, value)) in pairs.indexed)
        if (i == 0) (k, go(value)) else (k, value),
    ]),
    MontyNamedTuple(:final typeName, :final fieldNames, :final values) =>
      MontyNamedTuple(
        typeName: typeName,
        fieldNames: fieldNames,
        values: _one(values),
      ),
    _ => x is MontyInt ? MontyInt(x.value + 1) : MontyInt(r.nextInt(2) + 7),
  };

  return go(v);
}

List<MontyValue> _one(List<MontyValue> xs) => [
  for (final (i, x) in xs.indexed)
    if (i == xs.length - 1) mutate(x, Random(i)) else x,
];
