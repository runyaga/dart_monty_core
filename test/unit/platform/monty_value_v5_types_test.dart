// Unit tests for the three wire-v5 value types that had NO unit test at all:
// MontyNotImplemented, MontyClassType and MontyClassInstance.
//
// Found by listing every class in monty_value_structured.dart and grepping
// test/unit/ for each name: these three returned zero files. They are the
// NEWEST public types in the package — the ones wire v5 introduced — and they
// were the only ones nothing checked. The integration suites construct
// MontyClassInstance, which is not the same as checking its equality, its
// hashing, or what it does with a malformed envelope.
//
// MontyClassType is the sharper case: it is NOT a MontyValue (no extends
// clause), so it is invisible to every test that walks the MontyValue
// hierarchy. It can only be reached deliberately.
//
// Pure value-level tests: no interpreter, no FFI, no WASM.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// The envelope a real engine emits, taken from an observed v0.0.23 run rather
/// than invented: `class C: pass` then `C()` on the FFI backend.
Map<String, dynamic> _instanceEnvelope({
  String name = 'User',
  String classId = 'eeee1f5d-3dad-4e69-a00c-2ad1e3258621',
  String instanceId = '14abf845-dc0c-49cd-bfd3-9acd25082227',
  bool isDataclass = true,
  Map<String, dynamic>? attrs,
}) => {
  '__type': 'class_instance',
  'class_type': {
    'name': name,
    'id': classId,
    'host_defined': false,
    'is_dataclass': isDataclass,
    'attrs': {'__type': 'dict', 'value': <String, dynamic>{}},
  },
  'instance_id': instanceId,
  'attrs': {
    '__type': 'dict',
    'value': attrs ?? {'name': 'Alice', 'age': 30},
  },
};

