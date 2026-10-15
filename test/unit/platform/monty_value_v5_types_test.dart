// Unit tests for the three wire-v5 value types that had NO unit test at all:
// MontyNotImplemented, MontyClassTypeProxy and MontyClassProxy.
//
// Found by listing every class in monty_value_structured.dart and grepping
// test/unit/ for each name: these three returned zero files. They are the
// NEWEST public types in the package — the ones wire v5 introduced — and they
// were the only ones nothing checked. The integration suites construct
// MontyClassProxy, which is not the same as checking its equality or its
// hashing.
//
// MontyClassTypeProxy is the sharper case: it is NOT a MontyValue (no extends
// clause), so it is invisible to every test that walks the MontyValue
// hierarchy. It can only be reached deliberately.
//
// Pure value-level tests: no interpreter, no FFI, no WASM.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show
        MontyClassProxyInternal,
        MontyValueInternal,
        montyClassProxy,
        montyClassTypeProxy;
import 'package:test/test.dart';

/// An instance as a real engine decodes `class C: pass` then `C()`.
MontyClassProxy _instance({String instanceId = 'i-1'}) => montyClassProxy(
  classType: montyClassTypeProxy(
    name: 'User',
    id: 'eeee1f5d-3dad-4e69-a00c-2ad1e3258621',
    hostDefined: false,
    isDataclass: true,
    attrs: const {},
  ),
  instanceId: instanceId,
  attrs: const {'name': MontyString('Alice'), 'age': MontyInt(30)},
);

void main() {
  group('MontyNotImplemented', () {
    test('projects to its tagged map', () {
      const v = MontyNotImplemented();
      expect(v.toJson(), {'__type': 'not_implemented'});
    });

    test('a separately built instance equals a const one', () {
      // Deliberately NOT `const X() == const X()`. Dart canonicalises equal
      // const literals to a single instance, so that compares an object with
      // ITSELF and would pass even with a broken ==.
      // ignore: prefer_const_constructors
      final decoded = MontyNotImplemented();
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

  group('MontyClassTypeProxy', () {
    final base = montyClassTypeProxy(
      name: 'User',
      id: 'id-1',
      hostDefined: false,
      isDataclass: true,
      attrs: const {},
    );

    test('equality is structural across every field', () {
      expect(
        base,
        montyClassTypeProxy(
          name: 'User',
          id: 'id-1',
          hostDefined: false,
          isDataclass: true,
          attrs: const {},
        ),
      );
    });

    test('differing in ANY single field breaks equality', () {
      // One case per field. A == that forgot a field would pass the happy-path
      // test above and fail exactly here.
      expect(
        base,
        isNot(
          montyClassTypeProxy(
            name: 'Other',
            id: 'id-1',
            hostDefined: false,
            isDataclass: true,
            attrs: const {},
          ),
        ),
      );
      expect(
        base,
        isNot(
          montyClassTypeProxy(
            name: 'User',
            id: 'id-2',
            hostDefined: false,
            isDataclass: true,
            attrs: const {},
          ),
        ),
      );
      expect(
        base,
        isNot(
          montyClassTypeProxy(
            name: 'User',
            id: 'id-1',
            hostDefined: true,
            isDataclass: true,
            attrs: const {},
          ),
        ),
      );
      expect(
        base,
        isNot(
          montyClassTypeProxy(
            name: 'User',
            id: 'id-1',
            hostDefined: false,
            isDataclass: false,
            attrs: const {},
          ),
        ),
      );
      expect(
        base,
        isNot(
          montyClassTypeProxy(
            name: 'User',
            id: 'id-1',
            hostDefined: false,
            isDataclass: true,
            attrs: const {'x': MontyInt(1)},
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
      final a = montyClassTypeProxy(
        name: 'C',
        id: 'i',
        hostDefined: false,
        isDataclass: false,
        attrs: attrsA,
      );
      final b = montyClassTypeProxy(
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
        'MontyClassTypeProxy(User, id: id-1, isDataclass: true)',
      );
    });
  });

  group('MontyClassProxy', () {
    test('equality is structural, and instanceId participates', () {
      final a = _instance();
      final b = _instance();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(_instance(instanceId: 'a-different-instance')),
        reason: 'two instances of one class are distinct',
      );
    });

    test('class metadata is read through classType', () {
      final v = _instance();
      expect(v.classType.name, 'User');
      expect(v.classType.isDataclass, isTrue);
      expect(v.toString(), 'MontyClassProxy(User, 2 attrs)');
    });

    test('dartAttrs projects the attributes to Dart values', () {
      expect(_instance().dartAttrs, {'name': 'Alice', 'age': 30});
    });
  });
}
