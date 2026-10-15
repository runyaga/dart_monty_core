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

  @override
  int get _graphKind => _kFixed;

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

  @override
  Map<String, Object?> _toJson() => {'__type': 'ellipsis'};
}

// ---------------------------------------------------------------------------
// Path
// ---------------------------------------------------------------------------

/// Represents a Python `pathlib.Path` value.
@immutable
final class MontyPath extends MontyValue {
  /// Creates a [MontyPath] with the given string [value].
  const MontyPath(this.value);

  /// The underlying path string.
  final String value;

  @override
  String get dartValue => value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is MontyPath && other.value == value);

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'MontyPath($value)';

  @override
  Map<String, Object?> _toJson() => {'__type': 'path', 'value': value};
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
/// through `Path.read_text`/`write_text`/… OS-calls. An `OsHandler`
/// servicing `open` returns a [MontyFileHandle] to satisfy the call.
@immutable
final class MontyFileHandle extends MontyValue {
  /// Creates a [MontyFileHandle] for [path] opened in [mode] at [position].
  const MontyFileHandle({
    required this.path,
    required this.mode,
    this.position = 0,
  });

  /// The virtual (sandbox) path of the file. Never a host path.
  final String path;

  /// The canonical `open()` mode string (`r`, `rb`, `w`, `wb`, `a`, `ab`).
  final String mode;

  /// Position for sized/line/seek operations: char index in text mode,
  /// byte index in binary mode. `0` for a freshly opened file.
  final int position;

  @override
  Map<String, Object?> get dartValue => _toJson();

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

  @override
  Map<String, Object?> _toJson() => {
    '__type': 'filehandle',
    'path': path,
    'mode': mode,
    'position': position,
  };
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

  /// The name of the namedtuple type.
  final String typeName;

  /// The field names of the namedtuple.
  final List<String> fieldNames;

  /// The field values.
  final List<MontyValue> values;

  @override
  int get _graphKind => _kNamedTuple;

  @override
  Map<String, Object?> get dartValue => _toJson();

  // Compares the type and field names too, where Python compares a named
  // tuple as a plain tuple: a recorded divergence.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyNamedTuple && _MontyValueGraph.equals(this, other));

  @override
  int get hashCode => _MontyValueGraph.hash(this);

  @override
  String toString() =>
      'MontyNamedTuple($typeName, ${fieldNames.length} fields)';

  @override
  Map<String, Object?> _toJson() =>
      _MontyValueGraph.nodeToJson(this) as Map<String, Object?>;
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

  @override
  int get _graphKind => _kFixed;

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

  @override
  Map<String, Object?> _toJson() => {'__type': 'not_implemented'};
}

