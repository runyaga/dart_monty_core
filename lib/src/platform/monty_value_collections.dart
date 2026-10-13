part of 'monty_value.dart';

// ---------------------------------------------------------------------------
// Collections
// ---------------------------------------------------------------------------

/// Represents a Python `bytes` value.
@immutable
final class MontyBytes extends MontyValue {
  /// Creates a [MontyBytes] with the given byte [value].
  const MontyBytes(this.value);

  factory MontyBytes._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<Object?>? ?? const [];

    return MontyBytes(raw.cast<num>().map((n) => n.toInt()).toList());
  }

  /// The underlying list of byte values.
  final List<int> value;

  @override
  Map<String, Object?> toJson() => {'__type': 'bytes', 'value': value};

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
  List<Object?> toJson() => _MontyValueGraph.nodeToJson(this) as List<Object?>;

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
}

/// Represents a Python `tuple` value.
@immutable
final class MontyTuple extends MontyValue {
  /// Creates a [MontyTuple] with the given [items].
  const MontyTuple(this.items);

  factory MontyTuple._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<Object?>? ?? const [];

    return MontyTuple(raw.map(MontyValue.fromJson).toList());
  }

  /// The list of [MontyValue] items in the tuple.
  final List<MontyValue> items;

  @override
  int get _graphKind => _kTuple;

  @override
  Map<String, Object?> toJson() =>
      _MontyValueGraph.nodeToJson(this) as Map<String, Object?>;

  @override
  List<Object?> get dartValue =>
      _MontyValueGraph.nodeDartValue(this) as List<Object?>;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyTuple && _MontyValueGraph.equals(this, other));

  @override
  int get hashCode => _MontyValueGraph.hash(this);

  @override
  String toString() => 'MontyTuple(${items.length} items)';
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
/// Key comparison is by exact [MontyValue] subtype, so `{1: 'a'}` and
/// `{True: 'a'}` — the same dict in Python — are unequal here. That is a
/// property of every `MontyValue` and not of this type; the wire preserves the
/// int/float/bool distinction on purpose.
@immutable
final class MontyDict extends MontyValue {
  /// Creates a [MontyDict] from insertion-ordered [pairs].
  const MontyDict(this.pairs);

  /// Creates a [MontyDict] from a string-keyed map.
  ///
  /// For the common case and for encoding attribute maps, which Python
  /// guarantees are string-keyed.
  factory MontyDict.ofStrings(Map<String, MontyValue> entries) => MontyDict([
    for (final MapEntry(:key, :value) in entries.entries)
      (MontyString(key), value),
  ]);

  factory MontyDict._fromMap(Map<String, dynamic> map) {
    final entries = map['entries'];
    if (entries is List<Object?>) return MontyDict._fromEntries(entries);

    final payload = map['value'];
    if (payload is! Map<String, dynamic>) {
      throw FormatException(
        'a dict envelope needs an object under "value" or a list under '
        '"entries"; got ${payload.runtimeType}.',
        json.encode(map),
      );
    }

    // The payload's keys are DATA. They are read as dict keys and never
    // dispatched on, which is the whole of the core#136 fix: a Python dict
    // containing the key `__type` is a dict with an odd key, not a mint.
    return MontyDict([
      for (final MapEntry(:key, :value) in payload.entries)
        (MontyString(key), MontyValue.fromJson(value)),
    ]);
  }

  factory MontyDict._fromEntries(List<Object?> raw) => MontyDict([
    for (final entry in raw)
      if (entry case [final k, final v])
        (MontyValue.fromJson(k), MontyValue.fromJson(v))
      else
        throw FormatException(
          'each dict entry must be a [key, value] pair; got $entry',
          json.encode(raw),
        ),
  ]);

  /// The (key, value) pairs, in Python insertion order.
  final List<(MontyValue, MontyValue)> pairs;

  /// The number of entries.
  int get length => pairs.length;

  /// Whether this dict has no entries.
  bool get isEmpty => pairs.isEmpty;

  /// Whether this dict has at least one entry.
  bool get isNotEmpty => pairs.isNotEmpty;

