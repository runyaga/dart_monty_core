part of 'monty_value.dart';

// ---------------------------------------------------------------------------
// Ellipsis
// ---------------------------------------------------------------------------

/// Python's `Ellipsis` (`...`).
///
/// It has exactly one value, so this is a singleton with no payload.
///
/// Before 0.19.0 `...` was serialized as the bare string `"..."`, which made it
/// indistinguishable from the actual string `"..."` — both arrived as
/// [MontyString]. It now travels as `{"__type": "ellipsis"}` (core#129).
@immutable
final class MontyEllipsis extends MontyValue {
  /// Creates the [MontyEllipsis] singleton value.
  const MontyEllipsis();

  factory MontyEllipsis._fromMap(Map<String, dynamic> _) =>
      const MontyEllipsis();

  @override
  Map<String, Object?> toJson() => {'__type': 'ellipsis'};

  /// There is no Dart equivalent of `...`, so the sentinel represents itself.
  @override
  Object? get dartValue => this;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MontyEllipsis;

  @override
  int get hashCode => (MontyEllipsis).hashCode;

  @override
  String toString() => 'MontyEllipsis()';
}

// ---------------------------------------------------------------------------
// Path
// ---------------------------------------------------------------------------

/// Represents a Python `pathlib.Path` value.
@immutable
final class MontyPath extends MontyValue {
  /// Creates a [MontyPath] with the given string [value].
  const MontyPath(this.value);

  factory MontyPath._fromMap(Map<String, dynamic> map) =>
      MontyPath(map['value'] as String? ?? '');

  /// The underlying path string.
  final String value;

  @override
  Map<String, Object?> toJson() => {'__type': 'path', 'value': value};

  @override
  String get dartValue => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MontyPath && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MontyPath($value)';
}

// ---------------------------------------------------------------------------
// FileHandle
// ---------------------------------------------------------------------------

/// Represents an open file object (`_io.TextIOWrapper` / `BufferedReader` /
/// …) produced by Python's `open()`.
///
/// The interpreter never holds a live OS handle: an `open` OS-call returns
/// one of these (carrying the virtual [path], canonical open() [mode], and
/// byte/char [position]), and the engine drives subsequent reads/writes
/// through `Path.read_text`/`write_text`/… OS-calls. An `OsCallHandler`
/// servicing `open` returns a [MontyFileHandle] to satisfy the call.
@immutable
final class MontyFileHandle extends MontyValue {
  /// Creates a [MontyFileHandle] for [path] opened in [mode] at [position].
  const MontyFileHandle({
    required this.path,
    required this.mode,
    this.position = 0,
  });

  factory MontyFileHandle._fromMap(Map<String, dynamic> map) => MontyFileHandle(
    path: map['path'] as String? ?? '',
    mode: map['mode'] as String? ?? 'r',
    position: (map['position'] as num?)?.toInt() ?? 0,
  );

  /// The virtual (sandbox) path of the file. Never a host path.
  final String path;

  /// The canonical `open()` mode string (`r`, `rb`, `w`, `wb`, `a`, `ab`).
  final String mode;

  /// Position for sized/line/seek operations: char index in text mode,
  /// byte index in binary mode. `0` for a freshly opened file.
  final int position;

  @override
  Map<String, Object?> toJson() => {
    '__type': 'filehandle',
    'path': path,
    'mode': mode,
    'position': position,
  };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyFileHandle &&
          other.path == path &&
          other.mode == mode &&
          other.position == position);

  @override
  int get hashCode => Object.hash(path, mode, position);

  @override
  String toString() => 'MontyFileHandle($path, mode: $mode, pos: $position)';
}

// ---------------------------------------------------------------------------
// Structured types
// ---------------------------------------------------------------------------

/// Represents a Python `collections.namedtuple` value.
@immutable
final class MontyNamedTuple extends MontyValue {
  /// Creates a [MontyNamedTuple].
  const MontyNamedTuple({
    required this.typeName,
    required this.fieldNames,
    required this.values,
  });

