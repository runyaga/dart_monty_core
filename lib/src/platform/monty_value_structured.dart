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

/// Decodes an `attrs` dict envelope in EITHER of its two shapes.
///
/// Shared by [MontyClassInstance] and [MontyDataclass] precisely so a fix to
/// one cannot miss the other — which is exactly what happened when only the
/// former was corrected.
Map<String, MontyValue> _attrsFromEnvelope(Object? raw, String field) {
  if (raw == null) return const {};
  final decoded = MontyValue.fromJson(raw);

  return switch (decoded) {
    // One arm now. Both wire shapes decode to MontyDict, and _attrsFromPairs
    // enforces the string attribute names Python guarantees -- which the old
    // string-keyed arm got for free and so never checked.
    MontyDict(:final pairs) => _attrsFromPairs(pairs, field, raw),
    _ => throw FormatException(
      '$field must be a dict envelope, got ${decoded.runtimeType}',
      json.encode(raw),
    ),
  };
}

Map<String, MontyValue> _attrsFromPairs(
  List<(MontyValue, MontyValue)> pairs,
  String field,
  Object? raw,
) {
  final out = <String, MontyValue>{};
  for (final (k, v) in pairs) {
    if (k is! MontyString) {
      throw FormatException(
        '$field: attribute names must be strings, got ${k.runtimeType}',
        json.encode(raw),
      );
    }
    out[k.value] = v;
  }

  return out;
}

/// Python's `NotImplemented` singleton.
///
/// ADDED 2026-09-14 by the same alignment audit that found [MontyTime]. The
/// Rust encoder emits `{"__type": "not_implemented"}`
/// (native/src/convert.rs:172) and Dart had no factory, so evaluating the bare
/// name `NotImplemented` in the sandbox threw
/// `FormatException: unknown __type "not_implemented"`.
///
/// A singleton with no payload, mirroring [MontyEllipsis].
@immutable
final class MontyNotImplemented extends MontyValue {
  /// Creates the [MontyNotImplemented] singleton value.
  const MontyNotImplemented();

  factory MontyNotImplemented._fromMap(Map<String, dynamic> _) =>
      const MontyNotImplemented();

  @override
  Map<String, Object?> toJson() => {'__type': 'not_implemented'};

  /// No Dart equivalent, so the sentinel represents itself.
  @override
  Object? get dartValue => this;

  @override
  String toString() => 'MontyNotImplemented()';

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is MontyNotImplemented;

  @override
  int get hashCode => (MontyNotImplemented).hashCode;
}

/// Reads a wire bool: ABSENT means false, WRONG-TYPED is an error.
///
/// `as bool? ?? false` conflates the two, so `host_defined: 1` decodes as
/// `false` and nothing reports it.
bool _wireBool(Object? v, String field) => switch (v) {
  null => false,
  final bool b => b,
  _ => throw FormatException('$field must be a bool, got ${v.runtimeType}'),
};

/// The class an instance belongs to, as it crosses the host boundary.
///
/// Mirrors upstream `MontyClassType` (monty
/// `crates/monty-types/src/object.rs:766-785`) and monty's own JS host
/// boundary (`crates/monty-js/src/convert.rs:347-356`), which carries exactly
/// these five fields.
@immutable
final class MontyClassType {
  /// Creates a [MontyClassType].
  const MontyClassType({
    required this.name,
    required this.id,
    required this.hostDefined,
    required this.isDataclass,
    required this.attrs,
  });

  /// The class name, e.g. `Point`.
  final String name;

  /// Stable class identity, a canonical uuid STRING.
  ///
  /// A string, not an integer, for the reason monty's own JS boundary gives
  /// (`crates/monty-js/src/convert.rs:349`): "JS has no 128-bit integer type".
  /// Dart has the same constraint — a uuid does not fit in an `int` on the
  /// web. The engine keeps ONE type object per class id
  /// (`object.rs:781-784`), so this is what keeps two host classes apart.
  final String id;

  /// Whether the class was defined by the host rather than in the sandbox.
  final bool hostDefined;

  /// Whether `dataclasses.is_dataclass` is true for this class.
  ///
  /// Read from the CLASS, never the instance. Measured against
  /// pydantic-monty 0.0.23: an instance-level override is IGNORED and only a
  /// class-level one takes effect.
  final bool isDataclass;

  /// Class-level attributes sent eagerly with the type object.
  final Map<String, MontyValue> attrs;

