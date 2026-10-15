/// Host objects in the sandbox: each session's registry of the wrappers it
/// has sent (upstream's `InstanceStore`, pydantic-monty 1.1.0
/// `class_instance.py`, `monty-proto/src/python/class_instance.rs`).
///
/// The wrappers themselves, [ClassType] and [ClassInstance], and the
/// [HostClass] that describes a class, are values and live in the value
/// library (`platform/host_class.dart`); this library re-exports them
/// for the session, the writer and the reader.
///
/// A wrapper is a policy: which attributes cross eagerly, which the sandbox
/// may read lazily, which methods it may call, and whether it may construct
/// the class. Dart has no reflection, so the members a policy names come
/// from a [HostClass], the Dart stand-in for the Python class object.
///
/// Both wrappers' `==` and `hashCode` are identity (divergence
/// `host-wrapper-identity-eq`): upstream's are dataclasses, equal when their
/// fields are and unhashable, which a Dart object cannot be.
library;

import 'dart:async';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart'
    show HostObjectLookup;
import 'package:dart_monty_core/src/worker/arena_writer.dart'
    show PythonRefusal;
import 'package:dart_monty_core/src/worker/monty_snapshot.dart'
    show ExternalException;
import 'package:meta/meta.dart';

export 'package:dart_monty_core/src/platform/monty_value.dart'
    show
        BoundMethod,
        ClassInstance,
        ClassInstanceInternal,
        ClassType,
        ClassTypeInternal,
        HostClass,
        wrappedValue;

/// One session's host objects by id: every [ClassInstance] and [ClassType]
/// that crossed into the sandbox, in one id namespace (upstream's
/// `InstanceStore`). Never part of a dump: a loaded session starts empty.
@internal
final class HostObjects {
  final Map<String, MontyValue> _objects = {};

  /// The wrapper registered under [id], or null.
  MontyValue? operator [](String id) => _objects[id.toLowerCase()];

  /// Registers [wrapper] under its id. The same object re-sent with a new
  /// wrapper replaces the entry; an id bound to a different object is
  /// refused with `ValueError`.
  void register(MontyValue wrapper) {
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
  MontyValue? call(String id) => this[id];

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

  void _checkNoAlias(String id, MontyValue wrapper) {
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

/// Throws `AttributeError` for a method name upstream never dispatches: one
/// starting with `_`, other than `__call__`.
@internal
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
