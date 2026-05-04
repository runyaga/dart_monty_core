// 10 — Dataclasses: MontyDataclass + dartAttrs + hydrate
//
// Python `@dataclass` values cross the boundary as `MontyDataclass`. Dart
// can read their fields directly, convert all attrs to plain Dart values
// via `dartAttrs`, or hydrate into a user class with `hydrate(factory)`.
//
// Covers: MontyDataclass.name / attrs / fieldNames / frozen,
//         MontyDataclass.dartAttrs, MontyDataclass.hydrate,
//         caller-side registry pattern for multiple types.
//
// Run: dart run example/10_dataclasses.dart

import 'package:dart_monty_core/dart_monty_core.dart';

// ── User-defined Dart classes the example hydrates into. ──────────────────────

class User {
  const User({required this.name, required this.age});

  factory User.fromAttrs(Map<String, Object?> a) =>
      User(name: a['name']! as String, age: a['age']! as int);

  final String name;
  final int age;

  @override
  String toString() => 'User(name=$name, age=$age)';
}

class Order {
  const Order({required this.id, required this.total});

  factory Order.fromAttrs(Map<String, Object?> a) =>
      Order(id: a['id']! as int, total: a['total']! as double);

  final int id;
  final double total;

  @override
  String toString() => 'Order(id=$id, total=$total)';
}

// ── Helper: build the dataclass JSON envelope returned from a Dart callback.
// ─────────────────────────────────────────────────────────────────────────────

Map<String, Object?> _dataclass({
  required String name,
  required int typeId,
  required Map<String, Object?> attrs,
  bool frozen = false,
}) => {
  '__type': 'dataclass',
  'name': name,
  'type_id': typeId,
  'field_names': attrs.keys.toList(),
  'attrs': attrs,
  'frozen': frozen,
};

Future<void> main() async {
  await _readingFields();
  await _hydrateOne();
  await _hydrateRegistry();
}

// ── Read fields directly off MontyDataclass ──────────────────────────────────
// MontyDataclass exposes name, fieldNames, frozen, and the typed attrs map.
// Use dartAttrs when you want a plain `Map<String, Object?>` instead of
// `Map<String, MontyValue>`.
Future<void> _readingFields() async {
  print('\n── reading fields ──');

  final r = await Monty('make_user("alice", 30)').run(
    externalFunctions: {
      'make_user': (args, _) async => _dataclass(
        name: 'User',
        typeId: 1,
        attrs: {'name': args[0]! as String, 'age': args[1]! as int},
      ),
    },
  );

  final dc = r.value as MontyDataclass;
  print('name:       ${dc.name}'); // User
  print('typeId:     ${dc.typeId}'); // 1
  print('fields:     ${dc.fieldNames}'); // [name, age]
  print('frozen:     ${dc.frozen}'); // false
  print('attrs[name]: ${dc.attrs["name"]}'); // MontyString(alice)
  print('dartAttrs:   ${dc.dartAttrs}'); // {name: alice, age: 30}
}

// ── Hydrate into a user-supplied Dart class via a factory ────────────────────
// hydrate<T>(factory) calls factory(dartAttrs) and returns the typed object.
// The factory signature is `T Function(Map<String, Object?> attrs)`.
Future<void> _hydrateOne() async {
  print('\n── hydrate (one type) ──');

  final r = await Monty('make_user("bob", 42)').run(
    externalFunctions: {
      'make_user': (args, _) async => _dataclass(
        name: 'User',
        typeId: 1,
        attrs: {'name': args[0]! as String, 'age': args[1]! as int},
      ),
    },
  );

  final dc = r.value as MontyDataclass;
  final user = dc.hydrate(User.fromAttrs);
  print(user); // User(name=bob, age=42)
}

// ── Caller-side registry for multiple dataclass types ────────────────────────
// A `Map<String, Object Function(Map<String, Object?>)>` keyed by dataclass
// name is the natural way to dispatch. The framework doesn't ship a built-in
// registry on Monty/MontyRepl — composing one at the call site keeps the
// public surface small and the type story clear.
Future<void> _hydrateRegistry() async {
  print('\n── hydrate (registry) ──');

  final factories = <String, Object Function(Map<String, Object?>)>{
    'User': User.fromAttrs,
    'Order': Order.fromAttrs,
  };

  Object? hydrate(MontyValue value) {
    if (value is! MontyDataclass) return value;
    final factory = factories[value.name];
    return factory == null ? value : factory(value.dartAttrs);
  }

  final externalFunctions = <String, MontyCallback>{
    'make_user': (_, _) async =>
        _dataclass(name: 'User', typeId: 1, attrs: {'name': 'carol', 'age': 7}),
    'make_order': (_, _) async =>
        _dataclass(name: 'Order', typeId: 2, attrs: {'id': 99, 'total': 12.5}),
  };

  final ru = await Monty(
    'make_user()',
  ).run(externalFunctions: externalFunctions);
  final ro = await Monty(
    'make_order()',
  ).run(externalFunctions: externalFunctions);

  print(hydrate(ru.value)); // User(name=carol, age=7)
  print(hydrate(ro.value)); // Order(id=99, total=12.5)
}
