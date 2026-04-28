// Unit tests for MontyDataclass.hydrate / dartAttrs — pure value-level
// conversion, no interpreter involved.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

class _User {
  const _User({required this.name, required this.age});

  factory _User.fromAttrs(Map<String, Object?> a) =>
      _User(name: a['name']! as String, age: a['age']! as int);

  final String name;
  final int age;
}

void main() {
  group('MontyDataclass.dartAttrs', () {
    test('converts MontyValue attrs to plain Dart values', () {
      const dc = MontyDataclass(
        name: 'User',
        typeId: 1,
        fieldNames: ['name', 'age'],
        attrs: {
          'name': MontyString('alice'),
          'age': MontyInt(30),
        },
      );

      expect(dc.dartAttrs, {'name': 'alice', 'age': 30});
    });

    test('preserves nested values via dartValue', () {
      const dc = MontyDataclass(
        name: 'Score',
        typeId: 2,
        fieldNames: ['value', 'flag'],
        attrs: {
          'value': MontyFloat(3.14),
          'flag': MontyBool(true),
        },
      );

      expect(dc.dartAttrs, {'value': 3.14, 'flag': true});
    });
  });

  group('MontyDataclass.hydrate', () {
    test('passes dartAttrs to the factory', () {
      const dc = MontyDataclass(
        name: 'User',
        typeId: 1,
        fieldNames: ['name', 'age'],
        attrs: {
          'name': MontyString('bob'),
          'age': MontyInt(42),
        },
      );

      final user = dc.hydrate(_User.fromAttrs);
      expect(user.name, 'bob');
      expect(user.age, 42);
    });

    test('factory return type is preserved via the generic parameter', () {
      const dc = MontyDataclass(
        name: 'User',
        typeId: 1,
        fieldNames: ['name'],
        attrs: {'name': MontyString('carol')},
      );

      final user = dc.hydrate<_User>(
        (a) => _User(name: a['name']! as String, age: 0),
      );
      expect(user, isA<_User>());
      expect(user.name, 'carol');
    });

    test('composes with a caller-side registry', () {
      const dc = MontyDataclass(
        name: 'User',
        typeId: 1,
        fieldNames: ['name', 'age'],
        attrs: {
          'name': MontyString('dave'),
          'age': MontyInt(7),
        },
      );

      final factories = <String, Object Function(Map<String, Object?>)>{
        'User': _User.fromAttrs,
      };

      final dartObject = factories[dc.name]!(dc.dartAttrs) as _User;
      expect(dartObject.name, 'dave');
      expect(dartObject.age, 7);
    });
  });
}
