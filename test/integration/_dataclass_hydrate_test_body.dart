// Shared test body for ffi_dataclass_hydrate_test.dart and
// wasm_dataclass_hydrate_test.dart.
//
// Validates the end-to-end Python → Dart dataclass hydration path: an
// external function returns a dataclass JSON envelope, the engine round-
// trips it through Python, and Dart hydrates the returned MontyDataclass
// into a user class via MontyDataclass.hydrate.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';
import '../_accessors.dart';

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
  group('class-instance hydration via external function', () {
    test(
      'Python returns a dataclass; Dart hydrates into a user class',
      () async {
        final r = await Monty('make_user("alice", 30)').run(
          externalFunctions: {
            'make_user': (args, _) => _userDataclass(
              name: callbackArg(args, 0),
              age: callbackArg(args, 1),
            ),
          },
        );

        expect(r.error, isNull);
        // A MontyClassInstance, NOT a MontyDataclass. The host still SENDS a
        // MontyDataclass (that envelope is still accepted inbound), but monty
        // v0.0.23 replaced the wire Dataclass variant with ClassInstance
        // (upstream cf8246d7), so what comes BACK is a class instance. This
        // is the D2 break, asserted rather than hidden.
        expect(r.value, isA<MontyClassInstance>());

        final dc = r.value as MontyClassInstance;
        expect(dc.name, 'User');
        expect(dc.isDataclass, isTrue, reason: 'the CLASS carries the flag');
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
            'make_user': (_, _) => _userDataclass(name: 'eve', age: 9),
            'make_order': (_, _) => _orderDataclass(id: 99, total: 12.5),
          },
        );
        if (r.value is! MontyClassInstance) return r.value;
        final dc = r.value as MontyClassInstance;

        return factories[dc.name]?.call(dc.dartAttrs);
      }

      final user = await dispatchAndHydrate('make_user()');
      if (user is! _User) fail('expected a _User, got $user');
      expect(user.name, 'eve');

      final order = await dispatchAndHydrate('make_order()');
      if (order is! _Order) fail('expected an _Order, got $order');
      expect(order.total, 12.5);
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
                // These return the value directly. The Future.value wrappers
                // that stood here were a workaround for MontyCallback's old
                // `Future<Object?>` return type, which forced every callback
                // to be asynchronous whether or not it had anything to await.
                // The typedef is FutureOr<Object?> now, so a plain value is
                // allowed and the wrapper is noise. (codex caught this comment
                // still asserting "the Future is REQUIRED by the signature"
                // after the signature changed.)
                'make_user': (_, _) => _userDataclass(name: 'eve', age: 9),
                'make_order': (_, _) => _orderDataclass(id: 99, total: 12.5),
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

    test('frozen and field_names are DISCARDED at the boundary', () async {
      // THIS TEST USED TO ASSERT A ROUND TRIP, and it was unsatisfiable.
      //
      // monty v0.0.23 deleted the wire Dataclass variant that carried
      // `field_names` and `frozen` (upstream cf8246d7; the deleted variant is
      // visible at `git show cf8246d7^:crates/monty-types/src/object.rs`
      // lines 124-140). The replacement, MontyClassInstance, has three fields
      // and neither of those. Upstream says so twice:
      //   docs/limitations/classes.md:263-265 — "there is no frozen policy on
      //     the wire";
      //   docs/limitations/classes.md:266 — dataclasses.fields() does not work
      //     on host instances.
      // Measured on pydantic-monty 0.0.23, the shipped artifact: a frozen and
      // a non-frozen instance are WIRE-IDENTICAL, and in-sandbox
      // `from dataclasses import fields` raises ImportError — so nothing could
      // read field names even if they crossed.
      //
      // So this asserts the DISCARD. If upstream ever restores a frozen
      // policy, `frozen: true` will start surviving, this test will FAIL, and
      // the failure is the notification. A test asserting the old round trip
      // could only ever be red; a deleted test would say nothing at all.
      final r = await Monty('make_user("frank", 20)').run(
        externalFunctions: {
          'make_user': (args, _) => Future.value(
            _userDataclass(
              name: callbackArg(args, 0),
              age: callbackArg(args, 1),
              frozen: true,
            ),
          ),
        },
      );

      expect(r.error, isNull);
      final dc = r.value as MontyClassInstance;
      final classId = dc.classType.id;

      // What SURVIVES.
      expect(dc.name, 'User');
      expect(dc.dartAttrs, {'name': 'frank', 'age': 20});
      expect(dc.isDataclass, isTrue);
      expect(
        classId,
        isNotEmpty,
        reason:
            'class identity must survive; it is what keeps two host '
            'classes apart in-sandbox',
      );

      // What DOES NOT.
      //
      // AN EARLIER VERSION OF THIS ASSERTION WAS VACUOUS, and review caught
      // it. It checked `dc.toJson().keys` — but toJson() is OUR OWN hardcoded
      // four-key map, so it asserted that a literal we wrote contains the keys
      // we wrote into it. It would have passed no matter what the wire
      // carried. A test that cannot fail is not a test, and this file already
      // has one cautionary example of that (see the empty-attrs note in
      // native/src/convert.rs).
      //
      // These read values that came FROM THE ENGINE instead. `dartAttrs` is
      // decoded from the `attrs` envelope on the wire, so if frozen-ness or a
      // field list were still crossing, an attribute is where they would
      // land — their absence here is a fact about the PAYLOAD.
      expect(
        dc.dartAttrs.keys.toSet(),
        {'name', 'age'},
        reason:
            'the wire carried exactly the declared attrs — no frozen flag '
            'and no field-name list smuggled in alongside them',
      );
      expect(
        dc.dartAttrs.containsKey('frozen'),
        isFalse,
        reason: 'the host SET frozen: true and it did not come back',
      );
      expect(
        classId,
        isNotEmpty,
        reason: 'class identity is what DOES survive, and M1 depends on it',
      );
      // The type half: what returns is a class instance, not the dataclass
      // the host sent in. That IS the D2 break.
      expect(dc, isNot(isA<MontyDataclass>()));
    });
  });
}
