part of 'monty_value.dart';

// ---------------------------------------------------------------------------
// Host objects and host functions
// ---------------------------------------------------------------------------
//
// The wrappers that expose a Dart object, a Dart class or a Dart function to
// the sandbox: upstream's `ClassInstance` and `ClassType`
// (pydantic-monty 1.1.0 `class_instance.py`) and a Python callable. They are
// values (C1 q6 (a), API1), so inputs, resumes and containers can hold them,
// and a registered object returned by the sandbox decodes to its wrapper.
// Each session's registry of the wrappers it has sent is HostObjects
// (worker/host_objects.dart).

/// A Dart class as a Python class: its name and its members. Upstream reads
/// both from the class object; Dart has no reflection, so they are given.
final class HostClass<T extends Object> {
  /// The class [name] and its members.
  const HostClass(
    this.name, {
    this.isDataclass = false,
    this.instance = const (
      fields: <String, Never>{},
      properties: <String, Never>{},
      methods: <String, Never>{},
    ),
    this.attributes = const {},
    this.methods = const {},
    this.construct,
  });

  /// The Python-visible class name, such as `Point`.
  final String name;

  /// Whether the class is a dataclass in the sandbox.
  final bool isDataclass;

  /// The members of each instance, by name: what upstream reads with
  /// `getattr` on an instance.
  ///
  /// - `fields`: the instance's data, a dataclass's fields or `__dict__`:
  ///   what an eager `'all'` policy sends.
  /// - `properties`: computed attributes, `@property` upstream: readable by
  ///   name, never sent by an eager `'all'`.
  /// - `methods`: the methods defined on the class, each called with its
  ///   receiver: what an `'all'` method policy allows.
  final ({
    Map<String, Object Function(T self)> fields,
    Map<String, Object Function(T self)> properties,
    Map<
      String,
      FutureOr<Object> Function(
        T self,
        List<MontyValue> args,
        Map<String, MontyValue> kwargs,
      )
    >
    methods,
  })
  instance;

  /// The class constants: what an eager `'all'` sends with the class.
  final Map<String, Object Function()> attributes;

  /// The classmethods and staticmethods, the only methods callable on the
  /// class.
  final Map<
    String,
    FutureOr<Object> Function(
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    )
  >
  methods;

  /// Builds an instance for `__call__` from the call's arguments; a class
  /// without one cannot be instantiated from the sandbox.
  final T Function(List<MontyValue> args, Map<String, MontyValue> kwargs)?
  construct;
}

/// A host function as a value: a Python callable named [name].
///
/// It is sent as a function node carrying [name] and [docstring], as
/// upstream's encoder sends any callable, in `inputs`, a manual resume, an
/// external result or a container. A call from the sandbox dispatches by
/// that name through the session's external functions; [fn] itself is
/// never registered by being sent, as upstream keeps no callable either.
///
/// Input only: a function the sandbox returns decodes to a [MontyString]
/// with its name, so no decoded result holds one. An exhaustive `switch`
/// over a result names it in an arm that throws, for example
/// `StateError('unreachable: MontyHostFunction is input-only')`.
///
/// `==` and `hashCode` are identity, as a Python function's.
final class MontyHostFunction extends MontyValue {
  /// The function [fn], called [name] in the sandbox, with [docstring].
  const MontyHostFunction(this.name, this.fn, {this.docstring});

  /// The name the sandbox calls it by.
  final String name;

  /// The function: positional and keyword arguments in, a value out.
  final FutureOr<MontyValue> Function(
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  )
  fn;

  /// Its `__doc__`, if any.
  final String? docstring;

  /// The function itself.
  @override
  FutureOr<MontyValue> Function(List<MontyValue>, Map<String, MontyValue>)
  // `dartValue` is the sealed family's projection; its name is fixed.
  // ignore: match-getter-setter-field-names
  get dartValue => fn;

  @override
  String toString() => 'MontyHostFunction($name)';

  @override
  Map<String, Object?> _toJson() => {
    '__type': 'function',
    'name': name,
    'docstring': docstring,
  };
}

/// A method read as an attribute, as `getattr` returns a bound method or a
/// classmethod: callable from Dart, and sent into the sandbox as a function
/// named [name], as upstream's encoder sends any callable. Made only by the
/// wrappers; a host's `convertValue` hook receives one for a method
/// attribute, as upstream's `convert_value` receives the bound method (a
/// Dart closure has no `__name__`, so the name travels with it).
final class BoundMethod {
  /// [function], read under [name].
  const BoundMethod(this.name, this.function);

