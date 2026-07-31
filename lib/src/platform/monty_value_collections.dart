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
@immutable
final class MontyDict extends MontyValue {
  /// Creates a [MontyDict] with the given [entries].
  const MontyDict(this.entries);

  factory MontyDict._fromMap(Map<String, dynamic> map) {
    final payload = map['value'];
    if (payload is! Map<String, dynamic>) {
      throw FormatException(
        'a dict envelope needs an object under "value"; got '
        '${payload.runtimeType}. Non-string keys travel under "entries" and '
        'decode as MontyPairsDict.',
        json.encode(map),
      );
    }

    // The payload's keys are DATA. They are read as dict keys and never
    // dispatched on, which is the whole of the core#136 fix: a Python dict
    // containing the key `__type` is a dict with an odd key, not a mint.
    return MontyDict(
      payload.map((k, v) => MapEntry(k, MontyValue.fromJson(v))),
    );
  }

  /// The map of string keys to [MontyValue] values.
  final Map<String, MontyValue> entries;

  @override
  Map<String, Object?> toJson() => {
    '__type': 'dict',
    'value': entries.map((k, v) => MapEntry(k, v.toJson())),
  };

  @override
  Map<String, Object?> get dartValue =>
      entries.map((k, v) => MapEntry(k, v.dartValue));

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyDict && _deepEq.equals(other.entries, entries));

  @override
  int get hashCode => _deepEq.hash(entries);

  @override
  String toString() => 'MontyDict(${entries.length} entries)';
}

/// Represents a Python `dict` whose keys are not all strings.
///
/// Python allows any hashable key; JSON objects allow only strings. Such a dict
/// travels as `{"__type": "dict", "entries": [[k, v], …]}` and arrives with
/// both halves of every pair fully typed.
///
/// A separate variant rather than a widening of [MontyDict], so code already
/// written against `Map<String, MontyValue>` keeps compiling and keeps its
/// cheap key lookup. Before wire format v2 this shape was a bare JSON array
/// and decoded as a [MontyList] — a dict silently became a sequence, with keys
/// indistinguishable from values.
@immutable
final class MontyPairsDict extends MontyValue {
  /// Creates a [MontyPairsDict] with the given [pairs], in insertion order.
  const MontyPairsDict(this.pairs);

  factory MontyPairsDict._fromEntries(List<dynamic> raw) => MontyPairsDict([
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

  @override
  Map<String, Object?> toJson() => {
    '__type': 'dict',
    'entries': [
      for (final (k, v) in pairs) [k.toJson(), v.toJson()],
    ],
  };

  /// The pairs as a list of two-element lists.
  ///
  /// Deliberately not a `Map`: two distinct Python keys can share a Dart
  /// `toString`, so collapsing them into a map would silently drop entries.
  @override
  List<Object?> get dartValue => [
    for (final (k, v) in pairs) [k.dartValue, v.dartValue],
  ];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyPairsDict && _deepEq.equals(other.pairs, pairs));

  @override
  int get hashCode => _deepEq.hash(pairs);

  @override
  String toString() => 'MontyPairsDict(${pairs.length} pairs)';
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
