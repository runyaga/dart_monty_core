// Spec-requirement tests for the scalar members of the MontyValue family
// (T-values). Each test name starts with the REQ id it asserts, so a mutant
// run can select one row with `-N "REQ-...:"`.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show MontyValueInternal;
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:test/test.dart';

/// True where an integral double is also an `int` (dart2js).
const bool _isJs = identical(0, 0.0);

/// One instance of every other family member, for exclusion checks.
List<MontyValue> _others() => [
  const MontyNone(),
  const MontyBool(false),
  const MontyInt(0),
  MontyBigInt(BigInt.zero),
  const MontyFloat(0),
  const MontyComplex(0, 0),
  const MontyString(''),
  const MontyBytes([]),
  const MontyList([]),
  const MontyTuple([]),
  const MontyDict([]),
  const MontySet([]),
  const MontyFrozenSet([]),
  const MontyDate(year: 1, month: 1, day: 1),
  const MontyDateTime(
    year: 1,
    month: 1,
    day: 1,
    hour: 0,
    minute: 0,
    second: 0,
  ),
  const MontyTimeDelta(days: 0, seconds: 0),
  const MontyTimeZone(offsetSeconds: 0),
  const MontyTime(hour: 0, minute: 0, second: 0, microsecond: 0),
  MontyPath('/a'),
  MontyFileHandle('/a', 'r'),
  const MontyNamedTuple(typeName: 'T', fieldNames: [], values: []),
  const MontyNotImplemented(),
  MontyExceptionValue('E'),
  const MontyEllipsis(),
];

