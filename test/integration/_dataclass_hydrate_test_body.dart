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

// These used to be hand-spelled `{'__type': 'dataclass', …}` maps, and the
// interpreter honoured them — which is core#136 pointing from the host into the
// sandbox: any Dart Map whose keys happened to spell an envelope became that
// type. Since wire format v2 a Map is a dict, full stop, so a host that means
// "dataclass" says so with the type. That is a BREAKING change for consumers
// returning hand-built envelopes from an OS-call or external function.
MontyDataclass _userDataclass({
  required String name,
  required int age,
  bool frozen = false,
}) => MontyDataclass(
  name: 'User',
  typeId: 1,
  fieldNames: const ['name', 'age'],
  attrs: {'name': MontyString(name), 'age': MontyInt(age)},
  frozen: frozen,
);

MontyDataclass _orderDataclass({required int id, required double total}) =>
    MontyDataclass(
      name: 'Order',
      typeId: 2,
      fieldNames: const ['id', 'total'],
      attrs: {'id': MontyInt(id), 'total': MontyFloat(total)},
    );

void runDataclassHydrateTests() {
  group('MontyDataclass hydration via external function', () {
    test(
      'Python returns a dataclass; Dart hydrates into a user class',
      () async {
        final r = await Monty('make_user("alice", 30)').run(
          externalFunctions: {
            'make_user': (args, _) async => _userDataclass(
              name: args[0]! as String,
              age: args[1]! as int,
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
            'make_user': (_, _) async => _userDataclass(name: 'eve', age: 9),
            'make_order': (_, _) async => _orderDataclass(id: 99, total: 12.5),
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

    // M1 ISOLATION TEST — written BEFORE the fix, and it is EXPECTED TO FAIL
    // until native/src/convert.rs stops hardcoding class identity.
    //
    // THE DEFECT. convert.rs:536 builds every host dataclass with
    //     id: MontyUuid::from_random_bytes([1u8; 16])
    // and :544 gives every instance
    //     instance_id: MontyUuid::from_random_bytes([0u8; 16])
    // so the `typeId` Dart computes (1 for User, 2 for Order above) is
    // DISCARDED at the boundary. Upstream keeps "one type object per class id"
    // (monty crates/monty-types/src/object.rs:781-784), so two host classes
    // sharing an id ARE one class inside the sandbox.
    //
    // WHY THIS TEST AND NOT dataclass__basic.py. That fixture fails on
    // `assert point != mut_point` (line 41), which is CONSISTENT with the
    // collision but does not isolate it — a dozen other faults produce the same
    // assertion failure. This drives the two classes directly and asks Python
    // the one question that distinguishes them.
    //
    // CONTROL, measured 2026-09-14 against pydantic-monty 0.0.23 — the SAME
    // version this crate pins — with two different host dataclasses:
    //     type(a) is type(b) = False      <- identity PRESERVED
    //     type(a) = <class 'Point'>  type(b) = <class 'MutablePoint'>
    //     a != b  = True
    // So the behaviour asserted below is what a correct implementation does.
    // It is not aspirational.
    test(
      'two host classes with distinct typeIds stay distinct in-sandbox',
      () async {
        final r =
            await Monty('''
u = make_user()
o = make_order()
(type(u) is type(o), type(u).__name__, type(o).__name__)
''').run(
              externalFunctions: {
                // Future.value, not `async =>`: MontyCallback's return type is
                // already Future<Object?>, so the Future is REQUIRED by the
                // signature and an async body just makes DCM's
                // avoid-unnecessary-futures fire on a false positive.
                'make_user': (_, _) =>
                    Future.value(_userDataclass(name: 'eve', age: 9)),
                'make_order': (_, _) =>
                    Future.value(_orderDataclass(id: 99, total: 12.5)),
              },
            );

        expect(r.error, isNull, reason: 'the script itself must run');

        final got = r.value;
        expect(got, isA<MontyTuple>(), reason: 'expected a 3-tuple, got $got');
        // Destructured, not indexed: [] on a List is an unchecked throw,
        // and the pattern states the arity the assertions rely on.
        final [sameType, nameA, nameB] = (got as MontyTuple).items;

        // THE assertion. `User` and `Order` are different Dart types with
        // different typeIds; if the sandbox says they are the same type, the
        // identity was destroyed in transit.
        expect(
          (sameType as MontyBool).value,
          isFalse,
          reason:
              'type(User) is type(Order) came back TRUE — two distinct '
              'host classes collapsed to one class in-sandbox. That is '
              'convert.rs discarding the Dart typeId and substituting a '
              'constant uuid. Fix the encoder, do not relax this test.',
        );
        expect((nameA as MontyString).value, 'User');
        expect((nameB as MontyString).value, 'Order');
      },
    );

    test(
      'frozen flag and field_names round-trip through MontyDataclass',
      () async {
        final r = await Monty('make_user("frank", 20)').run(
          externalFunctions: {
            // Was a map spread overriding 'frozen'. A typed value takes the
            // flag as a named argument, which is also how a consumer would now
            // have to write it.
            'make_user': (args, _) async => _userDataclass(
              name: args[0]! as String,
              age: args[1]! as int,
              frozen: true,
            ),
          },
        );

        final dc = r.value as MontyDataclass;
        expect(dc.frozen, true);
        expect(dc.fieldNames, ['name', 'age']);
      },
    );
  });
}