  /// The attribute name it was read under.
  final String name;

  /// The method, its receiver bound.
  final FutureOr<Object> Function(
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  )
  function;
}

/// A class-level method: a classmethod or staticmethod upstream.
typedef _HostMethod =
    FutureOr<Object> Function(
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    );

/// The instance members of a [HostClass] ([HostClass.instance]).
typedef _Members<T> = ({
  Map<String, Object Function(T self)> fields,
  Map<String, Object Function(T self)> properties,
  Map<
    String,
    FutureOr<Object> Function(
      T self,
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    )
  >
  methods,
});

/// Upstream's three exposure policies, as the wrappers take them. Each is
/// `null` (nothing), `'all'` (everything the wrapper deems public), or an
/// [Iterable] of names (those exactly). Any other `String` is refused, as
/// upstream refuses a bare `str` with `TypeError`.
typedef _Policies = ({
  Object? eagerAttrs,
  Object? lazyAttrs,
  Object? allowedMethods,
});

/// Nothing exposed: the wrappers' default policies.
const _Policies _none = (
  eagerAttrs: null,
  lazyAttrs: null,
  allowedMethods: null,
);

/// [policies] as a wrapper keeps them, copied as upstream's `__post_init__`
/// normalises them: the eager names a fixed list (the send order), the
/// others fixed sets, so later changes to the caller's collections expose
/// nothing. Throws [ArgumentError] for a policy upstream refuses; [prefix]
/// names the field as upstream does (`instance_` for a class's instance
/// policies).
_Policies _normalized(_Policies policies, [String prefix = '']) => (
  eagerAttrs: _normalize(
    '${prefix}eager_attrs',
    policies.eagerAttrs,
    List.unmodifiable,
  ),
  lazyAttrs: _normalize(
    '${prefix}lazy_attrs',
    policies.lazyAttrs,
    Set.unmodifiable,
  ),
  allowedMethods: _normalize(
    '${prefix}allowed_methods',
    policies.allowedMethods,
    Set.unmodifiable,
  ),
);

Object? _normalize(
  String field,
  Object? policy,
  Iterable<String> Function(Iterable<String>) collect,
) {
  if (policy == null || policy == 'all') return policy;
  if (policy is Iterable<String>) return collect(policy);
  final shown = policy is String ? "'$policy'" : '$policy';
  throw ArgumentError.value(
    policy,
    field,
    "$field must be 'all', None or a set of names, got $shown",
  );
}

/// Whether [policy] exposes [name].
bool _allows(Object? policy, String name) =>
    policy == 'all' || (policy is Iterable<String> && policy.contains(name));

/// The names an eager [policy] sends, given the public names `'all'` means.
Iterable<String> _eagerNames(Object? policy, Iterable<String> all) =>
    switch (policy) {
      'all' => all.where((n) => !n.startsWith('_')),
      final Iterable<String> names => names,
      _ => const [],
    };

/// The `AttributeError` a denied or missing member raises.
ExternalException _noAttribute(String owner, String name) =>
    ExternalException('AttributeError', "$owner has no attribute '$name'");

/// Process-wide default class ids, never evicted, so a class keeps one
/// identity across sessions (upstream's `type_id_cache`, keyed there by
/// `module.qualname` and here by the [HostClass]).
final Map<HostClass<Object>, String> _typeIds = Map.identity();

final Random _random = Random.secure();

