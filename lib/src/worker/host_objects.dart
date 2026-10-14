/// Host objects in the sandbox: the wrappers that expose a Dart object or
/// class to Python, and each session's registry of the ones it has sent
/// (upstream's `ClassInstance`, `ClassType` and `InstanceStore`,
/// pydantic-monty 1.1.0 `class_instance.py`, `monty-proto/src/python/
/// class_instance.rs`).
///
/// A wrapper is a policy: which attributes cross eagerly, which the sandbox
/// may read lazily, which methods it may call, and whether it may construct
/// the class. Dart has no reflection, so the members a policy names come
/// from a [HostClass], the Dart stand-in for the Python class object.
///
/// The wrappers join the `MontyValue` family at the cutover. Until then
/// they are internal and cross where a host value may be a wrapper: a
/// feed's inputs, a manual resume's value, and what a wrapper's own
/// members return.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';
import 'dart:math';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart'
    show HostObjectLookup;
import 'package:dart_monty_core/src/worker/arena_writer.dart'
    show PythonRefusal;
import 'package:dart_monty_core/src/worker/monty_snapshot.dart'
    show ExternalException;

/// One session's host objects by id: every [ClassInstance] and [ClassType]
/// that crossed into the sandbox, in one id namespace (upstream's
/// `InstanceStore`). Never part of a dump: a loaded session starts empty.
final class HostObjects {
  final Map<String, Object> _objects = {};

  /// The wrapper registered under [id], or null.
  Object? operator [](String id) => _objects[id.toLowerCase()];

  /// Registers [wrapper] under its id. The same object re-sent with a new
  /// wrapper replaces the entry; an id bound to a different object is
  /// refused with `ValueError`.
  void register(Object wrapper) {
    final id = _idOf(wrapper);
    _checkNoAlias(id, wrapper);
    _objects[id] = wrapper;
  }

  /// Registers the class [wrapper] only if its id is free, so a class an
  /// instance carries never replaces an explicitly sent one; an id bound to
  /// a different class is still refused.
  void registerIfAbsent(ClassType<Object> wrapper) {
    _checkNoAlias(wrapper.id, wrapper);
    _objects.putIfAbsent(wrapper.id, () => wrapper);
  }

  /// Forgets every object, as a load or a new checkout starts empty.
  void clear() => _objects.clear();

  /// The reader's view: a class or instance node resolves to the wrapper
  /// registered under its id.
  HostObjectLookup get lookup => (classType: call, instance: call);

  /// The wrapper registered under [id], or null.
  Object? call(String id) => this[id];

  /// The value a lazy attribute [name] of the object [id] resolves to;
  /// null when it is not exposed (an underscore name, an unknown id, or an
  /// `AttributeError` from the wrapper). Any other throw propagates.
  Object? lookupLazyAttr(String id, String name) {
    if (name.startsWith('_')) return null;
    try {
      return switch (this[id]) {
        final ClassInstance<Object> w => w.lookupLazyAttr(name),
        final ClassType<Object> w => w.lookupLazyAttr(name),
        _ => null,
      };
    } on ExternalException catch (e) {
      if (e.excType == 'AttributeError') return null;
      rethrow;
    }
  }

  /// Calls method [name] on the object [id]. An underscore name other than
  /// `__call__` is refused before any lookup; an unknown id raises
  /// `RuntimeError`.
  FutureOr<Object> callMethod(
    String id,
    String name,
    List<MontyValue> args,
    Map<String, MontyValue> kwargs,
  ) => switch (this[id]) {
    final ClassInstance<Object> w => w.callMethod(name, args, kwargs),
    final ClassType<Object> w => w.callMethod(name, args, kwargs),
    _ => throw ExternalException(
      'RuntimeError',
      "no host object registered for method call '$name' (id "
          '${id.toLowerCase()}) — the instance store is empty after loading '
          'a dump into a fresh session',
    ),
  };

  void _checkNoAlias(String id, Object wrapper) {
    final existing = _objects[id];
    if (existing != null &&
        !identical(wrappedValue(existing), wrappedValue(wrapper))) {
      throw PythonRefusal(
        wrapper,
        'its id is bound to a different object in this session',
        'ValueError',
        'wrapper id $id already identifies a different object in this '
            'session',
      );
    }
  }
}

/// A method read as an attribute, as `getattr` returns a bound method or a
/// classmethod: callable from Dart, and sent into the sandbox as a function
/// named [name], as upstream's encoder sends any callable.
final class BoundMethod {
  /// [function], read under [name].
  const BoundMethod(this.name, this.function);

  /// The attribute name it was read under.
  final String name;

  /// The method, its receiver bound.
  final HostMethod function;
}

