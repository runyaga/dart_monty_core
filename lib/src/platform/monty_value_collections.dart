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

/// Represents a Python `dict` value, with keys of any type.
///
/// Python allows any hashable key; JSON objects allow only strings. That is a
/// constraint on the WIRE, and it stays there: a dict travels as
/// `{"__type": "dict", "value": {…}}` when every key is a string and
/// `{"__type": "dict", "entries": [[k, v], …]}` otherwise. Both arrive here as
/// one Dart type.
///
/// It used to be two — `MontyDict` for string keys and `MontyPairsDict` for
/// anything else — and the split cost more than it bought:
///
/// - **The Dart type depended on the DATA.** Adding one `int` key to an
///   otherwise string-keyed dict changed the class of the whole value, so
///   `{'a': 1}` and `{'a': 1, 2: 'b'}` were different types with nothing in the
///   type system marking the boundary. Same shape as core#134, where a type
///   depended on a value's magnitude.
/// - **One Python dict had two unequal Dart spellings.** The pairs form of
///   `{'a': 1}` was never `==` to the map form, and each round-tripped to
///   itself, so nothing normalised them.
/// - **Equality contradicted Python.** Pairs were a `List`, so `==` was
///   order-sensitive: `{1:'a',2:'b'}` and `{2:'b',1:'a'}` compared unequal
///   where Python — and `dict__ops.py`, in the corpus — say they are equal.
/// - **It could express dicts Python cannot hold**: duplicate keys, because a
///   `List` does not deduplicate.
///
/// A `Map` keyed by [MontyValue] fixes all four at once. Keys deduplicate by
/// [MontyValue] equality, which is structural and type-aware — `MontyInt(1)`
/// and `MontyString('1')` stay distinct — and map equality is
/// order-insensitive, which is Python's rule.
///
/// Reading a string-keyed dict costs an explicit wrap:
/// `entries[MontyString(k)]`. Building one has [MontyDict.ofStrings].
@immutable
final class MontyDict extends MontyValue {
  /// Creates a [MontyDict] with the given [entries].
  const MontyDict(this.entries);

  /// Creates a [MontyDict] from string keys — the overwhelmingly common case.
  ///
  /// `MontyDict.ofStrings({'a': MontyInt(1)})` is
  /// `MontyDict({MontyString('a'): MontyInt(1)})`.
  factory MontyDict.ofStrings(Map<String, MontyValue> entries) => MontyDict({
    for (final MapEntry(:key, :value) in entries.entries)
      MontyString(key): value,
  });

  factory MontyDict._fromMap(Map<String, dynamic> map) {
    final payload = map['value'];
    if (payload is! Map<String, dynamic>) {
      throw FormatException(
        'a dict envelope needs an object under "value" (string keys) or an '
        'array under "entries" (any keys); got ${payload.runtimeType}',
        json.encode(map),
      );
    }

    // The payload's keys are DATA. They are read as dict keys and never
    // dispatched on, which is the whole of the core#136 fix: a Python dict
    // containing the key `__type` is a dict with an odd key, not a mint.
    return MontyDict({
      for (final MapEntry(:key, :value) in payload.entries)
        MontyString(key): MontyValue.fromJson(value),
    });
  }

  factory MontyDict._fromEntries(List<dynamic> raw) {
    final out = <MontyValue, MontyValue>{};
    for (final entry in raw) {
      if (entry case [final k, final v]) {
        out[MontyValue.fromJson(k)] = MontyValue.fromJson(v);
      } else {
        throw FormatException(
          'each dict entry must be a [key, value] pair; got $entry',
          json.encode(raw),
        );
      }
    }

    return MontyDict(out);
  }

  /// The entries, keyed by [MontyValue], in Python insertion order.
  ///
  /// Iteration order is preserved (Dart's default `Map` is insertion-ordered),
  /// but it is deliberately NOT part of [operator ==] — Python dicts compare
  /// equal regardless of order.
  final Map<MontyValue, MontyValue> entries;

  @override
  Map<String, Object?> toJson() {
    // Which payload shape depends on the KEYS, not on the Dart type — that is
    // what lets one type serve both wire forms without a version bump. The
    // all-string case must stay `value`, because that is what the Rust decoder
    // reads first (convert.rs:268) and what every existing fixture expects.
    //
    // Two passes rather than one with an early return: the single-pass version
    // nested a second `MapEntry(:key, :value)` destructure inside the first and
    // shadowed both names, which DCM flagged and which was genuinely harder to
    // read than the extra walk costs.
    if (entries.keys.every((k) => k is MontyString)) {
      return {
        '__type': 'dict',
        'value': {
          for (final MapEntry(:key, :value) in entries.entries)
            (key as MontyString).value: value.toJson(),
        },
      };
    }

    return {
      '__type': 'dict',
      'entries': [
        for (final MapEntry(:key, :value) in entries.entries)
          [key.toJson(), value.toJson()],
      ],
    };
  }

  /// The entries as a plain Dart map, keys and values recursively unwrapped.
  ///
  /// Throws [StateError] when unwrapping would MERGE two distinct keys.
  /// [MontyValue] equality is type-aware but Dart's is not: `MontyInt(1)` and
  /// `MontyFloat(1)` are different keys here, and `1 == 1.0` in Dart, so a
  /// naive unwrap would silently drop one entry. Unreachable for values that
  /// came off the wire — the interpreter collapses such keys before encoding,
  /// exactly as CPython does — but a host-built dict can reach it, and dropping
  /// data quietly is the failure mode this whole value layer exists to prevent.
  @override
  Map<Object?, Object?> get dartValue {
    final out = <Object?, Object?>{};
    for (final MapEntry(:key, :value) in entries.entries) {
      final k = key.dartValue;
      if (out.containsKey(k)) {
        throw StateError(
          'dartValue would merge two distinct dict keys that compare equal as '
          'plain Dart values: $key collides with an earlier key unwrapping to '
          '$k. Read `entries` instead, which keeps them apart.',
        );
      }
      out[k] = value.dartValue;
    }

    return out;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyDict && _deepEq.equals(other.entries, entries));

  @override
  int get hashCode => _deepEq.hash(entries);

  @override
  String toString() => 'MontyDict(${entries.length} entries)';
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
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontySet && _deepEq.equals(other.items, items));

  @override
  int get hashCode => _deepEq.hash(items);

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
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyFrozenSet && _deepEq.equals(other.items, items));

  @override
  int get hashCode => _deepEq.hash(items);

  @override
  String toString() => 'MontyFrozenSet(${items.length} items)';
}