  @override
  String toString() =>
      'MontyClassType($name, id: $id, isDataclass: $isDataclass)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyClassType &&
          other.name == name &&
          other.id == id &&
          other.hostDefined == hostDefined &&
          other.isDataclass == isDataclass &&
          _deepEq.equals(other.attrs, attrs));

  @override
  int get hashCode =>
      Object.hash(name, id, hostDefined, isDataclass, _deepEq.hash(attrs));
}

/// A Python class instance crossing the host boundary.
///
/// WHY THIS TYPE EXISTS, and why it is not [MontyDataclass]. monty v0.0.23
/// DELETED its wire `Dataclass` variant and represents every instance as a
/// `ClassInstance` (upstream commit cf8246d7, "Replace wire `Dataclass` with
/// `ClassInstance` carrying instance identity"). The deleted variant carried
/// `name`, `type_id`, `field_names`, `attrs` and `frozen`; the replacement
/// carries a class, an instance id and attrs — and NOTHING ELSE.
///
/// `frozen` and `field_names` are GONE UPSTREAM, not dropped by this binding.
/// Verified twice, by source and by running the shipped artifact:
///   * monty `docs/limitations/classes.md:263-265` — "Frozen dataclasses are
///     not frozen in the sandbox: there is no frozen policy on the wire".
///   * `docs/limitations/classes.md:266` — "`dataclasses.fields()` /
///     `asdict()` do not work on host instances".
///   * pydantic-monty 0.0.23, measured: a returned instance exposes exactly
///     `['attributes', 'id', 'is_dataclass', 'name']`; frozen and non-frozen
///     are WIRE-IDENTICAL; and in-sandbox `from dataclasses import fields`
///     raises ImportError, so nothing could read field names even if they
///     crossed.
///
/// So mapping this onto [MontyDataclass] would mean inventing `frozen: false`
/// for something that may well be frozen. This binding does not guess — see
/// the decoder's refusal to assume an unknown `__type` (core#136).
@immutable
final class MontyClassInstance extends MontyValue {
  /// Creates a [MontyClassInstance].
  const MontyClassInstance({
    required this.classType,
    required this.instanceId,
    required this.attrs,
  });

  factory MontyClassInstance._fromMap(Map<String, dynamic> map) {
    // DELEGATES to MontyValue.fromJson rather than reaching for `value`
    // directly. A dict has TWO envelope shapes that share the `dict` tag:
    // `{"__type":"dict","value":{...}}` for string keys and
    // `{"__type":"dict","entries":[[k,v],...]}` for any keys
    // (the entries shape). Hand-reading `value` silently returned an EMPTY map
    // for the `entries` form — data loss with no error, caught in review.
    // Decoding through the real decoder means this cannot drift from it again.
    // TWO arguments, deliberately: `key` is what to look up, `label` is what
    // to say when it is missing. A first version used one string for both and
    // looked up 'class_type.name' — a key that never exists — so every decode
    // failed with "must be a string, got Null" while the payload plainly
    // contained {"name":"User"}. The error text was correct and the lookup
    // was not.
    String requiredString(Map<String, dynamic> m, String key, String label) {
      final v = m[key];
      if (v is String) return v;

      // Identity is not something to guess at. This was `as String? ?? ''`,
      // which turned a missing or wrong-typed class name or uuid into an empty
      // string and carried on — the same silent-default hazard removed from
      // the Rust decoder in the previous commit, reintroduced on the Dart
      // side. An envelope without these did not come from our encoder.
      throw FormatException(
        'class_instance: $label must be a string, got ${v.runtimeType}',
        json.encode(m),
      );
    }

    final ct = map['class_type'];
    if (ct is! Map<String, dynamic>) {
      throw FormatException(
        'class_instance: class_type must be an object, got ${ct.runtimeType}',
        json.encode(map),
      );
    }

    return MontyClassInstance(
      classType: MontyClassType(
        name: requiredString(ct, 'name', 'class_type.name'),
        id: requiredString(ct, 'id', 'class_type.id'),
        // Absent is false; present-but-wrong-typed is an error.
        hostDefined: _wireBool(ct['host_defined'], 'class_type.host_defined'),
        isDataclass: _wireBool(ct['is_dataclass'], 'class_type.is_dataclass'),
        attrs: _attrsFromEnvelope(ct['attrs'], 'class_type.attrs'),
      ),
      instanceId: requiredString(map, 'instance_id', 'instance_id'),
      attrs: _attrsFromEnvelope(map['attrs'], 'attrs'),
    );
  }

  /// The class this instance belongs to.
  final MontyClassType classType;

  /// Identity of this instance, a canonical uuid STRING.
  final String instanceId;

  /// Eagerly-sent attributes, in insertion order.
  final Map<String, MontyValue> attrs;

