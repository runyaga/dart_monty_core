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
    final raw = map['value'] as List<dynamic>? ?? const [];

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
  List<Object?> toJson() => items.map((e) => e.toJson()).toList();

  @override
  List<Object?> get dartValue => items.map((e) => e.dartValue).toList();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyList && _deepEq.equals(other.items, items));

  @override
  int get hashCode => _deepEq.hash(items);

  @override
  String toString() => 'MontyList(${items.length} items)';
}

/// Represents a Python `tuple` value.
@immutable
final class MontyTuple extends MontyValue {
  /// Creates a [MontyTuple] with the given [items].
  const MontyTuple(this.items);

  factory MontyTuple._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<dynamic>? ?? const [];

    return MontyTuple(raw.map(MontyValue.fromJson).toList());
  }

  /// The list of [MontyValue] items in the tuple.
  final List<MontyValue> items;

  @override
  Map<String, Object?> toJson() => {
    '__type': 'tuple',
    'value': items.map((e) => e.toJson()).toList(),
  };

  @override
  List<Object?> get dartValue => items.map((e) => e.dartValue).toList();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyTuple && _deepEq.equals(other.items, items));

  @override
  int get hashCode => _deepEq.hash(items);

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
    if (entries is List<dynamic>) return MontyDict._fromEntries(entries);

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

  factory MontyDict._fromEntries(List<dynamic> raw) => MontyDict([
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

  @override
  Map<String, Object?> toJson() {
    // Mirror the encoder on the Rust side: string-keyed dicts take the compact
    // object form, everything else the entries form. Keeps the wire
    // byte-identical to what the two classes emitted.
    final strings = asStringMap;
    if (strings != null) {
      return {
        '__type': 'dict',
        'value': strings.map((k, v) => MapEntry(k, v.toJson())),
      };
    }

    return {
      '__type': 'dict',
      'entries': [
        for (final (k, v) in pairs) [k.toJson(), v.toJson()],
      ],
    };
  }

  /// A `Map<String, Object?>` when every key is a string, else a list of
  /// two-element `[key, value]` lists.
  ///
  /// The shape is conditional on key type ON PURPOSE, and this is a projection
  /// to plain Dart, not a type distinction — the TYPE is the same either way.
  /// Stringifying keys merges distinct Python keys: `{1: 'a'}` and `{'1': 'b'}`
  /// would collapse into one map entry and silently lose the other. The pair
  /// list preserves both.
  @override
  Object? get dartValue {
    final strings = asStringMap;
    if (strings != null) {
      return strings.map((k, v) => MapEntry(k, v.dartValue));
    }

    return [
      for (final (k, v) in pairs) [k.dartValue, v.dartValue],
    ];
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MontyDict || other.pairs.length != pairs.length) return false;

    // Order-insensitive, matching the sandbox. Monty collapses equal keys
    // before the value ever reaches the wire, so no two pairs share a key and
    // multiset equality is exactly key-mapping equality.
    //
    // Records compare structurally, so `remove` matches a pair by both halves.
    // Consuming each match is what keeps this a MULTISET comparison rather than
    // a subset test.
    final remaining = [...other.pairs];
    for (final pair in pairs) {
      if (!remaining.remove(pair)) return false;
    }

    return remaining.isEmpty;
  }

  @override
  // Commutative on purpose: equal dicts must hash equally whatever order their
  // pairs arrived in, so this folds with `+` rather than hashing the list.
  int get hashCode => pairs.fold(
    0,
    (acc, p) => acc + Object.hash(p.$1, p.$2),
  );

  @override
  String toString() => 'MontyDict(${pairs.length} entries)';
}

/// Represents a Python `set` value.
@immutable
final class MontySet extends MontyValue {
  /// Creates a [MontySet] with the given [items].
  const MontySet(this.items);

  factory MontySet._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<dynamic>? ?? const [];

    return MontySet(raw.map(MontyValue.fromJson).toList());
  }

  /// The list of [MontyValue] items in the set.
  final List<MontyValue> items;

  @override
  Map<String, Object?> toJson() => {
    '__type': 'set',
    'value': items.map((e) => e.toJson()).toList(),
  };

  @override
  List<Object?> get dartValue => items.map((e) => e.dartValue).toList();

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
  // Both are commutative; only one of them survives a hostile payload.
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MontySet || other.items.length != items.length) return false;

    final remaining = [...other.items];
    for (final item in items) {
      if (!remaining.remove(item)) return false;
    }

    return remaining.isEmpty;
  }

  @override
  int get hashCode => items.fold(0, (acc, e) => acc + e.hashCode);

  @override
  String toString() => 'MontySet(${items.length} items)';
}

/// Represents a Python `frozenset` value.
@immutable
final class MontyFrozenSet extends MontyValue {
  /// Creates a [MontyFrozenSet] with the given [items].
  const MontyFrozenSet(this.items);

  factory MontyFrozenSet._fromMap(Map<String, dynamic> map) {
    final raw = map['value'] as List<dynamic>? ?? const [];

    return MontyFrozenSet(raw.map(MontyValue.fromJson).toList());
  }

  /// The list of [MontyValue] items in the frozen set.
  final List<MontyValue> items;

  @override
  Map<String, Object?> toJson() => {
    '__type': 'frozenset',
    'value': items.map((e) => e.toJson()).toList(),
  };

  @override
  List<Object?> get dartValue => items.map((e) => e.dartValue).toList();

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
  // Both are commutative; only one of them survives a hostile payload.
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! MontyFrozenSet || other.items.length != items.length) {
      return false;
    }

    final remaining = [...other.items];
    for (final item in items) {
      if (!remaining.remove(item)) return false;
    }

    return remaining.isEmpty;
  }

  @override
  int get hashCode => items.fold(0, (acc, e) => acc + e.hashCode);

  @override
  String toString() => 'MontyFrozenSet(${items.length} items)';
}
