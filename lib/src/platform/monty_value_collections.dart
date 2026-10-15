part of 'monty_value.dart';

// ---------------------------------------------------------------------------
// Collections
// ---------------------------------------------------------------------------

/// Represents a Python `bytes` value.
@immutable
final class MontyBytes extends MontyValue {
  /// Creates a [MontyBytes] with the given byte [value].
  const MontyBytes(this.value);

  /// The underlying list of byte values.
  final List<int> value;

  @override
  List<int> get dartValue => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyBytes && _deepEq.equals(other.value, value));

  @override
  int get hashCode => _deepEq.hash(value);

  @override
  String toString() => 'MontyBytes(${value.length} bytes)';

  @override
  Map<String, Object?> _toJson() => {'__type': 'bytes', 'value': value};
}

/// Represents a Python `list` value.
@immutable
final class MontyList extends MontyValue {
  /// Creates a [MontyList] with the given [items].
  const MontyList(this.items);

  /// The list of [MontyValue] items.
  final List<MontyValue> items;

  @override
  int get _graphKind => _kList;

  // toJson, dartValue, == and hashCode walk the value as a graph: a node
  // shared by several parents is visited once, deep nesting cannot overflow
  // the stack, and a value that contains itself is a StateError (except that
  // it equals itself). See monty_value_graph.dart.

  @override
  List<Object?> get dartValue =>
      _MontyValueGraph.nodeDartValue(this) as List<Object?>;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyList && _MontyValueGraph.equals(this, other));

  @override
  int get hashCode => _MontyValueGraph.hash(this);

  @override
  String toString() => 'MontyList(${items.length} items)';

  @override
  List<Object?> _toJson() => _MontyValueGraph.nodeToJson(this) as List<Object?>;
}

/// Represents a Python `tuple` value.
@immutable
final class MontyTuple extends MontyValue {
  /// Creates a [MontyTuple] with the given [items].
  const MontyTuple(this.items);

  /// The list of [MontyValue] items in the tuple.
  final List<MontyValue> items;

  @override
  int get _graphKind => _kTuple;

  @override
  List<Object?> get dartValue =>
      _MontyValueGraph.nodeDartValue(this) as List<Object?>;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      ((other is MontyTuple || other is MontyNamedTuple) &&
          _MontyValueGraph.equals(this, other));

  @override
  int get hashCode => _MontyValueGraph.hash(this);

  @override
  String toString() => 'MontyTuple(${items.length} items)';

  @override
  Map<String, Object?> _toJson() =>
      _MontyValueGraph.nodeToJson(this) as Map<String, Object?>;
}

/// Represents a Python `dict` value.
///
/// Holds insertion-ordered `(key, value)` pairs — the shape monty itself uses
/// (`DictPairs(Vec<(MontyObject, MontyObject)>)`). Python allows any hashable
/// key, so keys are [MontyValue]s, not strings.
///
/// TWO WIRE SHAPES, ONE TYPE. An all-string-keyed dict travels as
/// `{"__type": "dict", "value": {…}}`; any other dict travels as
/// `{"__type": "dict", "entries": [[k, v], …]}`. That is a transport detail of
/// the sending side, not a difference in the value, and this type does not
/// expose it.
///
/// It used to. The two shapes decoded as two classes, `MontyDict` and
/// `MontyPairsDict`, whose `==` disagreed: one compared as a `Map`
/// (order-insensitive), the other as a `List` (order-sensitive). So two objects
/// standing for the same Python dict compared UNEQUAL purely because its keys
/// were not strings, and which semantics a caller got was decided by the data.
/// The sandbox's own `==` is order-insensitive for both shapes
/// (`crates/monty/src/types/dict.rs`: a length check plus a per-key lookup), so
/// the split contradicted the language being bound.
///
/// Keys compare as Python's do: `{1: 'a'}` and `{True: 'a'}` are the same
/// dict. A dict built here with two equal keys compares as the dict Python
/// builds from the same pairs: the first key, with the last value.
@immutable
final class MontyDict extends MontyValue {
  /// Creates a [MontyDict] from insertion-ordered [pairs].
  const MontyDict(this.pairs);

  /// The (key, value) pairs, in Python insertion order.
  final List<(MontyValue, MontyValue)> pairs;

  /// A `Map<String, Object?>` when every key is a string, else a list of
  /// two-element `[key, value]` lists.
  ///
  /// The shape is conditional on key type ON PURPOSE, and this is a projection
  /// to plain Dart, not a type distinction — the TYPE is the same either way.
  /// Stringifying keys merges distinct Python keys: `{1: 'a'}` and `{'1': 'b'}`
  /// would collapse into one map entry and silently lose the other. The pair
  /// list preserves both.
  @override
  Object? get dartValue => _MontyValueGraph.nodeDartValue(this);