/// A class-level method: a classmethod or staticmethod upstream.
typedef HostMethod =
    FutureOr<Object> Function(
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    );

/// An instance method, called with its receiver.
typedef HostInstanceMethod<T> =
    FutureOr<Object> Function(
      T self,
      List<MontyValue> args,
      Map<String, MontyValue> kwargs,
    );

/// Upstream's `convert_value` hook: transforms an attribute's value or a
/// method's result, by member [name], before it crosses into the sandbox.
typedef ConvertValue = Object Function(String name, Object value);

/// Builds an instance from a constructor call's arguments.
typedef HostConstructor<T> =
    T Function(List<MontyValue> args, Map<String, MontyValue> kwargs);

/// The instance members of a [HostClass], by name: what upstream reads with
/// `getattr` on an instance.
final class HostMembers<T extends Object> {
  /// The instance members.
  const HostMembers({
    this.fields = const {},
    this.properties = const {},
    this.methods = const {},
  });

  /// The instance's data, a dataclass's fields or `__dict__`: what an
  /// eager `'all'` policy sends.
  final Map<String, Object Function(T self)> fields;

  /// Computed attributes, `@property` upstream: readable by name, never sent
  /// by an eager `'all'`.
  final Map<String, Object Function(T self)> properties;

  /// The methods defined on the class: what an `'all'` method policy
  /// allows.
  final Map<String, HostInstanceMethod<T>> methods;
}

/// A Dart class as a Python class: its name and its members. Upstream reads
/// both from the class object; Dart has no reflection, so they are given.
final class HostClass<T extends Object> {
  /// The class [name] and its members.
  const HostClass(
    this.name, {
    this.isDataclass = false,
    this.instance = const HostMembers(),
    this.attributes = const {},
    this.methods = const {},
    this.construct,
  });

  /// The Python-visible class name, such as `Point`.
  final String name;

  /// Whether the class is a dataclass in the sandbox.
  final bool isDataclass;

  /// The members of each instance.
  final HostMembers<T> instance;

  /// The class constants: what an eager `'all'` sends with the class.
  final Map<String, Object Function()> attributes;

  /// The classmethods and staticmethods, the only methods callable on the
  /// class.
  final Map<String, HostMethod> methods;

  /// Builds an instance for `__call__`; a class without one cannot be
  /// instantiated from the sandbox.
  final HostConstructor<T>? construct;
}

/// Upstream's three exposure policies. Each is `null` (nothing), `'all'`
/// (everything the wrapper deems public), or an [Iterable] of names (those
/// exactly). Any other `String` is refused, as upstream refuses a bare
/// `str` with `TypeError`.
final class HostPolicies {
  /// The policies; by default nothing is exposed.
  const HostPolicies({this.eagerAttrs, this.lazyAttrs, this.allowedMethods});

  /// Nothing exposed.
  static const HostPolicies none = HostPolicies();

  /// The attributes sent with the object, in this order.
  final Object? eagerAttrs;

  /// The attributes the sandbox may read on demand.
  final Object? lazyAttrs;

  /// The methods the sandbox may call.
  final Object? allowedMethods;

  /// These policies as a wrapper keeps them, copied as upstream's
  /// `__post_init__` normalises them: the eager names a fixed list (the send
  /// order), the others fixed sets, so later changes to the caller's
  /// collections expose nothing. Throws [ArgumentError] for a policy
  /// upstream refuses; [prefix] names the field as upstream does
  /// (`instance_` for a class's instance policies).
  HostPolicies normalized([String prefix = '']) => HostPolicies(
    eagerAttrs: _normalize(
      '${prefix}eager_attrs',
      eagerAttrs,
      List.unmodifiable,
    ),
    lazyAttrs: _normalize('${prefix}lazy_attrs', lazyAttrs, Set.unmodifiable),
    allowedMethods: _normalize(
      '${prefix}allowed_methods',
      allowedMethods,
      Set.unmodifiable,
    ),
  );