/// The class an instance belongs to, as it crosses the host boundary:
/// upstream's `MontyClassTypeProxy` (monty-proto
/// `src/python/class_instance.rs`), which carries exactly these five fields.
///
/// Built only by the package ([montyClassTypeProxy]); a caller receives one
/// from a decoded [MontyClassProxy].
@immutable
final class MontyClassTypeProxy {
  const MontyClassTypeProxy._({
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
  /// A string, not an integer, because a uuid does not fit in an `int` on the
  /// web. The engine keeps one type object per class id, so this is what
  /// keeps two host classes apart.
  final String id;

  /// Whether the class was defined by the host rather than in the sandbox.
  final bool hostDefined;

  /// Whether `dataclasses.is_dataclass` is true for this class.
  final bool isDataclass;

  /// Class-level attributes sent eagerly with the type object.
  final Map<String, MontyValue> attrs;

  @override
  String toString() =>
      'MontyClassTypeProxy($name, id: $id, isDataclass: $isDataclass)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyClassTypeProxy && _MontyValueGraph.equals(this, other));

  @override
  int get hashCode => _MontyValueGraph.hash(this);
}

/// A [MontyClassTypeProxy]; internal (the constructor is not public), left
/// out of the public `show` lists.
MontyClassTypeProxy montyClassTypeProxy({
  required String name,
  required String id,
  required bool hostDefined,
  required bool isDataclass,
  required Map<String, MontyValue> attrs,
}) => MontyClassTypeProxy._(
  name: name,
  id: id,
  hostDefined: hostDefined,
  isDataclass: isDataclass,
  attrs: attrs,
);

/// A Python class instance crossing the host boundary: upstream's
/// `MontyClassProxy`, a class, an instance id and the instance's attributes.
///
/// Built only by the package ([montyClassProxy]); a caller receives one from
/// a run and may pass it back.
@immutable
final class MontyClassProxy extends MontyValue {
  const MontyClassProxy._({
    required this.classType,
    required this.instanceId,
    required this.attrs,
  });

  /// The class this instance belongs to.
  final MontyClassTypeProxy classType;

  /// Identity of this instance, a canonical uuid STRING.
  final String instanceId;

  /// Eagerly-sent attributes, in insertion order.
  final Map<String, MontyValue> attrs;

  @override
  int get _graphKind => _kInstance;

  @override
  Map<String, Object?> get dartValue => _toJson();

  /// The class name and the attribute count. The attributes themselves are
  /// not rendered: a shared or deeply nested value would make that unbounded.
  @override
  String toString() =>
      'MontyClassProxy(${classType.name}, ${attrs.length} attrs)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyClassProxy && _MontyValueGraph.equals(this, other));

  @override
  int get hashCode => _MontyValueGraph.hash(this);

  @override
  Map<String, Object?> _toJson() =>
      _MontyValueGraph.nodeToJson(this) as Map<String, Object?>;
}

/// A [MontyClassProxy]; internal (the constructor is not public), left out
/// of the public `show` lists.
MontyClassProxy montyClassProxy({
  required MontyClassTypeProxy classType,
  required String instanceId,
  required Map<String, MontyValue> attrs,
}) => MontyClassProxy._(
  classType: classType,
  instanceId: instanceId,
  attrs: attrs,
);

/// [MontyClassProxy]'s internal members (pass-3 G2). The public libraries'
/// `show` lists leave this extension out.
extension MontyClassProxyInternal on MontyClassProxy {
  /// The attribute values as plain Dart objects.
  ///
  /// One projection covers every attribute, so a value shared between two
  /// attributes is one object here too.
  Map<String, Object?> get dartAttrs => _MontyValueGraph.dartAttrs(attrs);
}

/// A builtin function or type the host can see: upstream's
/// `MontyStdTypeProxy`.
///
/// [kind] is `'function'` for a builtin function, such as `abs`, and
/// `'type'` for a type object, such as `int`; [name] is the name the sandbox
/// renders it as. Passing one back produces the builtin it names.
///
/// Built only by the package ([montyStdTypeProxy]).
@immutable
final class MontyStdTypeProxy extends MontyValue {
  const MontyStdTypeProxy._(this.kind, this.name);

  /// `'function'` for a builtin function, `'type'` for a type object.
  final String kind;

  /// The builtin's name, such as `'open'` or `'int'`.
  final String name;

  @override
  String get dartValue => name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyStdTypeProxy && other.kind == kind && other.name == name);

  /// The name's hash, as upstream's: the name is unique across both kinds.
  @override
  int get hashCode => name.hashCode;

  /// Upstream's repr: `MontyStdTypeProxy(kind='function', name='open')`.
  @override
  String toString() =>
      'MontyStdTypeProxy(kind=${_pyRepr(kind)}, name=${_pyRepr(name)})';

  @override
  Map<String, Object?> _toJson() => {
    '__type': 'std_type_proxy',
    'kind': kind,
    'name': name,
  };
}

/// A [MontyStdTypeProxy] of [kind] named [name]; internal (the constructor
/// is not public), left out of the public `show` lists.
MontyStdTypeProxy montyStdTypeProxy(String kind, String name) =>
    MontyStdTypeProxy._(kind, name);

/// [text] as Python's `repr` of a `str` renders it: single-quoted unless it
/// holds a single quote and no double quote, backslashes and the quote
/// escaped, and the common control characters by their escapes.
String _pyRepr(String text) {
  final quote = text.contains("'") && !text.contains('"') ? '"' : "'";
  final out = StringBuffer(quote);
  for (final rune in text.runes) {
    out.write(_pyReprRune(rune, quote));
  }
  out.write(quote);

  return out.toString();
}

/// One code point of [_pyRepr]'s output, inside [quote]s.
String _pyReprRune(int rune, String quote) {
  final c = String.fromCharCode(rune);

  return switch (c) {
    r'\' => r'\\',
    '\n' => r'\n',
    '\r' => r'\r',
    '\t' => r'\t',
    _ when c == quote => '\\$c',
    _ when rune < 0x20 || rune == 0x7f =>
      '\\x${rune.toRadixString(16).padLeft(2, '0')}',
    _ => c,
  };
}
