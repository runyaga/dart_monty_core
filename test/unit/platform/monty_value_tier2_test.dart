// Unit tests for the value variants Tiers 1 and 2 added: MontyPairsDict,
// MontyBigInt, MontyExceptionValue and MontyOpaque.
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
import 'package:test/test.dart';

/// Every variant must survive `fromJson(toJson())` unchanged.
void _expectRoundTrip(MontyValue v) {
  expect(MontyValue.fromJson(v.toJson()), v, reason: '$v did not round-trip');
}

void main() {
  group('MontyBigInt', () {
    final big = BigInt.parse('9223372036854775808'); // 2^63, one past i64

    test('round-trips with exact digits', () {
      _expectRoundTrip(MontyBigInt(big));
      _expectRoundTrip(MontyBigInt(-big));
      _expectRoundTrip(MontyBigInt(BigInt.parse('9' * 60)));
    });

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

    test('rejects a payload that is not base-10 digits', () {
      for (final bad in <Object?>['', 'nope', '1.5', 12, null]) {
        expect(
          () => MontyValue.fromJson({'__type': 'bigint', 'value': bad}),
          throwsA(isA<FormatException>()),
          reason: 'accepted $bad',
        );
      }
    });
  });

  group('MontyExceptionValue', () {
    test('round-trips with and without a message', () {
      _expectRoundTrip(
        const MontyExceptionValue(excType: 'ValueError', message: 'boom'),
      );
      _expectRoundTrip(const MontyExceptionValue(excType: 'RuntimeError'));
    });

    test('a message containing ": " survives', () {
      // The old joined form ("ValueError: boom") could not be taken apart again
      // when the message itself contained the separator.
      const e = MontyExceptionValue(
        excType: 'ValueError',
        message: 'expected: got 3',
      );
      final back = MontyValue.fromJson(e.toJson()) as MontyExceptionValue;
      expect(back.excType, 'ValueError');
      expect(back.message, 'expected: got 3');
    });

    test('is distinguishable from the string that used to represent it', () {
      const exc = MontyExceptionValue(excType: 'ValueError', message: 'boom');
      const str = MontyString('ValueError: boom');
      expect(exc.toJson(), isNot(str.toJson()));
      expect(exc, isNot(str));
    });

    test('equality, hashCode, dartValue and toString', () {
      const a = MontyExceptionValue(excType: 'KeyError', message: 'k');
      const b = MontyExceptionValue(excType: 'KeyError', message: 'k');
      const c = MontyExceptionValue(excType: 'KeyError');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
      expect(a.dartValue, a.toJson());
      expect(a.toString(), 'MontyExceptionValue(KeyError: k)');
      expect(c.toString(), 'MontyExceptionValue(KeyError)');
    });
  });

  group('MontyOpaque', () {
    test('every kind round-trips under its own wire tag', () {
      for (final kind in MontyOpaqueKind.values) {
        _expectRoundTrip(MontyOpaque(kind, 'text-for-${kind.name}'));
        expect(
          MontyOpaque(kind, 'x').toJson(),
          {'__type': kind.wireTag, 'text': 'x'},
          reason: '${kind.name} must travel as "${kind.wireTag}"',
        );
      }
    });

    test('the five wire tags are distinct', () {
      final tags = MontyOpaqueKind.values.map((k) => k.wireTag).toSet();
      expect(tags, hasLength(MontyOpaqueKind.values.length));
    });

    test('fromWireTag maps back, and refuses anything else', () {
      for (final kind in MontyOpaqueKind.values) {
        expect(MontyOpaqueKind.fromWireTag(kind.wireTag), kind);
      }
      expect(MontyOpaqueKind.fromWireTag('dict'), isNull);
      expect(MontyOpaqueKind.fromWireTag(''), isNull);
    });

    test('a builtin carries the PYTHON name, not a Rust identifier', () {
      // `abs` used to arrive as "Abs" — Rust's Debug rendering of an internal
      // enum. This is the shape that replaced it.
      const b = MontyOpaque(MontyOpaqueKind.builtin, 'abs');
      expect(b.toJson(), {'__type': 'builtin', 'text': 'abs'});
      expect(b.dartValue, 'abs');
    });

    test('kind participates in equality', () {
      const asType = MontyOpaque(MontyOpaqueKind.type, 'same');
      const asRepr = MontyOpaque(MontyOpaqueKind.repr, 'same');
      expect(asType, isNot(asRepr));
      expect(asType, const MontyOpaque(MontyOpaqueKind.type, 'same'));
      expect(asType.hashCode, isNot(asRepr.hashCode));
      expect(asType.toString(), 'MontyOpaque(type, same)');
    });
  });

  group('MontyPairsDict', () {
    const pairs = MontyPairsDict([
      (MontyInt(1), MontyString('a')),
      (MontyString('k'), MontyInt(2)),
    ]);

    test('round-trips with key TYPES intact', () {
      _expectRoundTrip(pairs);
      final back = MontyValue.fromJson(pairs.toJson()) as MontyPairsDict;
      expect(back.pairs.map((p) => p.$1), [
        const MontyInt(1),
        const MontyString('k'),
      ]);
    });

    test('travels under the dict tag with an entries payload', () {
      expect(pairs.toJson(), {
        '__type': 'dict',
        'entries': [
          [1, 'a'],
          ['k', 2],
        ],
      });
    });

    test('preserves insertion order, and order is part of equality', () {
      const reversed = MontyPairsDict([
        (MontyString('k'), MontyInt(2)),
        (MontyInt(1), MontyString('a')),
      ]);
      expect(pairs, isNot(reversed));
    });

    test('dartValue is a list of pairs, not a Map', () {
      // Deliberately not a Map: two distinct Python keys can share a Dart
      // toString, so collapsing them would silently drop entries.
      expect(pairs.dartValue, [
        [1, 'a'],
        ['k', 2],
      ]);
    });

    test('equality, hashCode and toString', () {
      expect(
        pairs,
        const MontyPairsDict([
          (MontyInt(1), MontyString('a')),
          (MontyString('k'), MontyInt(2)),
        ]),
      );
      expect(pairs.toString(), 'MontyPairsDict(2 pairs)');
      expect(const MontyPairsDict([]).toString(), 'MontyPairsDict(0 pairs)');
    });

    test('nested values decode recursively', () {
      const nested = MontyPairsDict([
        (MontyInt(1), MontyList([MontyInt(2), MontyString('x')])),
      ]);
      _expectRoundTrip(nested);
    });

    test('a malformed entry is rejected', () {
      for (final bad in <Object?>[
        [1],
        [1, 2, 3],
        'not-a-pair',
      ]) {
        expect(
          () => MontyValue.fromJson({
            '__type': 'dict',
            'entries': [bad],
          }),
          throwsA(isA<FormatException>()),
          reason: 'accepted $bad',
        );
      }
    });
  });

  group('MontyDict envelope', () {
    test('rejects a missing or non-object payload', () {
      for (final bad in <Object?>[null, 'x', 3]) {
        expect(
          () => MontyValue.fromJson({'__type': 'dict', 'value': bad}),
          throwsA(isA<FormatException>()),
          reason: 'accepted $bad',
        );
      }
    });
  });
}
