// Shared test body for ffi_dataclass_hydrate_test.dart and
// wasm_dataclass_hydrate_test.dart.
//
// Validates the end-to-end Python → Dart dataclass hydration path: an
// external function returns a dataclass JSON envelope, the engine round-
// trips it through Python, and Dart hydrates the returned MontyDataclass
// into a user class via MontyDataclass.hydrate.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

class _User {
  const _User({required this.name, required this.age});

  final String name;
  final int age;
}

class _Order {
  const _Order({required this.id, required this.total});

  final int id;
  final double total;
}

Map<String, Object?> _userDataclass({required String name, required int age}) =>
    {
      '__type': 'dataclass',
      'name': 'User',
      'type_id': 1,
      'field_names': ['name', 'age'],
      'attrs': {'name': name, 'age': age},
      'frozen': false,
    };

Map<String, Object?> _orderDataclass({
  required int id,
  required double total,
}) => {
  '__type': 'dataclass',
  'name': 'Order',
  'type_id': 2,
  'field_names': ['id', 'total'],
  'attrs': {'id': id, 'total': total},
  'frozen': false,
};

void runDataclassHydrateTests() {
  group('MontyDataclass hydration via external function', () {
    test(
      'Python returns a dataclass; Dart hydrates into a user class',
      () async {
        final r = await Monty('make_user("alice", 30)').run(
          externalFunctions: {
            'make_user': (args) async => _userDataclass(
              name: args['_0']! as String,
              age: args['_1']! as int,
            ),
          },
        );

        expect(r.error, isNull);
        expect(r.value, isA<MontyDataclass>());

        final dc = r.value as MontyDataclass;
        expect(dc.name, 'User');
        expect(dc.dartAttrs, {'name': 'alice', 'age': 30});

        final user = dc.hydrate(
          (a) => _User(name: a['name']! as String, age: a['age']! as int),
        );
        expect(user.name, 'alice');
        expect(user.age, 30);
      },
    );

    test('caller-side registry pattern resolves multiple types', () async {
      final factories = <String, Object Function(Map<String, Object?>)>{
        'User': (a) => _User(name: a['name']! as String, age: a['age']! as int),
        'Order': (a) =>
            _Order(id: a['id']! as int, total: a['total']! as double),
      };

      Future<Object?> dispatchAndHydrate(String code) async {
        final r = await Monty(code).run(
          externalFunctions: {
            'make_user': (args) async => _userDataclass(name: 'eve', age: 9),
            'make_order': (args) async => _orderDataclass(id: 99, total: 12.5),
          },
        );
        if (r.value is! MontyDataclass) return r.value;
        final dc = r.value as MontyDataclass;
        return factories[dc.name]?.call(dc.dartAttrs);
      }

      final user = await dispatchAndHydrate('make_user()');
      expect(user, isA<_User>());
      expect((user! as _User).name, 'eve');

      final order = await dispatchAndHydrate('make_order()');
      expect(order, isA<_Order>());
      expect((order! as _Order).total, 12.5);
    });

    test(
      'frozen flag and field_names round-trip through MontyDataclass',
      () async {
        final r = await Monty('make_user("frank", 20)').run(
          externalFunctions: {
            'make_user': (args) async => {
              ..._userDataclass(
                name: args['_0']! as String,
                age: args['_1']! as int,
              ),
              'frozen': true,
            },
          },
        );

        final dc = r.value as MontyDataclass;
        expect(dc.frozen, true);
        expect(dc.fieldNames, ['name', 'age']);
      },
    );
  });
}