  /// The class name, e.g. `Point`. Convenience for `classType.name`.
  String get name => classType.name;

  /// Whether this instance's CLASS is a dataclass.
  bool get isDataclass => classType.isDataclass;

  /// The attribute values as plain Dart objects.
  Map<String, Object?> get dartAttrs =>
      attrs.map((k, v) => MapEntry(k, v.dartValue));

  /// Hydrates this instance into a Dart object via [factory].
  ///
  /// Carried over from [MontyDataclass] unchanged, because it is the useful
  /// half of that API and nothing about it depended on the deleted fields:
  ///
  /// ```dart
  /// final user = (result.value! as MontyClassInstance).hydrate(
  ///   (a) => User(name: a['name']! as String),
  /// );
  /// ```
  T hydrate<T>(T Function(Map<String, Object?> attrs) factory) =>
      factory(dartAttrs);

  @override
  Map<String, Object?> toJson() => {
    '__type': 'class_instance',
    'class_type': {
      'name': classType.name,
      'id': classType.id,
      'host_defined': classType.hostDefined,
      'is_dataclass': classType.isDataclass,
      'attrs': MontyDict.ofStrings(classType.attrs).toJson(),
    },
    'instance_id': instanceId,
    'attrs': MontyDict.ofStrings(attrs).toJson(),
  };

  @override
  Map<String, Object?> get dartValue => toJson();

  @override
  String toString() =>
      'MontyClassInstance(${classType.name}, attrs: $dartAttrs)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyClassInstance &&
          other.classType == classType &&
          other.instanceId == instanceId &&
          _deepEq.equals(other.attrs, attrs));

  @override
  int get hashCode => Object.hash(classType, instanceId, _deepEq.hash(attrs));
}

/// Represents a Python `@dataclass` value. ENCODE-ONLY as of monty v0.0.23.
///
/// **The engine no longer emits this.** monty v0.0.23 deleted its wire
/// `Dataclass` variant (upstream commit cf8246d7) and sends every instance as
/// a `class_instance`, so what comes BACK from a run is a
/// [MontyClassInstance]. This type remains the way a HOST hands a dataclass
/// IN — `toJson()` below still writes the `dataclass` envelope and
/// `native/src/convert.rs` still accepts it.
///
/// **[frozen], [fieldNames] and [typeId] are WRITE-ONLY.** Set them and they
/// are consumed at the boundary; nothing coming back will ever carry them,
/// because upstream has nowhere to put them:
///   * `docs/limitations/classes.md:263-265` — "there is no frozen policy on
///     the wire";
///   * `docs/limitations/classes.md:266` — `dataclasses.fields()` does not
///     work on host instances;
///   * measured on pydantic-monty 0.0.23: frozen and non-frozen instances are
///     WIRE-IDENTICAL, and in-sandbox `from dataclasses import fields` raises
///     ImportError.
/// [typeId] is not discarded — it feeds the class identity
/// (`derive_class_uuid` in convert.rs) — but it does not come back either.
///
/// This is a BREAKING change for consumers who read those fields off a
/// returned value. It is surfaced rather than papered over: mapping
/// `class_instance` onto this type would mean reporting `frozen: false` for a
/// dataclass that was frozen, which is a fabricated answer.
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
    // SAME BUG AS MontyClassInstance HAD, and it outlived that fix by three
    // hundred lines. Hand-reading `attrs['value']` returns an EMPTY map — no
    // error — for the OTHER dict shape, `{"__type":"dict","entries":[...]}`,
    // which carries the same `dict` tag and is what a non-string-keyed dict
    // uses. Measured 2026-09-14: a dataclass envelope with entries-form attrs
    // decoded to `{}`. Delegating to the real decoder is what stops the two
    // drifting apart again.
    final parsedAttrs = _attrsFromEnvelope(map['attrs'], 'dataclass.attrs');

    return MontyDataclass(
      name: map['name'] as String? ?? '',
      // NOT `?? 0`. The Rust decoder now REQUIRES type_id — it derives the
      // class identity from it (convert.rs: "dataclass envelope missing field
      // \"type_id\": cannot derive a stable class identity") — so defaulting
      // here produced a value Dart accepts and Rust rejects. Review caught the
      // mismatch. Absent is an error on both sides now.
      typeId: switch (map['type_id']) {
        final num n => n.toInt(),
        final other => throw FormatException(
          'dataclass: type_id must be a number, got ${other.runtimeType}',
          json.encode(map),
        ),
      },
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
    'attrs': MontyDict.ofStrings(attrs).toJson(),
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
  cycle('cycle')
  ;

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