  factory MontyNamedTuple._fromMap(Map<String, dynamic> map) => MontyNamedTuple(
    typeName: map['type_name'] as String? ?? '',
    fieldNames:
        (map['field_names'] as List<dynamic>?)?.cast<String>().toList() ??
        const [],
    values:
        (map['values'] as List<dynamic>?)?.map(MontyValue.fromJson).toList() ??
        const [],
  );

  /// The name of the namedtuple type.
  final String typeName;

  /// The field names of the namedtuple.
  final List<String> fieldNames;

  /// The field values.
  final List<MontyValue> values;

  @override
  Map<String, Object?> toJson() => {
    '__type': 'namedtuple',
    'type_name': typeName,
    'field_names': fieldNames,
    'values': values.map((e) => e.toJson()).toList(),
  };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyNamedTuple &&
          other.typeName == typeName &&
          _deepEq.equals(other.fieldNames, fieldNames) &&
          _deepEq.equals(other.values, values));

  @override
  int get hashCode =>
      Object.hash(typeName, _deepEq.hash(fieldNames), _deepEq.hash(values));

  @override
  String toString() =>
      'MontyNamedTuple($typeName, ${fieldNames.length} fields)';
}

/// Represents a Python `@dataclass` value.
@immutable
final class MontyDataclass extends MontyValue {
  /// Creates a [MontyDataclass].
  const MontyDataclass({
    required this.name,
    required this.typeId,
    required this.fieldNames,
    required this.attrs,
    this.frozen = false,
  });

  factory MontyDataclass._fromMap(Map<String, dynamic> map) {
    // `attrs` is a dict, so since wire format v2 it carries the dict envelope
    // like every other object — there is no "except inside dataclass"
    // carve-out. The encoder gets this for free by routing attrs through
    // dict_to_json, which is a good sign the uniform rule is the right one.
    final rawAttrs = map['attrs'];
    final attrsPayload = rawAttrs is Map<String, dynamic>
        ? rawAttrs['value']
        : null;
    final parsedAttrs = attrsPayload is Map<String, dynamic>
        ? attrsPayload.map((k, v) => MapEntry(k, MontyValue.fromJson(v)))
        : const <String, MontyValue>{};

    return MontyDataclass(
      name: map['name'] as String? ?? '',
      typeId: (map['type_id'] as num?)?.toInt() ?? 0,
      fieldNames:
          (map['field_names'] as List<dynamic>?)?.cast<String>().toList() ??
          const [],
      attrs: parsedAttrs,
      frozen: map['frozen'] as bool? ?? false,
    );
  }

  /// The dataclass name.
  final String name;

  /// The numeric type identifier.
  final int typeId;

  /// The field names of the dataclass.
  final List<String> fieldNames;

  /// The attribute values keyed by field name.
  final Map<String, MontyValue> attrs;

  /// Whether the dataclass is frozen (immutable).
  final bool frozen;

  /// The attribute values converted to plain Dart objects via
  /// [MontyValue.dartValue]. Convenient for hydrating into a
  /// user-supplied class.
  Map<String, Object?> get dartAttrs =>
      attrs.map((k, v) => MapEntry(k, v.dartValue));

  /// Hydrates this dataclass into a Dart object via [factory].
  ///
  /// `factory` receives [dartAttrs] (a plain `Map<String, Object?>`) and
  /// returns the user class. Composes naturally with `Map<String,
  /// DataclassFactory>` registries on the caller side:
  ///
  /// ```dart
  /// final factories = <String, Object Function(Map<String, Object?>)>{
  ///   'User': (a) => User(name: a['name'] as String, age: a['age'] as int),
  ///   'Order': Order.fromAttrs,
  /// };
  ///
  /// final dc = result.value as MontyDataclass;
  /// final dartObject = factories[dc.name]!(dc.dartAttrs);
  /// ```
  ///
  /// For one-off conversion, call [hydrate] directly:
  ///
  /// ```dart
  /// final user = (result.value as MontyDataclass).hydrate(
  ///   (a) => User(name: a['name'] as String),
  /// );
  /// ```
  T hydrate<T>(T Function(Map<String, Object?> attrs) factory) =>
      factory(dartAttrs);

