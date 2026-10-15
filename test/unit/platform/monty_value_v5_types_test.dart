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

    MontyClassTypeProxy variant({
      String name = 'User',
      String id = 'id-1',
      bool hostDefined = false,
      bool isDataclass = true,
      Map<String, MontyValue> attrs = const {},
    }) => montyClassTypeProxy(
      name: name,
      id: id,
      hostDefined: hostDefined,
      isDataclass: isDataclass,
      attrs: attrs,
    );

    test('equality is by class id alone, as upstream (one type per id)', () {
      // class_instance.rs:314-319: __eq__ compares class_type.id only.
      for (final other in [
        variant(name: 'Other'),
        variant(hostDefined: true),
        variant(isDataclass: false),
        variant(attrs: const {'x': MontyInt(1)}),
        variant(id: 'ID-1'),
      ]) {
        expect(base, other);
        expect(other, base);
        expect(base.hashCode, other.hashCode);
      }
      expect(base, isNot(variant(id: 'id-2')));
    });

    test('is a value: a class type proxy is a MontyValue', () {
      const id = _identity;
      expect(id(base), same(base));
      expect(base.dartValue, {
        '__type': 'class_type',
        'name': 'User',
        'id': 'id-1',
        'host_defined': false,
        'is_dataclass': true,
        'attrs': {'__type': 'dict', 'value': <String, Object?>{}},
      });
    });

    test('toString names the class and counts its attributes', () {
      expect(base.toString(), 'MontyClassTypeProxy(User, 0 attrs)');
    });
  });

  group('MontyClassProxy', () {
    test('equality is by class name, dataclass flag and attributes', () {
      // class_instance.rs:255-263: the instance id is not compared.
      final a = _instance();
      final b = _instance();
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      final other = _instance(instanceId: 'a-different-instance');
      expect(a, other);
      expect(a.hashCode, other.hashCode);
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

MontyValue _identity(MontyValue v) => v;