  // Order-insensitive, matching the sandbox: each key with the value it keeps
  // (Python's construction: equal keys collapse to the first, holding the
  // last value). Commutative hash over those entries, so equal dicts hash
  // equally whatever order their pairs arrived in.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyDict && _MontyValueGraph.equals(this, other));

  @override
  int get hashCode => _MontyValueGraph.hash(this);

  @override
  String toString() => 'MontyDict(${pairs.length} entries)';

  /// Mirrors the encoder on the Rust side: string-keyed dicts take the compact
  /// object form, everything else the entries form.
  @override
  Map<String, Object?> _toJson() =>
      _MontyValueGraph.nodeToJson(this) as Map<String, Object?>;
}

/// Represents a Python `set` value.
@immutable
final class MontySet extends MontyValue {
  /// Creates a [MontySet] with the given [items].
  const MontySet(this.items);

  /// The list of [MontyValue] items in the set.
  final List<MontyValue> items;

  @override
  int get _graphKind => _kSet;

  @override
  List<Object?> get dartValue =>
      _MontyValueGraph.nodeDartValue(this) as List<Object?>;

  @override
  // Order-insensitive, matching the sandbox. `crates/monty/src/types/set.rs`
  // compares sets with a length check plus a per-element `contains` (:412),
  // and hashes a frozenset by XORing element hashes because "XOR is
  // commutative, so the hash is independent of insertion order" (:1435).
  // Comparing `items` as a LIST contradicted both: `{1, 2}` and `{2, 1}` --
  // the same set in Python -- were unequal, and hashed differently.
  //
  // This is the same defect the two dict classes had (see [MontyDict]); the
  // sets were simply left behind when that one was fixed. A set built here
  // with two equal members compares as the set Python builds from them: by
  // its distinct members, and a set equals a frozenset of the same members.
  //
  // `+` over the distinct members' hashes: equal sets sum the same hashes,
  // whatever duplicates either was built with. Each element hash is mixed
  // before the sum, so small consecutive element hashes
  // rarely collide.
  bool operator ==(Object other) =>
      identical(this, other) ||
      ((other is MontySet || other is MontyFrozenSet) &&
          _MontyValueGraph.equals(this, other));

  @override
  int get hashCode => _MontyValueGraph.hash(this);

  @override
  String toString() => 'MontySet(${items.length} items)';

  @override
  Map<String, Object?> _toJson() =>
      _MontyValueGraph.nodeToJson(this) as Map<String, Object?>;
}

/// Represents a Python `frozenset` value.
@immutable
final class MontyFrozenSet extends MontyValue {
  /// Creates a [MontyFrozenSet] with the given [items].
  const MontyFrozenSet(this.items);

  /// The list of [MontyValue] items in the frozen set.
  final List<MontyValue> items;

  @override
  int get _graphKind => _kFrozenSet;

  @override
  List<Object?> get dartValue =>
      _MontyValueGraph.nodeDartValue(this) as List<Object?>;

  @override
  // Order-insensitive, matching the sandbox. `crates/monty/src/types/set.rs`
  // compares sets with a length check plus a per-element `contains` (:412),
  // and hashes a frozenset by XORing element hashes because "XOR is
  // commutative, so the hash is independent of insertion order" (:1435).
  // Comparing `items` as a LIST contradicted both: `{1, 2}` and `{2, 1}` --
  // the same set in Python -- were unequal, and hashed differently.
  //
  // This is the same defect the two dict classes had (see [MontyDict]); the
  // sets were simply left behind when that one was fixed. A set built here
  // with two equal members compares as the set Python builds from them: by
  // its distinct members, and a set equals a frozenset of the same members.
  //
  // `+` over the distinct members' hashes: equal sets sum the same hashes,
  // whatever duplicates either was built with. Each element hash is mixed
  // before the sum, so small consecutive element hashes
  // rarely collide.
  bool operator ==(Object other) =>
      identical(this, other) ||
      ((other is MontyFrozenSet || other is MontySet) &&
          _MontyValueGraph.equals(this, other));

  @override
  int get hashCode => _MontyValueGraph.hash(this);

  @override
  String toString() => 'MontyFrozenSet(${items.length} items)';

  @override
  Map<String, Object?> _toJson() =>
      _MontyValueGraph.nodeToJson(this) as Map<String, Object?>;
}
