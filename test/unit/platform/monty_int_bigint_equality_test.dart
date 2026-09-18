// Cross-type equality between MontyInt and MontyBigInt.
//
// Python has ONE int type; the split here is a Dart artifact for JS-safe
// integers, so two representations of the same integer must compare equal.
//
// RUN ON EVERY BACKEND ON PURPOSE. The fix turns on `BigInt.isValidInt`, which
// is BACKEND-DEPENDENT -- measured, 2^53+1 is a valid int on the VM and NOT on
// dart2js, because on dart2js an `int` is a double and cannot hold it. That
// divergence is correct: MontyInt equals MontyBigInt exactly when the bigint is
// representable as a MontyInt on the executing backend. A VM-only test would
// not have shown it.
@TestOn('vm || browser')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

MontyBigInt big(String s) => MontyBigInt(BigInt.parse(s));

void main() {
  group('int/bigint permutations', () {
    test('sign and zero', () {
      expect(const MontyInt(0), big('0'));
      expect(const MontyInt(-1), big('-1'));
      expect(const MontyInt(-42), big('-42'));
      expect(const MontyInt(0).hashCode, big('0').hashCode);
      expect(const MontyInt(-42).hashCode, big('-42').hashCode);
    });

    test('boundary at the wire limit, both sides', () {
      for (final s in ['9007199254740991', '9007199254740992']) {
        final asInt = MontyInt(int.parse(s));
        final asBig = big(s);
        expect(asInt, asBig, reason: s);
        expect(asInt.hashCode, asBig.hashCode, reason: s);
      }
    });

    test('unequal neighbours do not collapse', () {
      expect(const MontyInt(1), isNot(big('2')));
      expect(const MontyInt(-1), isNot(big('1')));
      expect(big('9007199254740992'), isNot(big('9007199254740993')));
    });

    test('out-of-int-range bigints equal no MontyInt', () {
      final huge = big('123456789012345678901234567890');
      expect(const MontyInt(1), isNot(huge));
      expect(huge, isNot(const MontyInt(1)));
      expect(huge, big('123456789012345678901234567890'));
    });

    test('SET membership collapses the pair', () {
      // The practical consequence of equal + equal-hash.
      final s = {const MontyInt(5), big('5')};
      expect(s.length, 1, reason: 'equal values must collapse in a Set');
      final m = <MontyValue, String>{const MontyInt(7): 'a', big('7'): 'b'};
      expect(m.length, 1, reason: 'equal keys must collapse in a Map');
      expect(m[big('7')], 'b');
      expect(m[const MontyInt(7)], 'b', reason: 'lookup by either form');
    });

    test('composes inside every container', () {
      const ints = [MontyInt(3)];
      final bigs = [big('3')];
      expect(const MontyList(ints), MontyList(bigs));
      expect(const MontyTuple(ints), MontyTuple(bigs));
      expect(const MontySet(ints), MontySet(bigs));
      expect(const MontyFrozenSet(ints), MontyFrozenSet(bigs));
      expect(const MontyList(ints).hashCode, MontyList(bigs).hashCode);
    });

    test('SCOPE: float and bool are deliberately NOT folded in', () {
      // Python says 1 == 1.0 == True. This fix covers int/bigint ONLY, because
      // the wire preserves the int/float distinction on purpose and monty
      // returns MontyBool for True. Pinned so the scope is explicit rather
      // than discovered later.
      const one = MontyInt(1);
      const oneAsFloat = MontyFloat(1);
      final notOneAsFloat = isNot(oneAsFloat);
      expect(one, notOneAsFloat);
      expect(one, isNot(const MontyBool(true)));
      expect(big('1'), notOneAsFloat);
    });

    test('equality survives a toJson round trip in both directions', () {
      final a = MontyValue.fromJson(const MontyInt(5).toJson());
      final b = MontyValue.fromJson(big('5').toJson());
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });
  });
}
