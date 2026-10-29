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

/// A virtual file handle returned by the host for Python's `open()`.
@immutable
final class MontyFileHandle extends MontyValue {
  /// Creates a virtual file handle with canonicalized mode and position.
  ///
  /// [mode] accepts one of `r`, `w`, or `a` with at most one `b` or `t` in
  /// either order. It rejects `x` and `+`, canonicalizes `rt` to `r` and `br`
  /// to `rb`, and produces `r`, `rb`, `w`, `wb`, `a`, or `ab`. A null
  /// [position] is zero. An unpaired surrogate in [path] or a [position]
  /// outside 0 through 2^64 - 1 throws [ArgumentError].
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
  /// Compares path, mode, and position by value, unlike Python file identity.
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

// ---------------------------------------------------------------------------
// ExternalModule
// ---------------------------------------------------------------------------

/// A host module the sandbox imports: upstream's `PyExternalModule`
/// (monty-proto `src/python/external_module.rs`).
///
/// The host builds one and gives it to a session through the
/// `externalModules` parameter of `Monty.checkout` or `Monty.withSession`,
/// and the sandbox imports it by name:
///
/// ```dart
/// final tools = ExternalModule({
///   'VERSION': 3,
///   'add': MontyHostFunction('add', (arguments, keywords) {
///     final left = arguments[0] as MontyInt;
///     final right = arguments[1] as MontyInt;
///
///     return MontyInt(left.value + right.value);
///   }),
///   'sub': ExternalModule({'TAG': 'nested'}),
/// });
///
/// await Monty.withPool(
///   (monty) => monty.withSession(
///     (session) => session.feedRun('import tools\ntools.add(2, 3)'),
///     externalModules: {'tools': tools},
///   ),
/// );
/// ```
///
/// The attributes are the module's public surface, and the sandbox sees the
/// public ones only, in insertion order: [publicAttrs] holds them, and a
/// name that starts with `_` is protected and reaches no host code. A
/// [MontyHostFunction] attribute is a function the sandbox calls by its
/// name (`tools.add(2, 3)`), and a nested [ExternalModule] is a submodule of
/// its own, imported by its dotted path (`import tools.sub`). [stubs] is the
/// module's `.pyi` source, `null` when it has none; the type checker reads
/// it when it type checks an import of the module.
///
/// [attrs] is copied and checked once, at construction, so the module's
/// attribute mapping never changes after: its keys must be strings and
/// identifiers (a keyword is not one), and a nested [ExternalModule] may
/// sit only under a key naming a module the sandbox does not itself
/// provide. The copy is shallow: the values are the very objects the host
/// gave, so a mutable value is shared with the module and not copied into
/// it, and a change the host makes to it is seen by the sandbox the next
/// time the value is converted, that is by a later import. A value the
/// sandbox already imported is not changed: it was converted and sent when
/// that import happened. Ordinary values are neither checked nor converted
/// at construction; [attrValue] converts one when it is read, the moment an
/// import would.
///
/// Two are equal, as upstream's `__eq__`, when their ids, stubs and
/// attributes match: the attribute values are compared structurally, as
/// Python compares the values of two dicts, so a `List` or a `Map`
/// attribute matches another one with the same contents, not only the very
/// same object.
///
/// A module is a [MontyValue] of its own: `MontyValue.fromDart` hands one
/// back unchanged, and its [dartValue] is the module itself. It has no
/// tagged JSON projection, so [_toJson] refuses one with an
/// [UnsupportedError]. Nor is it a value the sandbox can hold: it enters
/// the sandbox through the session's `externalModules` mapping, and the
/// arena writer refuses one that arrives as an ordinary value.
///
/// The rules the sandbox follows for an import, a module call and a
/// factory, and every difference from upstream, are in
/// `docs/reference/upstream-divergences.md`. The map a module is given
/// through is the `externalModules` parameter of `Monty.checkout` and
/// `Monty.withSession`, whose contract the `Monty` class documents.
final class ExternalModule extends MontyValue {
  /// Creates a module from a shallow copy of [attrs].
  ///
  /// A key that is not a [String] is an [ArgumentError] with upstream's
  /// message (`ExternalModule attrs must have str keys, not <type>`), as is
  /// one that is not an identifier or is a keyword
  /// (`ExternalModule attrs must have identifier keys, not '<key>'`). A
  /// nested [ExternalModule] is imported by its key, so that key must also
  /// name a module the sandbox does not provide itself: an [ArgumentError]
  /// that names the key and says the module is provided by the sandbox and
  /// cannot be replaced. [id] must be a uuid, canonical whatever its case;
  /// a random version 4 one is made when it is absent, as a class id is.
  ///
  /// The id is checked before the attributes, so an invalid id is reported
  /// even when the attributes are invalid too.
  ExternalModule(Map<Object?, Object?> attrs, {this.stubs, String? id})
    : id = id == null ? _uuid4() : _checkedId(id),
      _attrs = _checkedAttrs(attrs);

