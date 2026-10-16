// Tests for the scalar members of the MontyValue family.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show MontyValueInternal;
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:test/test.dart';

import '_monty_value_support.dart';

/// True where an integral double is also an `int` (dart2js).
const bool _isJs = identical(0, 0.0);

/// Fresh, non-canonical instances: a `const` twin is the same object, and
/// identity-only equality would pass on it.
const MontyNone Function() _newNone = MontyNone.new;
const MontyEllipsis Function() _newEllipsis = MontyEllipsis.new;
const MontyNotImplemented Function() _newNotImplemented =
    MontyNotImplemented.new;
MontyNone _none() => _newNone();
MontyNotImplemented _notImplemented() => _newNotImplemented();
MontyEllipsis _ellipsis() => _newEllipsis();

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
    test('MontyBigInt', () {
      final v = MontyBigInt(BigInt.one << 80);
      expect(identical(MontyValue.fromDart(v), v), isTrue);
    });
    test('MontyEllipsis', () {
      final v = _ellipsis();
      expect(identical(MontyValue.fromDart(v), v), isTrue);
      expect(MontyValue.fromDart(v), isA<MontyEllipsis>());
    });
    test('MontyExceptionValue', () {
      final v = MontyExceptionValue('ValueError', 'bad', const {
        'k': MontyInt(1),
      });
      expect(identical(MontyValue.fromDart(v), v), isTrue);
    });
    test('MontyNotImplemented', () {
      final v = _notImplemented();
      expect(identical(MontyValue.fromDart(v), v), isTrue);
    });
    test('MontyPath', () {
      final v = MontyPath('/a/b');
      expect(identical(MontyValue.fromDart(v), v), isTrue);
    });
    test('raw BigInt is refused, MontyBigInt is not', () {
      expect(() => MontyValue.fromDart(BigInt.one), throwsArgumentError);
      expect(() => MontyValue.fromDart(BigInt.one << 70), throwsArgumentError);
      expect(
        () => MontyValue.fromDart([BigInt.one]),
        throwsArgumentError,
      );
      expect(MontyValue.fromDart(MontyBigInt(BigInt.one)), isA<MontyBigInt>());
    });
    test('a raw BigInt throws ArgumentError', () {
      final rejects = throwsA(isA<ArgumentError>());
      expect(
        () => MontyValue.fromDart(BigInt.parse('123456789012345678901234567')),
        rejects,
      );
      expect(() => MontyValue.fromDart({'k': BigInt.zero}), rejects);
    });
  });

  group('toString', () {
    test('MontyBool(<value>)', () {
      expect(const MontyBool(true).toString(), 'MontyBool(true)');
      expect(const MontyBool(false).toString(), 'MontyBool(false)');
    });
    test('MontyInt(<value>)', () {
      expect(const MontyInt(42).toString(), 'MontyInt(42)');
      expect(const MontyInt(-7).toString(), 'MontyInt(-7)');
      expect(const MontyInt(0).toString(), 'MontyInt(0)');
    });
    test('MontyBigInt(<value>)', () {
      final big = BigInt.parse('123456789012345678901234567890');
      final text = MontyBigInt(big).toString();
      expect(text, 'MontyBigInt($big)');
      expect(text, 'MontyBigInt(123456789012345678901234567890)');
      final negative = MontyBigInt(-big).toString();
      expect(negative, startsWith('MontyBigInt(-1234'));
      expect(negative, endsWith('890)'));
    });
    test('MontyFloat( + interpolated double + )', () {
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
    test('MontyString( + text + )', () {
      expect(const MontyString('hi').toString(), 'MontyString(hi)');
      expect(const MontyString('').toString(), 'MontyString()');
      expect(const MontyString('a b)').toString(), 'MontyString(a b))');
    });
  });

  group('equality and hashing', () {
    test('equal exactly to another MontyNone', () {
      final none = _none();
      const Object? asNull = null;
      const Object asZero = 0;
      const Object asFalse = false;
      expect(none == _none(), isTrue);
      expect(_none() == _none(), isTrue);
      expect(none == asNull, isFalse);
      expect(none == const MontyBool(false), isFalse);
      expect(none == const MontyInt(0), isFalse);
      expect(none == const MontyFloat(0), isFalse);
      expect(none == MontyBigInt(BigInt.zero), isFalse);
      expect(none == const MontyString(''), isFalse);
      expect(none == asZero, isFalse);
      expect(none == asFalse, isFalse);
      for (final other in _others()) {
        if (other is MontyNone) continue;
        expect(none == other, isFalse, reason: '$other');
        expect(other == none, isFalse, reason: '$other');
      }
    });
    test('hashCode equals null.hashCode', () {
      final nullHash = null.hashCode;
      expect(const MontyNone().hashCode, nullHash);
      expect(MontyValue.fromDart(null).hashCode, nullHash);
    });
    test('hashCode is the stored string hashCode', () {
      for (final s in ['', 'a', 'hello world', 'é\u{1F600}']) {
        expect(MontyString(s).hashCode, s.hashCode);
      }
    });
    test('equal to every ellipsis, unequal to others', () {
      final a = _ellipsis();
      final b = MontyValue.fromDart(_ellipsis());
      expect(identical(a, b), isFalse);
      expect(a == b, isTrue);
      for (final other in _others()) {
        if (other is MontyEllipsis) continue;
        expect(a == other, isFalse, reason: '$other');
        expect(other == a, isFalse, reason: '$other');
      }
      const Object? asNull = null;
      const Object asText = '...';
      expect(a == asNull, isFalse);
      expect(a == asText, isFalse);
    });
    test('hashCode is the type object hashCode', () {
      final typeHash = (MontyEllipsis).hashCode;
      expect(const MontyEllipsis().hashCode, typeHash);
      expect(MontyValue.fromDart(const MontyEllipsis()).hashCode, typeHash);
    });
  });

  group('MontyFloat', () {
    test('stores specials; dartValue returns the double', () {
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
    test('tagged text appends .0 only when needed', () {
      Object? text(double v) =>
          castTo<Map<Object?, Object?>>(MontyFloat(v).toJson())['value'];
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
      'shared tagged maps are one object per projection',
      () {
        const f = MontyFloat(4);
        final [first, second, ...] = castTo<List<Object?>>(
          const MontyList([f, f]).toJson(),
        );
        expect(first, isA<Map<String, Object?>>());
        expect(identical(first, second), isTrue);

        // A named tuple's dartValue children use the toJson projection.
        const nt = MontyNamedTuple(
          typeName: 'T',
          fieldNames: ['a', 'b'],
          values: [f, f],
        );
        final [tagged, again, ...] = nt.dartValue['values']! as List;
        expect(tagged, {'__type': 'float', 'value': '4.0'});
        expect(identical(tagged, again), isTrue);

        // The direct projection of the same MontyFloat stays a double, and the
        // two projections do not share memoised objects.
        const mixed = MontyList([f, nt, f]);
        final [out0, out1, out2, ...] = mixed.dartValue as List;
        expect(out0, 4.0);
        expect(out2, 4.0);
        final [inner, ...] = (out1 as Map)['values']! as List;
        expect(inner, {'__type': 'float', 'value': '4.0'});
        final [json0, _, json2, ...] = castTo<List<Object?>>(mixed.toJson());
        expect(json0, {'__type': 'float', 'value': '4.0'});
        expect(identical(json0, json2), isTrue);
      },
    );
  });

  group('MontyBigInt projections', () {
    test(
      'one tagged map per projection, kept separate',
      () {
        final big = MontyBigInt(BigInt.one << 70);
        final list = MontyList([big, big]);
        final [json0, json1, ...] = castTo<List<Object?>>(list.toJson());
        expect(json0, {'__type': 'bigint', 'value': '${BigInt.one << 70}'});
        expect(identical(json0, json1), isTrue);

        final [direct0, direct1, ...] = list.dartValue as List;
        expect(direct0, BigInt.one << 70);
        expect(identical(direct0, direct1), isTrue);

        // dartValue first, then a named tuple (toJson form) of the same leaf.
        final nt = MontyNamedTuple(
          typeName: 'T',
          fieldNames: const ['a'],
          values: [big],
        );
        final [mixed0, mixed1, mixed2, ...] =
            MontyList([big, nt, big]).dartValue as List;
        expect(mixed0, BigInt.one << 70);
        expect(mixed2, BigInt.one << 70);
        final [inner, ...] = (mixed1 as Map)['values']! as List;
        expect(inner, {'__type': 'bigint', 'value': '${BigInt.one << 70}'});
      },
    );
  });

  group('MontyString', () {
    test('fromDart never interprets string contents', () {
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
      'strings stored unvalidated; encoding refuses',
      () {
        const lone = '\uD800';
        expect(const MontyString(lone).value, lone);
        final converted = MontyValue.fromDart(lone);
        expect(converted, isA<MontyString>());
        expect((converted as MontyString).value, lone);
        final inList = MontyValue.fromDart([lone]) as MontyList;
        final [only] = inList.items;
        expect((only as MontyString).value, lone);
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
      final isFloat = isA<MontyFloat>();
      final isInt = isA<MontyInt>();
      // An explicit MontyFloat always survives.
      final explicit = MontyValue.fromDart(const MontyFloat(3));
      expect(explicit, isFloat);
      expect((explicit as MontyFloat).value, 3.0);
      // The exceptions hold on every backend.
      final negZero = MontyValue.fromDart(-0.0);
      expect(negZero, isFloat);
      expect((negZero as MontyFloat).value.isNegative, isTrue);
      expect(MontyValue.fromDart(double.infinity), isFloat);
      expect(MontyValue.fromDart(double.negativeInfinity), isFloat);
      expect(MontyValue.fromDart(double.nan), isFloat);
      expect(MontyValue.fromDart(1.5), isFloat);
      expect(MontyValue.fromDart(7), isInt);
      // The integral double depends on the backend.
      final integral = MontyValue.fromDart(3.0);
      if (_isJs) {
        expect(integral, isInt);
        expect((integral as MontyInt).value, 3);
      } else {
        expect(integral, isFloat);
      }
    }

    test(
      'dart2js selects MontyInt for an integral double',
      check,
    );
    test('only an explicit MontyFloat keeps a float', check);
    test('explicit wrapper needed for a float', check);
    test('explicit wrapper preserves the float', check);
    test('integral doubles are ambiguous on dart2js', check);
    test('explicit MontyFloat preserves the type', check);
    test(
      'only -0.0 and infinities are exempt',
      check,
    );
  });
}