void main() {
  group('MontyNotImplemented', () {
    test('round-trips through fromJson(toJson())', () {
      const v = MontyNotImplemented();
      expect(v.toJson(), {'__type': 'not_implemented'});
      expect(MontyValue.fromJson(v.toJson()), v);
    });

    test('a decoded instance equals a constructed one', () {
      // Deliberately NOT `const X() == const X()`. Dart canonicalises equal
      // const literals to a single instance, so that compares an object with
      // ITSELF and would pass even with a broken ==. Build one through the
      // decoder and one through the constructor — genuinely separate paths.
      final decoded = MontyValue.fromJson({'__type': 'not_implemented'});
      const constructed = MontyNotImplemented();
      expect(decoded, constructed);
      expect(decoded.hashCode, constructed.hashCode);
    });

    test('dartValue returns the value itself, not null', () {
      // The distinction matters: NotImplemented is a REAL Python value, and
      // collapsing it to null would make it indistinguishable from None at the
      // call site.
      const v = MontyNotImplemented();
      expect(v.dartValue, same(v));
      expect(v.dartValue, isNot(isNull));
    });

    test('is not equal to MontyNone', () {
      expect(const MontyNotImplemented(), isNot(const MontyNone()));
    });

    test('renders as its type name', () {
      expect(const MontyNotImplemented().toString(), 'MontyNotImplemented()');
    });
  });

  group('MontyClassType', () {
    const base = MontyClassType(
      name: 'User',
      id: 'id-1',
      hostDefined: false,
      isDataclass: true,
      attrs: {},
    );

    test('equality is structural across every field', () {
      expect(
        base,
        const MontyClassType(
          name: 'User',
          id: 'id-1',
          hostDefined: false,
          isDataclass: true,
          attrs: {},
        ),
      );
    });

    test('differing in ANY single field breaks equality', () {
      // One case per field. A == that forgot a field would pass the happy-path
      // test above and fail exactly here.
      expect(
        base,
        isNot(
          const MontyClassType(
            name: 'Other',
            id: 'id-1',
            hostDefined: false,
            isDataclass: true,
            attrs: {},
          ),
        ),
      );
      expect(
        base,
        isNot(
          const MontyClassType(
            name: 'User',
            id: 'id-2',
            hostDefined: false,
            isDataclass: true,
            attrs: {},
          ),
        ),
      );
      expect(
        base,
        isNot(
          const MontyClassType(
            name: 'User',
            id: 'id-1',
            hostDefined: true,
            isDataclass: true,
            attrs: {},
          ),
        ),
      );
      expect(
        base,
        isNot(
          const MontyClassType(
            name: 'User',
            id: 'id-1',
            hostDefined: false,
            isDataclass: false,
            attrs: {},
          ),
        ),
      );
      expect(
        base,
        isNot(
          const MontyClassType(
            name: 'User',
            id: 'id-1',
            hostDefined: false,
            isDataclass: true,
            attrs: {'x': MontyInt(1)},
          ),
        ),
      );
    });

    test('attrs equality is DEEP, not identity', () {
      // The two maps are built SEPARATELY and deliberately not const. Dart
      // canonicalises equal const literals to one instance, so a const map
      // here would make `identical` below TRUE and the test would pass for the
      // opposite of the reason it exists. Hoisting them out of the constructor
      // also keeps the analyzer's const lints off a place where const is wrong.
      final attrsA = <String, MontyValue>{'x': const MontyInt(1)};
      final attrsB = <String, MontyValue>{'x': const MontyInt(1)};
      final a = MontyClassType(
        name: 'C',
        id: 'i',
        hostDefined: false,
        isDataclass: false,
        attrs: attrsA,
      );
      final b = MontyClassType(
        name: 'C',
        id: 'i',
        hostDefined: false,
        isDataclass: false,
        attrs: attrsB,
      );
      expect(identical(a.attrs, b.attrs), isFalse, reason: 'distinct maps');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('toString names the class, its id and the dataclass flag', () {
      expect(
        base.toString(),
        'MontyClassType(User, id: id-1, isDataclass: true)',
      );
    });
  });

  group('MontyClassInstance', () {
    test('decodes the envelope a real engine emits', () {
      final v = MontyValue.fromJson(_instanceEnvelope()) as MontyClassInstance;
      expect(v.classType.name, 'User');
      expect(v.classType.isDataclass, isTrue);
      expect(v.classType.hostDefined, isFalse);
      expect(v.instanceId, '14abf845-dc0c-49cd-bfd3-9acd25082227');
      expect((v.attrs['name']! as MontyString).value, 'Alice');
      expect((v.attrs['age']! as MontyInt).value, 30);
    });

    test('equality is structural, and instanceId participates', () {
      final envelope = _instanceEnvelope();
      final a = MontyValue.fromJson(envelope);
      final b = MontyValue.fromJson(envelope);
      expect(a, b);
      expect(a.hashCode, b.hashCode);

      final other = MontyValue.fromJson(
        _instanceEnvelope(instanceId: 'a-different-instance'),
      );
      expect(
        a,
        isNot(other),
        reason: 'two instances of one class are distinct',
      );
    });

    test('a non-object class_type is a FormatException, not a crash', () {
      final bad = _instanceEnvelope()..['class_type'] = 'not-an-object';
      expect(
        () => MontyValue.fromJson(bad),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('class_type must be an object'),
          ),
        ),
      );
    });

    test('a non-string class_type.name is a FormatException naming it', () {
      final bad = _instanceEnvelope();
      final ct = bad['class_type']! as Map<String, dynamic>;
      ct['name'] = 42;
      expect(
        () => MontyValue.fromJson(bad),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('class_type.name'),
          ),
        ),
      );
    });

    test('a non-string class_type.id is a FormatException naming it', () {
      final bad = _instanceEnvelope();
      final ct = bad['class_type']! as Map<String, dynamic>;
      ct['id'] = <String, dynamic>{};
      expect(
        () => MontyValue.fromJson(bad),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('class_type.id'),
          ),
        ),
      );
    });

    test('a non-bool is_dataclass throws; an absent one defaults false', () {
      final bad = _instanceEnvelope();
      final badCt = bad['class_type']! as Map<String, dynamic>;
      badCt['is_dataclass'] = 'yes';
      expect(() => MontyValue.fromJson(bad), throwsA(isA<FormatException>()));

      final absent = _instanceEnvelope();
      (absent['class_type']! as Map<String, dynamic>).remove('is_dataclass');
      final v = MontyValue.fromJson(absent) as MontyClassInstance;
      expect(v.classType.isDataclass, isFalse, reason: 'absent means false');
    });
  });
}