  /// The module's `.pyi` source, `null` when it has none.
  final String? stubs;

  /// Identity of the module, a canonical lowercase uuid string; every import
  /// of the module carries it.
  final String id;

  /// The module's attributes, copied once at construction and never changed
  /// after. The values are the very objects given, so the copy is shallow
  /// and a mutable value among them is shared with the module.
  final Map<String, Object?> _attrs;

  /// A copy of the module's attributes, protected ones included. Editing it,
  /// or the map given at construction, changes neither the module nor the
  /// next copy read; the values are the very objects given, so a mutable
  /// value among them is shared, not copied.
  Map<String, Object?> get attrs => Map.of(_attrs);

  /// The public attributes, in insertion order: every attribute whose name
  /// does not start with `_`. A nested [ExternalModule] is one of them, and
  /// the sandbox imports it as a submodule of its own.
  Map<String, Object?> get publicAttrs {
    final public = <String, Object?>{};
    for (final entry in _attrs.entries) {
      if (!entry.key.startsWith('_')) public[entry.key] = entry.value;
    }

    return public;
  }

  /// The module itself: a module has no Dart projection of its own, so it
  /// represents itself.
  @override
  Object? get dartValue => this;

  /// The attribute [name] as the sandbox sees it: `null` when [name] is
  /// absent or protected (its name starts with `_`), a nested
  /// [ExternalModule] as itself, and any other value converted now —
  /// deferred from construction — by `MontyValue.fromDart`.
  Object? attrValue(String name) {
    if (name.startsWith('_')) return null;
    if (!_attrs.containsKey(name)) return null;
    final value = _attrs[name];

    return value is ExternalModule ? value : MontyValue.fromDart(value);
  }

  /// Equal to another [ExternalModule] when the ids, the stubs and the
  /// attributes match: the same attribute names, protected ones included,
  /// and for each of them values that are equal as Python compares them.
  ///
  /// A list is compared element by element, in order, and a map entry by
  /// entry, with the keys equal and the values equal, whatever order the
  /// entries come in; any other value is compared with its own `==`, and so
  /// is a map key. Two containers that are the very same object are equal
  /// without being walked into.
  ///
  /// A module is equal to itself whatever its attributes hold, as upstream's
  /// is (Python compares one dict with itself).
  @override
  // The module is immutable in shape: its attributes are copied once and
  // never change. The values they hold are the host's own objects, which
  // the module cannot make immutable, so the class is not @immutable.
  // ignore: avoid_equals_and_hash_code_on_mutable_classes
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! ExternalModule) return false;

    return _ModuleEquality().equals(this, other);
  }

  /// A hash over the id, the stubs and the attribute names, never over the
  /// attribute values: two equal modules have the same hash, but two
  /// modules that differ only in a value may share one.
  @override
  // The hash follows the equality above, which the class cannot be
  // @immutable for.
  // ignore: avoid_equals_and_hash_code_on_mutable_classes
  int get hashCode =>
      Object.hash(id, stubs, Object.hashAllUnordered(_attrs.keys));

  /// Upstream's `__repr__`:
  /// `ExternalModule(<attrs>, stubs=<stubs or None>, id=UUID('<id>'))`.
  @override
  String toString() {
    final stubsText = switch (stubs) {
      null => 'None',
      final value => pythonRepr(value),
    };

    return 'ExternalModule(${_attrs.length} attrs, stubs=$stubsText, '
        "id=UUID('$id'))";
  }

  /// A module has no tagged JSON representation, so the projection refuses
  /// one.
  @override
  Object? _toJson() => throw UnsupportedError(
    'ExternalModule has no tagged JSON representation',
  );

  /// The module's attributes, copied and checked as upstream's constructor
  /// checks them: string keys, no key twice, identifier keys (a keyword is
  /// not one), and a nested module only under a key that may name a host
  /// module.
  ///
  /// The checks run in upstream's order, so a key seen twice is reported as
  /// such even when it is not an identifier.
  static Map<String, Object?> _checkedAttrs(Map<Object?, Object?> attrs) {
    final copy = <String, Object?>{};
    for (final entry in attrs.entries) {
      final key = entry.key;
      if (key is! String) {
        throw ArgumentError(
          'ExternalModule attrs must have str keys, not ${key.runtimeType}',
        );
      }
      if (copy.containsKey(key)) {
        throw ArgumentError(
          'ExternalModule attrs has the key ${pythonRepr(key)} twice',
        );
      }
      if (!isValidIdentifier(key)) {
        throw ArgumentError(
          'ExternalModule attrs must have identifier keys, '
          'not ${pythonRepr(key)}',
        );
      }
      final value = entry.value;
      if (value is ExternalModule) {
        final error = moduleNameError(key);
        if (error != null) {
          throw ArgumentError("ExternalModule attrs['$key']: $error");
        }
      }
      copy[key] = value;
    }

    return Map.unmodifiable(copy);
  }
}
