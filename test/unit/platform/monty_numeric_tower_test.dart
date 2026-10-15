// MontyComplex (SPEC2 Q46) and the numeric tower in public equality (C5D
// q4, contracts/equality-tower.md): bool, int, big int, float and complex
// compare as Python's numbers, symmetrically and exactly, with one hash per
// value. The upstream answers for fixed pairs are in
// monty_value_oracle_test.dart; this file adds the class itself and a
// randomized property check over the five classes.
import 'dart:math';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show MontyValueInternal;
import 'package:test/test.dart';

/// dart2js, where an `int` is a double.
const bool _isJs = identical(1, 1.0);

void main() {
  group('MontyComplex', () {
    test('mirrors MontyFloat: const, two final doubles, its toString', () {
      const c = MontyComplex(1.5, -2.25);
      expect(c.real, 1.5);
      expect(c.imag, -2.25);
      // As MontyFloat's: Dart's double text (an integral double prints
      // without `.0` on dart2js, as MontyFloat's does).
      expect(c.toString(), 'MontyComplex(1.5, -2.25)');
      expect(MontyValue.fromDart(c), same(c));
    });

    test('projects each part in MontyFloat form', () {
      const c = MontyComplex(double.nan, -0);
      expect(c.toJson(), {
        '__type': 'complex',
        'real': {'__type': 'float', 'value': 'NaN'},
        'imag': {'__type': 'float', 'value': '-0.0'},
      });
      expect(const MontyComplex(1.25, 4).dartValue, {
        '__type': 'complex',
        'real': 1.25,
        'imag': {'__type': 'float', 'value': '4.0'},
      });
      expect(
        const MontyComplex(double.infinity, double.negativeInfinity).toJson(),
        {
          '__type': 'complex',
          'real': {'__type': 'float', 'value': 'Infinity'},
          'imag': {'__type': 'float', 'value': '-Infinity'},
        },
      );
    });

    test('compares part by part; NaN equals NaN (the kept divergence)', () {
      expect(
        const MontyComplex(double.nan, 1),
        const MontyComplex(double.nan, 1),
      );
      expect(const MontyComplex(1, 2), isNot(const MontyComplex(2, 1)));
      expect(const MontyComplex(0, 0), const MontyComplex(-0, -0));
      expect(const MontyComplex(double.nan, 0), const MontyFloat(double.nan));
      expect(const MontyComplex(1, 1), isNot(const MontyInt(1)));
      expect(const MontyComplex(1, -0), const MontyBool(true));
    });

    test('a zero imaginary part hashes as the real part', () {
      expect(const MontyComplex(3, 0).hashCode, const MontyInt(3).hashCode);
      expect(
        const MontyComplex(3, -0).hashCode,
        const MontyFloat(3).hashCode,
      );
      expect(
        const MontyComplex(double.nan, 0).hashCode,
        const MontyFloat(double.nan).hashCode,
      );
    });
  });

  group('the tower is exact, never through a double', () {
    final two64 = BigInt.two.pow(64);
    test('2**64 + 1 != float(2**64); 2**64 == float(2**64)', () {
      final f = MontyFloat(two64.toDouble());
      expect(MontyBigInt(two64 + BigInt.one), isNot(f));
      expect(f, isNot(MontyBigInt(two64 + BigInt.one)));
      expect(MontyBigInt(two64), f);
      expect(MontyBigInt(two64).hashCode, f.hashCode);
    });

    test('2**53 + 1 != float(2**53)', () {
      final two53 = BigInt.two.pow(53);
      final f = MontyFloat(two53.toDouble());
      expect(MontyBigInt(two53 + BigInt.one), isNot(f));
    });

    test('an int beyond 2^53 on the VM compares exactly', () {
      if (_isJs) return markTestSkipped('dart2js holds no such int');
      // 2^62 + 1 as a double rounds to 2^62.
      final p62 = BigInt.two.pow(62).toInt();
      final big = p62 + 1;
      expect(MontyInt(big), isNot(MontyFloat(big.toDouble())));
      final asFloat = MontyFloat(p62.toDouble());
      final asInt = MontyInt(p62);
      expect(asInt, asFloat);
      expect(asInt.hashCode, asFloat.hashCode);
    });
  });

  test('random numbers: == is symmetric and transitive, equal hashes '
      'agree, across all five classes', () {
    final rnd = Random(20261015);
    final values = [for (var i = 0; i < 400; i++) _randomNumber(rnd)];
    for (final a in values) {
      for (final b in values) {
        final ab = a == b;
        expect(b == a, ab, reason: '$a vs $b: symmetry');
        if (ab) expect(a.hashCode, b.hashCode, reason: '$a == $b: hash');
      }
    }
    // Transitivity, on the equal classes.
    for (final a in values) {
      final same = values.where((b) => b == a).toList();
      for (final b in same) {
        for (final c in same) {
          expect(b == c, isTrue, reason: '$b == $a == $c');
        }
      }
    }
  });
}

/// One of the five classes near the boundaries that matter: ±0.0, small
/// integers, 2^53 and 2^64 neighbours, integral and non-integral floats,
/// the infinities, NaN, and complexes with zero and non-zero imaginary parts.
MontyValue _randomNumber(Random r) {
  final pivots = [
    BigInt.zero,
    BigInt.one,
    BigInt.two,
    BigInt.two.pow(53),
    BigInt.two.pow(63),
    BigInt.two.pow(64),
  ];
  final pivot = pivots[r.nextInt(pivots.length)];
  final n =
      (pivot + BigInt.from(r.nextInt(3) - 1)) *
      (r.nextBool() ? BigInt.one : -BigInt.one);
  final d = switch (r.nextInt(8)) {
    0 => double.nan,
    1 => double.infinity,
    2 => -0.0,
    3 => r.nextInt(3) + 0.5,
    _ => n.toDouble(),
  };

  return switch (r.nextInt(5)) {
    0 => MontyBool(n.isOdd),
    1 => n.abs() <= BigInt.two.pow(53) ? MontyInt(n.toInt()) : MontyBigInt(n),
    2 => MontyBigInt(n),
    3 => MontyFloat(d),
    _ => MontyComplex(d, _imaginary(r)),
  };
}

/// A non-zero imaginary part one time in three, else 0 or -0.0.
double _imaginary(Random r) {
  if (r.nextInt(3) == 0) return 1;

  return r.nextBool() ? 0 : -0.0;
}