  /// The keys, in insertion order.
  Iterable<MontyValue> get keys => pairs.map((p) => p.$1);

  /// The values, in insertion order.
  Iterable<MontyValue> get values => pairs.map((p) => p.$2);

  /// This dict as a string-keyed map, or `null` when any key is not a
  /// [MontyString].
  ///
  /// Nullable on purpose. Python dicts routinely carry non-string keys, so a
  /// caller wanting `Map<String, …>` is making an assumption — this makes it an
  /// explicit decision at the call site rather than a cast that throws.
  Map<String, MontyValue>? get asStringMap {
    final out = <String, MontyValue>{};
    for (final (k, v) in pairs) {
      if (k is! MontyString) return null;
      out[k.value] = v;
    }

    return out;
  }

  /// Mirrors the encoder on the Rust side: string-keyed dicts take the compact
  /// object form, everything else the entries form.
  @override
  Map<String, Object?> toJson() =>
      _MontyValueGraph.nodeToJson(this) as Map<String, Object?>;

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

  // Order-insensitive, matching the sandbox: the (key, value) pairs compare as
  // a multiset, so a dict built with a duplicate key compares as it always
  // did. Commutative hash: equal dicts hash equally whatever order their pairs
  // arrived in.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyDict && _MontyValueGraph.equals(this, other));

  @override
  int get hashCode => _MontyValueGraph.hash(this);

  @override
  String toString() => 'MontyDict(${pairs.length} entries)';
}

/// Represents a Python `set` value.
@immutable
final class MontySet extends MontyValue {
  /// Creates a [MontySet] with the given [items].
  const MontySet(this.items);

  factory MontySet._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<Object?>? ?? const [];

    return MontySet(raw.map(MontyValue.fromJson).toList());
  }

  /// The list of [MontyValue] items in the set.
  final List<MontyValue> items;

  @override
  int get _graphKind => _kSet;

  @override
  Map<String, Object?> toJson() =>
      _MontyValueGraph.nodeToJson(this) as Map<String, Object?>;

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
  // sets were simply left behind when that one was fixed. Monty collapses
  // equal elements before the value reaches the wire, so multiset equality is
  // exactly set equality here.
  //
  // `+` rather than upstream's XOR on purpose: XOR cancels duplicates, so a
  // forged `{"__type": "set", "value": [1, 1]}` would hash like the EMPTY set.
  // Both are commutative; only one of them survives a hostile payload. Each
  // element hash is mixed before the sum, so small consecutive element hashes
  // rarely collide.
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontySet && _MontyValueGraph.equals(this, other));

  @override
  int get hashCode => _MontyValueGraph.hash(this);

  @override
  String toString() => 'MontySet(${items.length} items)';
}

/// Represents a Python `frozenset` value.
@immutable
final class MontyFrozenSet extends MontyValue {
  /// Creates a [MontyFrozenSet] with the given [items].
  const MontyFrozenSet(this.items);

  factory MontyFrozenSet._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<Object?>? ?? const [];

    return MontyFrozenSet(raw.map(MontyValue.fromJson).toList());
  }

  /// The list of [MontyValue] items in the frozen set.
  final List<MontyValue> items;

  @override
  int get _graphKind => _kFrozenSet;

  @override
  Map<String, Object?> toJson() =>
      _MontyValueGraph.nodeToJson(this) as Map<String, Object?>;

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
  // sets were simply left behind when that one was fixed. Monty collapses
  // equal elements before the value reaches the wire, so multiset equality is
  // exactly set equality here.
  //
  // `+` rather than upstream's XOR on purpose: XOR cancels duplicates, so a
  // forged `{"__type": "set", "value": [1, 1]}` would hash like the EMPTY set.
  // Both are commutative; only one of them survives a hostile payload. Each
  // element hash is mixed before the sum, so small consecutive element hashes
  // rarely collide.
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyFrozenSet && _MontyValueGraph.equals(this, other));

  @override
  int get hashCode => _MontyValueGraph.hash(this);

  @override
  String toString() => 'MontyFrozenSet(${items.length} items)';
}