void main() {
  group('fromDart returns an existing value unchanged', () {
    test('REQ-MontyBigInt-15: MontyBigInt', () {
      final v = MontyBigInt(BigInt.one << 80);
      expect(identical(MontyValue.fromDart(v), v), isTrue);
    });
    test('REQ-MontyEllipsis-12: MontyEllipsis', () {
      const v = MontyEllipsis();
      expect(identical(MontyValue.fromDart(v), v), isTrue);
      expect(MontyValue.fromDart(v), isA<MontyEllipsis>());
    });
    test('REQ-MontyExceptionValue-23: MontyExceptionValue', () {
      final v = MontyExceptionValue('ValueError', 'bad', const {
        'k': MontyInt(1),
      });
      expect(identical(MontyValue.fromDart(v), v), isTrue);
    });
    test('REQ-MontyNotImplemented-9: MontyNotImplemented', () {
      const v = MontyNotImplemented();
      expect(identical(MontyValue.fromDart(v), v), isTrue);
    });
    test('REQ-MontyPath-13: MontyPath', () {
      final v = MontyPath('/a/b');
      expect(identical(MontyValue.fromDart(v), v), isTrue);
    });
    test('REQ-MontyValue-34: raw BigInt is refused, MontyBigInt is not', () {
      expect(() => MontyValue.fromDart(BigInt.one), throwsArgumentError);
      expect(() => MontyValue.fromDart(BigInt.one << 70), throwsArgumentError);
      expect(
        () => MontyValue.fromDart([BigInt.one]),
        throwsArgumentError,
      );
      expect(MontyValue.fromDart(MontyBigInt(BigInt.one)), isA<MontyBigInt>());
    });
    test('REQ-MontyBigInt-22: a raw BigInt throws ArgumentError', () {
      expect(
        () => MontyValue.fromDart(BigInt.parse('123456789012345678901234567')),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => MontyValue.fromDart({'k': BigInt.zero}),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('toString', () {
    test('REQ-MontyBool-11: MontyBool(<value>)', () {
      expect(const MontyBool(true).toString(), 'MontyBool(true)');
      expect(const MontyBool(false).toString(), 'MontyBool(false)');
    });
    test('REQ-MontyInt-17: MontyInt(<value>)', () {
      expect(const MontyInt(42).toString(), 'MontyInt(42)');
      expect(const MontyInt(-7).toString(), 'MontyInt(-7)');
      expect(const MontyInt(0).toString(), 'MontyInt(0)');
    });
    test('REQ-MontyBigInt-16: MontyBigInt(<value>)', () {
      final big = BigInt.parse('123456789012345678901234567890');
      expect(MontyBigInt(big).toString(), 'MontyBigInt($big)');
      expect(
        MontyBigInt(big).toString(),
        'MontyBigInt(123456789012345678901234567890)',
      );
      expect(MontyBigInt(-big).toString(), startsWith('MontyBigInt(-1234'));
      expect(MontyBigInt(-big).toString(), endsWith('890)'));
    });
    test('REQ-MontyFloat-22: MontyFloat( + interpolated double + )', () {
      expect(const MontyFloat(1.5).toString(), 'MontyFloat(1.5)');
      expect(const MontyFloat(-2.25).toString(), 'MontyFloat(-2.25)');
      // Runtime doubles: dart2js folds `'${-0.0}'` of a literal differently.
      final four = double.parse('4.0');
      final negZero = double.parse('-0.0');
      final huge = double.parse('1e21');
      expect(MontyFloat(four).toString(), 'MontyFloat($four)');
      expect(MontyFloat(negZero).toString(), 'MontyFloat($negZero)');
      expect(MontyFloat(huge).toString(), 'MontyFloat($huge)');
      expect(
        const MontyFloat(double.nan).toString(),
        'MontyFloat(NaN)',
      );
      expect(
        const MontyFloat(double.negativeInfinity).toString(),
        'MontyFloat(-Infinity)',
      );
    });
    test('REQ-MontyString-16: MontyString( + text + )', () {
      expect(const MontyString('hi').toString(), 'MontyString(hi)');
      expect(const MontyString('').toString(), 'MontyString()');
      expect(const MontyString('a b)').toString(), 'MontyString(a b))');
    });
  });

  group('equality and hashing', () {
    test('REQ-MontyNone-6: equal exactly to another MontyNone', () {
      const none = MontyNone();
      expect(none == const MontyNone(), isTrue);
      expect(none == (null as Object?), isFalse);
      expect(none == const MontyBool(false), isFalse);
      expect(none == const MontyInt(0), isFalse);
      expect(none == const MontyFloat(0), isFalse);
      expect(none == MontyBigInt(BigInt.zero), isFalse);
      expect(none == const MontyString(''), isFalse);
      expect(none == (0 as Object), isFalse);
      expect(none == (false as Object), isFalse);
      for (final other in _others()) {
        if (other is MontyNone) continue;
        expect(none == other, isFalse, reason: '$other');
        expect(other == none, isFalse, reason: '$other');
      }
    });
    test('REQ-MontyNone-7: hashCode equals null.hashCode', () {
      expect(const MontyNone().hashCode, null.hashCode);
      expect(MontyValue.fromDart(null).hashCode, null.hashCode);
    });
    test('REQ-MontyString-6: hashCode is the stored string hashCode', () {
      for (final s in ['', 'a', 'hello world', 'é\u{1F600}']) {
        expect(MontyString(s).hashCode, s.hashCode);
      }
    });
    test('REQ-MontyEllipsis-5: equal to every ellipsis, unequal to others', () {
      expect(const MontyEllipsis() == const MontyEllipsis(), isTrue);
      // Distinct, non-canonical instances.
      final a = (() => const MontyEllipsis())();
      final b = MontyValue.fromDart(const MontyEllipsis());
      expect(a == b, isTrue);
      for (final other in _others()) {
        if (other is MontyEllipsis) continue;
        expect(a == other, isFalse, reason: '$other');
        expect(other == a, isFalse, reason: '$other');
      }
      expect(a == (null as Object?), isFalse);
      expect(a == ('...' as Object), isFalse);
    });
    test('REQ-MontyEllipsis-6: hashCode is the type object hashCode', () {
      expect(const MontyEllipsis().hashCode, (MontyEllipsis).hashCode);
      expect(
        MontyValue.fromDart(const MontyEllipsis()).hashCode,
        (MontyEllipsis).hashCode,
      );
    });
  });

  group('MontyFloat', () {
    test('REQ-MontyFloat-3: stores specials; dartValue returns the double', () {
      expect(const MontyFloat(double.nan).value.isNaN, isTrue);
      expect(const MontyFloat(double.nan).dartValue.isNaN, isTrue);
      expect(const MontyFloat(double.infinity).dartValue, double.infinity);
      expect(
        const MontyFloat(double.negativeInfinity).dartValue,
        double.negativeInfinity,
      );
      final negZero = const MontyFloat(-0).dartValue;
      expect(negZero == 0, isTrue);
      expect(negZero.isNegative, isTrue);
      expect(const MontyFloat(0).dartValue.isNegative, isFalse);
      expect(const MontyFloat(2.5).dartValue, 2.5);
      expect(const MontyFloat(-0).value.isNegative, isTrue);
    });
    test('REQ-MontyFloat-25: tagged text appends .0 only when needed', () {
      Object? text(double v) => (MontyFloat(v).toJson()! as Map)['value'];
      expect(text(4), '4.0');
      expect(text(-4), '-4.0');
      expect(text(123456789), '123456789.0');
      expect(text(1e21), '1e+21');
      expect(text(1e22), '1e+22');
      expect(text(-1.5e300), '-1.5e+300');
      expect(text(-0), '-0.0');
      expect(const MontyFloat(4).toJson(), {'__type': 'float', 'value': '4.0'});
      // A non-integral finite float is a plain JSON number, not tagged.
      expect(const MontyFloat(1.5).toJson(), 1.5);
      expect(const MontyFloat(1e-7).toJson(), 1e-7);
    });
    test(
      'REQ-MontyFloat-27: shared tagged maps are one object per projection',
      () {
        const f = MontyFloat(4);
        final list = const MontyList([f, f]).toJson()! as List;
        expect(list[0], isA<Map<String, Object?>>());
        expect(identical(list[0], list[1]), isTrue);

        // A named tuple's dartValue children use the toJson projection.
        const nt = MontyNamedTuple(
          typeName: 'T',
          fieldNames: ['a', 'b'],
          values: [f, f],
        );
        final values = nt.dartValue['values']! as List;
        expect(values[0], {'__type': 'float', 'value': '4.0'});
        expect(identical(values[0], values[1]), isTrue);

        // The direct projection of the same MontyFloat stays a double, and the
        // two projections do not share memoised objects.
        const mixed = MontyList([f, nt, f]);
        final out = mixed.dartValue as List;
        expect(out[0], 4.0);
        expect(out[2], 4.0);
        final inner = ((out[1] as Map)['values']! as List)[0];
        expect(inner, {'__type': 'float', 'value': '4.0'});
        final json = mixed.toJson()! as List;
        expect(json[0], {'__type': 'float', 'value': '4.0'});
        expect(identical(json[0], json[2]), isTrue);
      },
    );
  });

  group('MontyBigInt projections', () {
    test(
      'REQ-MontyBigInt-18: one tagged map per projection, kept separate',
      () {
        final big = MontyBigInt(BigInt.one << 70);
        final list = MontyList([big, big]);
        final json = list.toJson()! as List;
        expect(json[0], {'__type': 'bigint', 'value': '${BigInt.one << 70}'});
        expect(identical(json[0], json[1]), isTrue);

        final direct = list.dartValue as List;
        expect(direct[0], BigInt.one << 70);
        expect(identical(direct[0], direct[1]), isTrue);

        // dartValue first, then a named tuple (toJson form) of the same leaf.
        final nt = MontyNamedTuple(
          typeName: 'T',
          fieldNames: const ['a'],
          values: [big],
        );
        final mixed = MontyList([big, nt, big]).dartValue as List;
        expect(mixed[0], BigInt.one << 70);
        expect(mixed[2], BigInt.one << 70);
        final inner = ((mixed[1] as Map)['values']! as List)[0];
        expect(inner, {'__type': 'bigint', 'value': '${BigInt.one << 70}'});
      },
    );
  });

  group('MontyString', () {
    test('REQ-MontyString-4: fromDart never interprets string contents', () {
      for (final s in [
        '42',
        '-1',
        '1.5',
        '1e5',
        'NaN',
        'Infinity',
        'true',
        'None',
        '__type',
        '{"__type":"int","value":"1"}',
        '...',
      ]) {
        final v = MontyValue.fromDart(s);
        expect(v, isA<MontyString>(), reason: s);
        expect((v as MontyString).value, s);
      }
      final inList = MontyValue.fromDart(['7', 'NaN']) as MontyList;
      expect(inList.items.every((e) => e is MontyString), isTrue);
    });
    test(
      'REQ-MontyString-17: strings stored unvalidated; encoding refuses',
      () {
        const lone = '\uD800';
        expect(const MontyString(lone).value, lone);
        final converted = MontyValue.fromDart(lone);
        expect(converted, isA<MontyString>());
        expect((converted as MontyString).value, lone);
        final inList = MontyValue.fromDart([lone]) as MontyList;
        expect((inList.items.single as MontyString).value, lone);
        // Validation happens when the value is encoded.
        expect(() => ArenaWriter().add(converted), throwsArgumentError);
        expect(() => ArenaWriter().add(inList), throwsArgumentError);
        expect(
          () => ArenaWriter().add(const MontyString('ok \u00e9')),
          returnsNormally,
        );
      },
    );
  });

  group('dispatch of integral doubles (dart2js)', () {
    void check() {
      // An explicit MontyFloat always survives.
      final explicit = MontyValue.fromDart(const MontyFloat(3));
      expect(explicit, isA<MontyFloat>());
      expect((explicit as MontyFloat).value, 3.0);
      // The exceptions hold on every backend.
      expect(MontyValue.fromDart(-0.0), isA<MontyFloat>());
      expect(
        (MontyValue.fromDart(-0.0) as MontyFloat).value.isNegative,
        isTrue,
      );
      expect(MontyValue.fromDart(double.infinity), isA<MontyFloat>());
      expect(MontyValue.fromDart(double.negativeInfinity), isA<MontyFloat>());
      expect(MontyValue.fromDart(double.nan), isA<MontyFloat>());
      expect(MontyValue.fromDart(1.5), isA<MontyFloat>());
      expect(MontyValue.fromDart(7), isA<MontyInt>());
      // The integral double depends on the backend.
      final integral = MontyValue.fromDart(3.0);
      if (_isJs) {
        expect(integral, isA<MontyInt>());
        expect((integral as MontyInt).value, 3);
      } else {
        expect(integral, isA<MontyFloat>());
      }
    }

    test(
      'REQ-MontyInt-5: dart2js selects MontyInt for an integral double',
      check,
    );
    test('REQ-MontyInt-21: only an explicit MontyFloat keeps a float', check);
    test('REQ-MontyFloat-5: explicit wrapper needed for a float', check);
    test('REQ-MontyFloat-31: explicit wrapper preserves the float', check);
    test('REQ-MontyValue-12: integral doubles are ambiguous on dart2js', check);
    test('REQ-MontyValue-49: explicit MontyFloat preserves the type', check);
    test(
      'REQ-values-and-equality-100: only -0.0 and infinities are exempt',
      check,
    );
  });
}