/// A random (version 4) uuid, canonical and lowercase: version digit 4,
/// variant digit 8 to b.
String _uuid4() {
  final hex = [
    for (var i = 0; i < 32; i++)
      switch (i) {
        12 => 4,
        16 => _random.nextInt(4) + 8,
        _ => _random.nextInt(16),
      }.toRadixString(16),
  ].join();

  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

final RegExp _canonicalUuid = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

String _checkedId(String id) {
  if (!_canonicalUuid.hasMatch(id)) {
    throw ArgumentError.value(id, 'id', 'not a uuid');
  }

  return id.toLowerCase();
}

/// Upstream's `ClassType`: exposes a class to the sandbox.
///
/// [policies] expose the class itself: its constants ([HostClass.attributes])
/// and its classmethods ([HostClass.methods]). With [init] the sandbox may
/// call the class; the call is a `__call__` method call, built by
/// [HostClass.construct], and the instance crosses back wrapped with
/// [instancePolicies]. [convertValue] transforms every value that crosses
/// from the class or from an instance that carries it.
///
/// A [MontyValue]: a class the sandbox returns decodes to the [ClassType]
/// registered under its id, and [dartValue] is [value]. `==` and `hashCode`
/// are identity (`host-wrapper-identity-eq`).
final class ClassType<T extends Object> extends MontyValue {
  /// Exposes [value]. Without [id] the class's process-wide id is used,
  /// made on first use.
  ///
  /// Each policy is upstream's field of the same name: `null` (nothing),
  /// `'all'` (everything the wrapper deems public) or an [Iterable] of names
  /// (those exactly), copied here; any other `String` is an [ArgumentError]
  /// with upstream's `TypeError` text.
  ClassType(
    this.value, {
    String? id,
    ({Object? eagerAttrs, Object? lazyAttrs, Object? allowedMethods}) policies =
        _none,
    this.init = false,
    ({Object? eagerAttrs, Object? lazyAttrs, Object? allowedMethods})
        instancePolicies =
        _none,
    Object Function(String name, Object value)? convertValue,
  }) : id = id == null ? _typeIds.putIfAbsent(value, _uuid4) : _checkedId(id),
       policies = _normalized(policies),
       instancePolicies = _normalized(instancePolicies, 'instance_'),
       _convert = convertValue;

  /// The class.
  final HostClass<T> value;

  /// The class's identity in the sandbox, a canonical lowercase uuid.
  final String id;

  /// What the class itself exposes.
  final ({Object? eagerAttrs, Object? lazyAttrs, Object? allowedMethods})
  policies;

  /// Whether sandbox code may instantiate the class. Host-side only: it
  /// never crosses the wire.
  final bool init;

  /// The policies of each instance the sandbox constructs.
  final ({Object? eagerAttrs, Object? lazyAttrs, Object? allowedMethods})
  instancePolicies;

  final Object Function(String name, Object value)? _convert;

  @override
  // `dartValue` is the sealed family's projection; its name is fixed.
  // ignore: match-getter-setter-field-names
  HostClass<T> get dartValue => value;

  @override
  String toString() => 'ClassType(${value.name}, id: $id)';

  @override
  Map<String, Object?> _toJson() => {
    '__type': 'host_class',
    'name': value.name,
    'id': id,
  };

  /// The class constants sent with the class: `'all'` sends every public
  /// one, a list exactly those, each through [convertValue].
  ///
  /// `'all'` skips a constant that holds a function, as upstream's
  /// `_is_class_machinery` skips callables; a name listed explicitly is
  /// read whatever it holds.
  Map<String, Object> _eagerAttributes() {
    final all = policies.eagerAttrs == 'all';

    return _convertAll(this, [
      for (final name in _eagerNames(
        policies.eagerAttrs,
        value.attributes.keys,
      ))
        if (_attribute(name) case final read when !all || read is! BoundMethod)
          (name, read),
    ]);
  }

  /// A lazy class attribute; `AttributeError` when [name] is not exposed.
  Object _lookupLazyAttr(String name) {
    if (!_allows(policies.lazyAttrs, name)) throw _error(name);

    return convertValue(name, _attribute(name));
  }

  /// Calls the class: `__call__` constructs, any other name is a
  /// classmethod allowed by [policies].
  FutureOr<Object> _callMethod(
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) {
    if (name == '__call__') return construct(args, kwargs);
    final method = value.methods[name];
    if (method == null || !_allows(policies.allowedMethods, name)) {
      throw _error(name);
    }

    return _converted(this, name, method(args, kwargs));
  }

  /// Builds an instance for the sandbox, checking [init] on every call, and
  /// wraps it with [instancePolicies] and this class.
  ClassInstance<T> _construct(
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) {
    final build = value.construct;
    if (!init || build == null) {
      throw ExternalException(
        'TypeError',
        "cannot instantiate host class '${value.name}'",
      );
    }

    return ClassInstance(
      build(args, kwargs),
      classType: this,
      policies: instancePolicies,
    );
  }

  /// The hook: [item] as it crosses for member [name]; unchanged by
  /// default.
  Object _convertValue(String name, Object item) =>
      _convert?.call(name, item) ?? item;

  /// What `getattr` on the class finds: a constant, else a classmethod,
  /// else an instance method (the plain function, sent by name).
  Object _attribute(String name) =>
      _maybeNamed(name, value.attributes[name]?.call()) ??
      switch (value.methods[name]) {
        final m? => BoundMethod(name, m),
        null when value.instance.methods.containsKey(name) => BoundMethod(
          name,
          (args, kwargs) => throw _unbound(name),
        ),
        null => throw _error(name),
      };

  /// An instance method read from the class has no receiver; it is never
  /// called through the class, whose method calls are classmethods only.
  ExternalException _unbound(String name) => ExternalException(
    'TypeError',
    "unbound method '${value.name}.$name' needs an instance",
  );

  ExternalException _error(String name) =>
      _noAttribute("type object '${value.name}'", name);
}

/// Upstream's `ClassInstance`: exposes a host object to the sandbox.
///
/// The sandbox routes lazy attribute reads and method calls back to
/// [value] by [id], and a result that is the instance decodes to this
/// wrapper. [classType] is the instance's class as the sandbox sees it
/// (`type(x)`), and its constants cross with every crossing of the
/// instance.
///
/// A [MontyValue]: an instance the sandbox returns decodes to the
/// [ClassInstance] registered under its id (upstream returns the object
/// itself; the wrapper carries it as [value]), and [dartValue] is [value].
/// `==` and `hashCode` are identity (`host-wrapper-identity-eq`).
final class ClassInstance<T extends Object> extends MontyValue {
  /// Exposes [value] as an instance of [classType]. Without [id] a random
  /// one is made.
  ///
  /// Each policy is upstream's field of the same name: `null` (nothing),
  /// `'all'` (everything the wrapper deems public) or an [Iterable] of names
  /// (those exactly), copied here; any other `String` is an [ArgumentError]
  /// with upstream's `TypeError` text.
  ClassInstance(
    this.value, {
    required this.classType,
    String? id,
    ({Object? eagerAttrs, Object? lazyAttrs, Object? allowedMethods}) policies =
        _none,
    Object Function(String name, Object value)? convertValue,
  }) : id = id == null ? _uuid4() : _checkedId(id),
       policies = _normalized(policies),
       _convert = convertValue;

  /// The instance.
  final T value;

  /// The instance's class.
  final ClassType<T> classType;

  /// The instance's identity in the sandbox, a canonical lowercase uuid.
  final String id;

  /// What the instance exposes.
  final ({Object? eagerAttrs, Object? lazyAttrs, Object? allowedMethods})
  policies;

  final Object Function(String name, Object value)? _convert;

  @override
  // `dartValue` is the sealed family's projection; its name is fixed.
  // ignore: match-getter-setter-field-names
  T get dartValue => value;

  @override
  String toString() => 'ClassInstance(${classType.value.name}, id: $id)';

  @override
  Map<String, Object?> _toJson() => {
    '__type': 'host_instance',
    'class': classType.value.name,
    'id': id,
  };

  _Members<T> get _members => classType.value.instance;

  /// The attributes sent with the instance: `'all'` sends every public
  /// field, a list exactly those names, each through [convertValue].
  Map<String, Object> _eagerAttributes() => _convertAll(this, [
    for (final name in _eagerNames(policies.eagerAttrs, _members.fields.keys))
      (name, _attribute(name)),
  ]);

  /// A lazy attribute; `AttributeError` when [name] is not exposed. Any
  /// other throw is raised in the sandbox.
  Object _lookupLazyAttr(String name) {
    if (!_allows(policies.lazyAttrs, name)) throw _error(name);

    return convertValue(name, _attribute(name));
  }

  /// Calls method [name] on [value]. `__call__` is always refused on an
  /// instance. Under `'all'` only the class's methods qualify; a name
  /// granted explicitly calls whatever the attribute holds, as upstream
  /// calls what `getattr` returns.
  FutureOr<Object> _callMethod(
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) {
    final policy = policies.allowedMethods;
    if (name == '__call__' || !_allows(policy, name)) throw _error(name);
    // Under 'all' only a method the class defines qualifies; what is
    // called is still what the attribute resolves to.
    if (policy == 'all' && _method(name) == null) throw _error(name);

    return _converted(this, name, _callable(name)(args, kwargs));
  }

  /// The hook: this wrapper's, or else its class's.
  Object _convertValue(String name, Object item) =>
      _convert?.call(name, item) ?? classType.convertValue(name, item);

  /// A method defined on the class: an instance method bound to [value],
  /// or a classmethod or staticmethod, as `getattr` finds them.
  _HostMethod? _method(String name) => switch (_members.methods[name]) {
    final m? => (args, kwargs) => m(value, args, kwargs),
    null => classType.value.methods[name],
  };

  /// The attribute [name] as a callable: a method it holds, or
  /// `TypeError` for any other value.
  _HostMethod _callable(String name) => switch (_attribute(name)) {
    BoundMethod(:final function) => function,
    final _HostMethod m => m,
    final other => throw ExternalException(
      'TypeError',
      "'${_typeName(other)}' object is not callable",
    ),
  };

  /// What `getattr` on the instance finds: its own data first, then its
  /// methods (bound), then its class's constants.
  Object _attribute(String name) {
    final read = _members.fields[name] ?? _members.properties[name];
    if (read != null) return _named(name, read(value));
    if (_method(name) case final method?) return BoundMethod(name, method);
    final constant = classType.value.attributes[name];

    return _named(name, (constant ?? (throw _error(name)))());
  }

  ExternalException _error(String name) =>
      _noAttribute("'${classType.value.name}' object", name);
}

/// [raw], every value read first, then each through [wrapper]'s hook, as
/// upstream's `get_eager_attrs` reads them all before converting: a name
/// listed twice is read and converted twice, and the later value is kept.
Map<String, Object> _convertAll(
  Object wrapper,
  List<(String, Object)> raw,
) => {
  for (final (key, value) in raw)
    key: switch (wrapper) {
      ClassInstance() => wrapper.convertValue(key, value),
      ClassType() => wrapper.convertValue(key, value),
      _ => value,
    },
};

/// [result] through [wrapper]'s hook once it is known: a future's value
/// after it completes.
FutureOr<Object> _converted(
  Object wrapper,
  String name,
  FutureOr<Object> result,
) {
  Object convert(Object v) => switch (wrapper) {
    ClassInstance() => wrapper.convertValue(name, v),
    ClassType() => wrapper.convertValue(name, v),
    _ => v,
  };

  return result is Future<Object> ? _later(result, convert) : convert(result);
}

/// [result]'s value through [convert], once it completes: the hook sees the
/// resolved value, never the future (upstream's `_convert_awaited`).
Future<Object> _later(
  Future<Object> result,
  Object Function(Object) convert,
) async => convert(await result);

/// The Python type name of a value a host attribute holds.
String _typeName(Object value) => switch (value) {
  ClassInstance(:final classType) => classType.value.name,
  MontyInt() || MontyBigInt() => 'int',
  MontyFloat() => 'float',
  MontyString() => 'str',
  MontyBool() => 'bool',
  MontyNone() => 'NoneType',
  _ => _otherTypeName(value),
};

String _otherTypeName(Object value) => switch (value) {
  MontyList() => 'list',
  MontyTuple() => 'tuple',
  MontyDict() => 'dict',
  ClassType() => 'type',
  _ => '${value.runtimeType}',
};

/// [value], a function held by attribute [name] named after it, so it
/// crosses as a function as upstream sends any callable (a Dart closure has
/// no `__name__`; the attribute name stands in).
Object _named(String name, Object value) =>
    value is _HostMethod ? BoundMethod(name, value) : value;

Object? _maybeNamed(String name, Object? value) =>
    value == null ? null : _named(name, value);

/// The object a host-object [wrapper] wraps: what upstream's store
/// resolves its id to, and what identity is judged by.
@internal
Object wrappedValue(Object wrapper) => switch (wrapper) {
  ClassInstance(:final value) => value,
  ClassType(:final value) => value,
  _ => wrapper,
};

/// [ClassType]'s dispatch members, which the session calls (HOST1: internal,
/// item 68). The public show list leaves this extension out.
extension ClassTypeInternal<T extends Object> on ClassType<T> {
  /// The eager class attributes, converted.
  Map<String, Object> eagerAttributes() => _eagerAttributes();

  /// A lazy class attribute by [name].
  Object lookupLazyAttr(String name) => _lookupLazyAttr(name);

  /// A call on the class: `__call__` constructs, else a classmethod.
  FutureOr<Object> callMethod(
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) => _callMethod(name, args, kwargs);

  /// Constructs an instance from [args] and [kwargs].
  ClassInstance<T> construct(
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) => _construct(args, kwargs);

  /// [item] as it crosses for member [name].
  Object convertValue(String name, Object item) => _convertValue(name, item);
}

/// [ClassInstance]'s dispatch members, which the session calls (HOST1:
/// internal, item 68). The public show list leaves this extension out.
extension ClassInstanceInternal<T extends Object> on ClassInstance<T> {
  /// The eager instance attributes, converted.
  Map<String, Object> eagerAttributes() => _eagerAttributes();

  /// A lazy instance attribute by [name].
  Object lookupLazyAttr(String name) => _lookupLazyAttr(name);

  /// A method call on the instance.
  FutureOr<Object> callMethod(
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) => _callMethod(name, args, kwargs);

  /// [item] as it crosses for member [name].
  Object convertValue(String name, Object item) => _convertValue(name, item);
}