  @override
  Map<String, Object?> toJson() => {
    '__type': 'dataclass',
    'name': name,
    'type_id': typeId,
    'field_names': fieldNames,
    'attrs': MontyDict(attrs).toJson(),
    'frozen': frozen,
  };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyDataclass &&
          other.name == name &&
          other.typeId == typeId &&
          _deepEq.equals(other.fieldNames, fieldNames) &&
          _deepEq.equals(other.attrs, attrs) &&
          other.frozen == frozen);

  @override
  int get hashCode => Object.hash(
    name,
    typeId,
    _deepEq.hash(fieldNames),
    _deepEq.hash(attrs),
    frozen,
  );

  @override
  String toString() => 'MontyDataclass($name, ${attrs.length} attrs)';
}

/// What kind of host-side rendering a [MontyOpaque] carries.
///
/// A typed enum rather than the raw wire string, so `switch` over it is
/// exhaustive and a typo is a compile error. It also keeps the door open: if
/// one of these later deserves its own [MontyValue] variant, the split is a
/// Dart-side change with no wire movement.
enum MontyOpaqueKind {
  /// A Python class, e.g. `int` — wire tag `type`.
  type('type'),

  /// A user-defined function — wire tag `function`.
  function('function'),

  /// A built-in function, e.g. `abs` — wire tag `builtin`.
  builtin('builtin'),

  /// An object's `repr()`, for values with no richer representation.
  repr('repr'),

  /// A marker standing in for a cycle in a self-referential structure.
  cycle('cycle');

  const MontyOpaqueKind(this.wireTag);

  /// The `__type` value this kind travels under.
  final String wireTag;

  /// The kind for [tag], or `null` when unrecognised.
  static MontyOpaqueKind? fromWireTag(String tag) {
    for (final k in values) {
      if (k.wireTag == tag) return k;
    }

    return null;
  }
}

/// Represents a value the host can see but cannot reconstruct.
///
/// Five Python things have no faithful Dart representation: a class, a
/// function, a builtin, a bare `repr()`, and a cycle marker. What crosses the
/// wire is a rendering of each — `<function f at 0x…>`, `int`, `abs`, `[...]` —
/// and this variant says so instead of pretending otherwise.
///
/// All five used to arrive as bare [MontyString]s (core#134's siblings), so
/// they were indistinguishable from each other AND from ordinary Python
/// strings. `abs` was worse than lossy: it arrived as `"Abs"`, Rust's `Debug`
/// rendering of an internal enum, where a reader expects the Python name.
///
/// **Sending one back into the interpreter is an error.** A rendering of a
/// callable is not a callable, and a cycle marker names a position in a graph
/// that does not exist on this side. The one exception is
/// [MontyOpaqueKind.builtin], which round-trips exactly because its Python
/// name identifies it.
@immutable
final class MontyOpaque extends MontyValue {
  /// Creates a [MontyOpaque] of [kind] carrying [text].
  const MontyOpaque(this.kind, this.text);

  factory MontyOpaque._fromMap(Map<String, dynamic> map) {
    final tag = map['__type'] as String? ?? '';
    final kind = MontyOpaqueKind.fromWireTag(tag);
    if (kind == null) {
      throw FormatException('not an opaque wire tag: "$tag"', json.encode(map));
    }

    return MontyOpaque(kind, map['text'] as String? ?? '');
  }

  /// Which of the five this is.
  final MontyOpaqueKind kind;

  /// The host-visible rendering.
  final String text;

  @override
  Map<String, Object?> toJson() => {'__type': kind.wireTag, 'text': text};

  @override
  String get dartValue => text;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyOpaque && other.kind == kind && other.text == text);

  @override
  int get hashCode => Object.hash(kind, text);

  @override
  String toString() => 'MontyOpaque(${kind.name}, $text)';
}
