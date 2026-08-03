// The past-2^53 integer boundary — VM ONLY, and it has to be its own file.
//
// `0x7FFFFFFFFFFFFFFF` is a dart2js COMPILE error ("can't be represented
// exactly in JavaScript"), and `(1 << 53) + 1` is a value dart2js cannot hold.
// A tag or a `skip:` cannot rescue either one, because the failure happens when
// the file is compiled, before any test runs — it takes down every other test
// in the same library with it. Splitting the file is the only thing that lets
// the rest of the unit suite run on the web at all, which is what
// `unit_web` in tool/gate.sh depends on.
//
// The behaviour under test is real and backend-independent in its CONCLUSION:
// past 2^53 a value is a `MontyBigInt` on every backend, precisely so the TYPE
// does not depend on the backend (invariant I1). Only the act of *constructing*
// the input is VM-only.
@Tags(['unit', 'vm-only'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('MontyInt past 2^53 (VM only)', () {
    test('encodes as a bigint and decodes as MontyBigInt', () {
      // Tier 3 / core#128b. On dart2js `int` IS a double, so beyond 2^53 an
      // integer cannot be a MontyInt there at all — `JSON.parse` measurably
      // returns 9007199254740992 for 9007199254740993. Rather than let the TYPE
      // depend on the backend, it is a MontyBigInt on ALL backends past the
      // boundary.
      // Written as an expression, not a literal: the literal itself trips
      // avoid_js_rounded_ints, because it is precisely a value JavaScript
      // cannot hold — which is the defect under test.
      const past = MontyInt((1 << 53) + 1);
      expect(past.toJson(), {
        '__type': 'bigint',
        'value': '9007199254740993',
      });
      expect(
        MontyValue.fromJson(past.toJson()),
        MontyBigInt(BigInt.parse('9007199254740993')),
        reason: 'the value survives; the Dart type deliberately changes',
      );
    });

    test('i64 max, comfortably past the boundary', () {
      expect(
        MontyValue.fromJson(const MontyInt(0x7FFFFFFFFFFFFFFF).toJson()),
        MontyBigInt(BigInt.parse('9223372036854775807')),
      );
    });
  });
}
