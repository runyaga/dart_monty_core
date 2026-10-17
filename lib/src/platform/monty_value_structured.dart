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
///
/// The path is normalised as `PurePosixPath` normalises it (`a//b` is
/// `a/b`, `./a/` is `a`, the empty path is `.`), so `==`, the hash and what
/// is sent to Python all see one form.
@immutable
final class MontyPath extends MontyValue {
  /// The path [value], normalised as `str(PurePosixPath(value))`.
  MontyPath(String value) : value = purePosixPath(value);

  /// The normalised path string.
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
/// …) produced by Python's `open()`: upstream's `MontyFileHandle`.
///
/// The interpreter never holds a live OS handle: an `open` OS-call returns
/// one of these (carrying the virtual [path], canonical open() [mode], and
/// byte/char [position]), and the engine drives subsequent reads/writes
/// through `Path.read_text`/`write_text`/… OS-calls. An `OsHandler`
/// servicing `open` returns a [MontyFileHandle] to satisfy the call.
///
/// Two handles are equal when their fields are (Python compares file
/// objects by identity, which a detached copy cannot carry: a recorded
/// divergence).
@immutable
final class MontyFileHandle extends MontyValue {
  /// A handle for [path] opened in [mode] at [position] (zero when null).
  ///
  /// As upstream's constructor: [mode] is parsed and stored in its canonical
  /// form (`rt` is `r`); a mode upstream refuses, a [path] with an unpaired
  /// UTF-16 surrogate (no Python `str` holds one), and a [position] outside
  /// 0..2^64-1 throw [ArgumentError].
  MontyFileHandle(this.path, String mode, {BigInt? position})
    : mode = _canonicalMode(mode),
      position = _checkedPosition(position ?? BigInt.zero) {
    if (hasUnpairedSurrogate(path)) {
      throw ArgumentError.value(
        path,
        'path',
        'a file path has no unpaired UTF-16 surrogate',
      );
    }
  }

  /// The virtual (sandbox) path of the file. Never a host path.
  final String path;

  /// The canonical `open()` mode string (`r`, `rb`, `w`, `wb`, `a`, `ab`).
  final String mode;

  /// Position for sized/line/seek operations: char index in text mode,
  /// byte index in binary mode. Zero for a freshly opened file; at most
  /// 2^64-1, as upstream's `u64`.
  final BigInt position;

  /// Whether [mode] opens the file in binary form (`rb`, `wb`, `ab`).
  bool get binary => mode.endsWith('b');

  /// Whether [mode] permits `read()`.
  bool get readable => mode.startsWith('r');

  /// Whether [mode] permits `write()`.
  bool get writable => !readable;

  @override
  Map<String, Object?> get dartValue => _markDartValue(_toJson(), 'filehandle');

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyFileHandle &&
          other.path == path &&
          other.mode == mode &&
          other.position == position);

  @override
  int get hashCode => Object.hash(path, mode, position);

  /// Upstream's repr: `MontyFileHandle(path='/x', mode='r')`.
  @override
  String toString() =>
      'MontyFileHandle(path=${pythonRepr(path)}, mode=${pythonRepr(mode)})';

  /// The position as a JSON number up to 2^53, as decimal text beyond.
  @override
  Map<String, Object?> _toJson() => {
    '__type': 'filehandle',
    'path': path,
    'mode': mode,
    'position': position <= _maxJsonInt ? position.toInt() : '$position',
  };
}

/// The largest integer every compiler holds exactly as a JSON number.
final BigInt _maxJsonInt = BigInt.two.pow(53);

/// The largest file position, upstream's `u64::MAX`.
final BigInt _maxPosition = BigInt.two.pow(64) - BigInt.one;

String _canonicalMode(String mode) {
  final parsed = parseFileMode(mode);

  return parsed.canonical ??
      (throw ArgumentError.value(mode, 'mode', parsed.error));
}

BigInt _checkedPosition(BigInt position) {
  if (position.isNegative || position > _maxPosition) {
    throw ArgumentError.value(
      position,
      'position',
      'a file position is in 0..2^64-1',
    );
  }

  return position;
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
  Map<String, Object?> get dartValue =>
      _MontyValueGraph.nodeDartValue(this) as Map<String, Object?>;

  /// As Python's: a named tuple is a tuple, equal to any [MontyTuple] or
  /// [MontyNamedTuple] with equal items, whatever the type and field names,
  /// and hashed as that tuple.
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      ((other is MontyNamedTuple || other is MontyTuple) &&
          _MontyValueGraph.equals(this, other));

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

/// A Python class as it crosses the host boundary: upstream's
/// `MontyClassTypeProxy` (monty-proto `src/python/class_instance.rs`), which
/// carries exactly these five fields.
///
/// A class sent back as a value decodes to one unless the session has a
/// [ClassType] registered under its id, and the class of every decoded
/// [MontyClassProxy] is one. Passing one back re-enters the sandbox as the
/// same class.
///
/// Two are equal when their class ids are, as upstream's (`__eq__`, one
/// type object per id in the sandbox); the hash is the id's.
///
/// Built only by the package ([montyClassTypeProxy]).
@immutable
final class MontyClassTypeProxy extends MontyValue {
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
  int get _graphKind => _kClassType;

  @override
  Map<String, Object?> get dartValue =>
      _MontyValueGraph.nodeDartValue(this) as Map<String, Object?>;

  /// The class name and the attribute count. The attributes themselves are
  /// not rendered: a shared or deeply nested value would make that unbounded.
  @override
  String toString() => 'MontyClassTypeProxy($name, ${attrs.length} attrs)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MontyClassTypeProxy && _idKey(other.id) == _idKey(id));

  @override
  int get hashCode => _idKey(id).hashCode;

  @override
  Map<String, Object?> _toJson() =>
      _MontyValueGraph.nodeToJson(this) as Map<String, Object?>;
}

/// A class id as the uuid it names, whatever the hex digits' case.
String _idKey(String id) => id.toLowerCase();

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
/// Two are equal, as upstream's (`__eq__`), when their class names,
/// dataclass flags and attributes are; the instance id and the class id are
/// not compared.
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
  Map<String, Object?> get dartValue =>
      _MontyValueGraph.nodeDartValue(this) as Map<String, Object?>;

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