  static Object? _normalize(
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
final class ClassType<T extends Object> {
  /// Exposes [value]. Without [id] the class's process-wide id is used,
  /// made on first use.
  ClassType(
    this.value, {
    String? id,
    HostPolicies policies = HostPolicies.none,
    this.init = false,
    HostPolicies instancePolicies = HostPolicies.none,
    ConvertValue? convertValue,
  }) : id = id == null ? _typeIds.putIfAbsent(value, _uuid4) : _checkedId(id),
       policies = policies.normalized(),
       instancePolicies = instancePolicies.normalized('instance_'),
       _convert = convertValue;

  /// The class.
  final HostClass<T> value;

  /// The class's identity in the sandbox, a canonical lowercase uuid.
  final String id;

  /// What the class itself exposes.
  final HostPolicies policies;

  /// Whether sandbox code may instantiate the class. Host-side only: it
  /// never crosses the wire.
  final bool init;

  /// The policies of each instance the sandbox constructs.
  final HostPolicies instancePolicies;

  final ConvertValue? _convert;

  /// The class constants sent with the class: `'all'` sends every public
  /// one, a list exactly those, each through [convertValue].
  ///
  /// `'all'` skips a constant that holds a function, as upstream's
  /// `_is_class_machinery` skips callables; a name listed explicitly is
  /// read whatever it holds.
  Map<String, Object> eagerAttributes() {
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
  Object lookupLazyAttr(String name) {
    if (!_allows(policies.lazyAttrs, name)) throw _error(name);

    return convertValue(name, _attribute(name));
  }

  /// Calls the class: `__call__` constructs, any other name is a
  /// classmethod allowed by [policies].
  FutureOr<Object> callMethod(
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
  ClassInstance<T> construct(
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
  Object convertValue(String name, Object item) =>
      _convert?.call(name, item) ?? item;

  /// What `getattr` on the class finds: a constant, else a classmethod,
  /// else an instance method (the plain function, sent by name).
  Object _attribute(String name) =>
      _maybeNamed(name, value.attributes[name]?.call()) ??
      switch (value.methods[name]) {
        final HostMethod m => BoundMethod(name, m),
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
final class ClassInstance<T extends Object> {
  /// Exposes [value] as an instance of [classType]. Without [id] a random
  /// one is made.
  ClassInstance(
    this.value, {
    required this.classType,
    String? id,
    HostPolicies policies = HostPolicies.none,
    ConvertValue? convertValue,
  }) : id = id == null ? _uuid4() : _checkedId(id),
       policies = policies.normalized(),
       _convert = convertValue;

  /// The instance.
  final T value;

  /// The instance's class.
  final ClassType<T> classType;

  /// The instance's identity in the sandbox, a canonical lowercase uuid.
  final String id;

  /// What the instance exposes.
  final HostPolicies policies;

  final ConvertValue? _convert;

  HostMembers<T> get _members => classType.value.instance;

  /// The attributes sent with the instance: `'all'` sends every public
  /// field, a list exactly those names, each through [convertValue].
  Map<String, Object> eagerAttributes() => _convertAll(this, [
    for (final name in _eagerNames(policies.eagerAttrs, _members.fields.keys))
      (name, _attribute(name)),
  ]);

  /// A lazy attribute; `AttributeError` when [name] is not exposed. Any
  /// other throw is raised in the sandbox.
  Object lookupLazyAttr(String name) {
    if (!_allows(policies.lazyAttrs, name)) throw _error(name);

    return convertValue(name, _attribute(name));
  }

  /// Calls method [name] on [value]. `__call__` is always refused on an
  /// instance. Under `'all'` only the class's methods qualify; a name
  /// granted explicitly calls whatever the attribute holds, as upstream
  /// calls what `getattr` returns.
  FutureOr<Object> callMethod(
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
  Object convertValue(String name, Object item) =>
      _convert?.call(name, item) ?? classType.convertValue(name, item);

  /// A method defined on the class: an instance method bound to [value],
  /// or a classmethod or staticmethod, as `getattr` finds them.
  HostMethod? _method(String name) => switch (_members.methods[name]) {
    final HostInstanceMethod<T> m => (args, kwargs) => m(value, args, kwargs),
    null => classType.value.methods[name],
  };

  /// The attribute [name] as a callable: a [HostMethod] it holds, or
  /// `TypeError` for any other value.
  HostMethod _callable(String name) => switch (_attribute(name)) {
    BoundMethod(:final function) => function,
    final HostMethod m => m,
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

/// Throws `AttributeError` for a method name upstream never dispatches: one
/// starting with `_`, other than `__call__`.
void checkHostMethodName(String name) {
  if (name.startsWith('_') && name != '__call__') {
    throw ExternalException(
      'AttributeError',
      "host method '$name' is not exposed",
    );
  }
}

String _idOf(Object wrapper) => wrapper is ClassInstance<Object>
    ? wrapper.id
    : (wrapper as ClassType<Object>).id;

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
    value is HostMethod ? BoundMethod(name, value) : value;

Object? _maybeNamed(String name, Object? value) =>
    value == null ? null : _named(name, value);

/// The object a host-object [wrapper] wraps: what upstream's store
/// resolves its id to, and what identity is judged by.
Object wrappedValue(Object wrapper) => switch (wrapper) {
  ClassInstance(:final value) => value,
  ClassType(:final value) => value,
  _ => wrapper,
};
