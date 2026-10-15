// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 10 — Class instances from the sandbox
//
// An instance of a class defined in the sandbox, such as a @dataclass,
// reaches Dart as a MontyClassProxy: its class (name, id, whether it is a
// dataclass) and its attributes as MontyValues. Dart reads the attributes
// directly, or builds its own objects from them; a registry keyed by class
// name handles several classes.
//
// Covers: MontyClassProxy (classType, instanceId, attrs),
//         MontyClassTypeProxy (name, isDataclass), hydrating Dart objects.
//
// Run: dart run example/10_dataclasses.dart

import 'package:dart_monty_core/dart_monty_core.dart';

// ── Dart classes the example builds from sandbox instances ───────────────────
final class User {
  const User(this.name, this.age);
  final String name;
  final int age;
  @override
  String toString() => 'User($name, $age)';
}

final class Order {
  const Order(this.id, this.total);
  final int id;
  final double total;
  @override
  String toString() => 'Order(#$id, $total)';
}

/// Builds a Dart object from a sandbox instance, by class name.
final Map<String, Object Function(Map<String, MontyValue> attrs)> _registry = {
  'User': (a) =>
      User((a['name']! as MontyString).value, (a['age']! as MontyInt).value),
  'Order': (a) =>
      Order((a['id']! as MontyInt).value, (a['total']! as MontyFloat).value),
};

Object _hydrate(MontyValue value) => switch (value) {
  MontyClassProxy(:final classType, :final attrs) =>
    (_registry[classType.name] ??
        (throw StateError('no Dart class for ${classType.name}')))(attrs),
  _ => throw ArgumentError.value(value, 'value', 'not a class instance'),
};

Future<void> main() async {
  await Monty.withPool(
    (monty) => monty.withSession((session) async {
      await session.feedRun('''
from dataclasses import dataclass

@dataclass
class User:
    name: str
    age: int
    active: bool = True

@dataclass
class Order:
    id: int
    total: float
''');

      // ── Reading attributes directly ───────────────────────────────────────
      print('\n── reading attributes ──');
      final u = await session.feedRun('User("Alice", 30)') as MontyClassProxy;
      print(
        'class: ${u.classType.name} (dataclass: ${u.classType.isDataclass})',
      );
      print('instance id: ${u.instanceId}');
      for (final MapEntry(:key, :value) in u.attrs.entries) {
        print('  $key = $value');
      }
      _check(u.classType.isDataclass, 'isDataclass');
      _check(u.attrs['active'] == const MontyBool(true), 'default field');

      // ── Building Dart objects ─────────────────────────────────────────────
      print('\n── hydrating ──');
      final mixed =
          await session.feedRun(
                '[User("Bob", 41), Order(7, 19.5), User("Cy", 25)]',
              )
              as MontyList;
      final objects = mixed.items.map(_hydrate).toList();
      print(objects.join('\n'));
      _check(objects.whereType<User>().length == 2, 'two users');
      _check(objects.whereType<Order>().single.total == 19.5, 'order total');
    }),
  );
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}
