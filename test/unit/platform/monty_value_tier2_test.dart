// Unit tests for the value variants Tiers 1 and 2 added: mixed-key dicts,
// MontyBigInt, MontyExceptionValue and MontyStdTypeProxy.
//
// Written because the patch-coverage gate reported them at 9.5%-67.7%. They
// are new PUBLIC API — four sealed variants consumers must now match on — and
// nothing exercised their equality, hashing, rendering or error paths.
// The integration suites construct them, which is not the same as checking
// them.
//
// Pure value-level tests: no interpreter, no FFI, no WASM.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show MontyValueInternal, montyStdTypeProxy;
import 'package:test/test.dart';

void main() {
  group('MontyBigInt', () {
    final big = BigInt.parse('9223372036854775808'); // 2^63, one past i64

    test('carries the digits as text on the wire', () {
      expect(MontyBigInt(big).toJson(), {
        '__type': 'bigint',
        'value': '9223372036854775808',
      });
    });

    test('equality, hashCode and dartValue', () {
      final a = MontyBigInt(big);
      final b = MontyBigInt(big);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(MontyBigInt(big + BigInt.one)));
      expect(a.dartValue, big);
      expect(a.toString(), contains('9223372036854775808'));
    });
  });

  group('MontyExceptionValue', () {
    test('projects with and without a message', () {
      expect(MontyExceptionValue('ValueError', 'expected: got 3').toJson(), {
        '__type': 'exception',
        'exc_type': 'ValueError',
        'message': 'expected: got 3',
      });
      expect(MontyExceptionValue('RuntimeError').message, isNull);
    });

    test('is distinguishable from the string that used to represent it', () {
      final exc = MontyExceptionValue('ValueError', 'boom');
      const str = MontyString('ValueError: boom');
      expect(exc.toJson(), isNot(str.toJson()));
      expect(exc, isNot(str));
    });

    test('equality, hashCode, dartValue and toString', () {
      final a = MontyExceptionValue('KeyError', 'k');
      final b = MontyExceptionValue('KeyError', 'k');
      final c = MontyExceptionValue('KeyError');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a.dartValue, a.toJson());
      expect(a.toString(), 'MontyExceptionValue(KeyError: k)');
      expect(c.toString(), 'MontyExceptionValue(KeyError)');
    });

    test('attributes default to empty', () {
      expect(MontyExceptionValue('ValueError', 'm').attributes, isEmpty);
    });

    test('attributes are an unmodifiable copy', () {
      final source = <String, MontyValue>{'pos': const MontyInt(3)};
      final e = MontyExceptionValue('json.JSONDecodeError', 'm', source);
      source['pos'] = const MontyInt(4);
      source['extra'] = const MontyString('x');
      expect(e.attributes, {'pos': const MontyInt(3)});
      expect(
        () => e.attributes['pos'] = const MontyInt(5),
        throwsUnsupportedError,
      );
    });

    test('a container attribute is an ArgumentError', () {
      for (final bad in <MontyValue>[
        const MontyList([MontyInt(1)]),
        const MontyDict([]),
        const MontyNone(),
        const MontyFloat(1.5),
      ]) {
        expect(
          () => MontyExceptionValue('ValueError', 'm', {'a': bad}),
          throwsArgumentError,
          reason: 'accepted $bad',
        );
      }
      for (final leaf in <MontyValue>[
        const MontyString('s'),
        const MontyBytes([1]),
        const MontyInt(1),
        MontyBigInt(BigInt.two.pow(70)),
      ]) {
        expect(
          MontyExceptionValue('ValueError', 'm', {'a': leaf}).attributes,
          {'a': leaf},
        );
      }
    });

    test('attributes take part in == and hashCode', () {
      MontyExceptionValue at(int pos) => MontyExceptionValue(
        'json.JSONDecodeError',
        'm',
        {'pos': MontyInt(pos), 'msg': const MontyString('m')},
      );
      final one = at(1);
      final again = at(1);
      expect(one, again);
      expect(one.hashCode, again.hashCode);
      expect(one, isNot(at(2)));
      expect(one, isNot(MontyExceptionValue('json.JSONDecodeError', 'm')));
      // Order of the attributes does not matter.
      final reordered = MontyExceptionValue('json.JSONDecodeError', 'm', const {
        'msg': MontyString('m'),
        'pos': MontyInt(1),
      });
      expect(reordered, one);
      expect(reordered.hashCode, one.hashCode);
    });
  });

  group('MontyStdTypeProxy', () {
    test('a builtin carries the PYTHON name, not a Rust identifier', () {
      // `abs` used to arrive as "Abs" — Rust's Debug rendering of an internal
      // enum.
      final b = montyStdTypeProxy('function', 'abs');
      expect(b.kind, 'function');
      expect(b.name, 'abs');
      expect(b.dartValue, 'abs');
      expect(b.toJson(), {
        '__type': 'std_type_proxy',
        'kind': 'function',
        'name': 'abs',
      });
    });

    test("renders as upstream's repr", () {
      expect(
        montyStdTypeProxy('function', 'open').toString(),
        "MontyStdTypeProxy(kind='function', name='open')",
      );
      expect(
        montyStdTypeProxy('type', 'functools.partial').toString(),
        "MontyStdTypeProxy(kind='type', name='functools.partial')",
      );
    });

    test('kind participates in equality; the hash is the name only', () {
      final asType = montyStdTypeProxy('type', 'type');
      final asFunction = montyStdTypeProxy('function', 'type');
      expect(asType, isNot(asFunction));
      expect(asType, montyStdTypeProxy('type', 'type'));
      expect(asType.hashCode, asFunction.hashCode);
      expect(asType.hashCode, 'type'.hashCode);
      expect(
        montyStdTypeProxy('type', 'int').hashCode,
        isNot(montyStdTypeProxy('type', 'str').hashCode),
      );
    });
  });

  group('MontyDict with non-string keys', () {
    const pairs = MontyDict([
      (MontyInt(1), MontyString('a')),
      (MontyString('k'), MontyInt(2)),
    ]);

    test('travels under the dict tag with an entries payload', () {
      expect(pairs.toJson(), {
        '__type': 'dict',
        'entries': [
          [1, 'a'],
          ['k', 2],
        ],
      });
    });

    test('preserves insertion order in pairs, but NOT in equality', () {
      // INVERTED, deliberately. This test used to assert
      // `expect(pairs, isNot(reversed))` — order was part of equality for a
      // non-string-keyed dict but not for a string-keyed one, so the same
      // Python dict compared differently depending on its keys. The sandbox
      // answers True for both, so order-insensitive is the correct semantics
      // and the old assertion was pinning a defect.
      const reversed = MontyDict([
        (MontyString('k'), MontyInt(2)),
        (MontyInt(1), MontyString('a')),
      ]);

      // The DATA keeps Python's insertion order...
      expect(pairs.pairs.map((p) => p.$1).toList(), [
        const MontyInt(1),
        const MontyString('k'),
      ]);
      expect(reversed.pairs.map((p) => p.$1).toList(), [
        const MontyString('k'),
        const MontyInt(1),
      ]);

      // ...while EQUALITY ignores it.
      expect(pairs, reversed);
      expect(pairs.hashCode, reversed.hashCode);
    });

    test('dartValue is a list of pairs when a key is not a string', () {
      // Deliberately not a Map here -- see the dartValue doc comment.
      expect(pairs.dartValue, [
        [1, 'a'],
        ['k', 2],
      ]);
    });

    test('equality, hashCode and toString', () {
      expect(
        pairs,
        const MontyDict([
          (MontyInt(1), MontyString('a')),
          (MontyString('k'), MontyInt(2)),
        ]),
      );
      expect(pairs.toString(), 'MontyDict(2 entries)');
      expect(const MontyDict([]).toString(), 'MontyDict(0 entries)');
    });

    test('a different length is never equal', () {
      // Guards the length short-circuit: a subset must not compare equal.
      const shorter = MontyDict([(MontyInt(1), MontyString('a'))]);
      expect(pairs, isNot(shorter));
      expect(shorter, isNot(pairs));
    });
  });
}
