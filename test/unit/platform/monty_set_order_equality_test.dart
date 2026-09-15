// `MontySet` and `MontyFrozenSet` compared and hashed ORDER-SENSITIVELY.
//
// `{1, 2}` and `{2, 1}` -- the same set in Python -- were unequal, and hashed
// differently, because `==` ran `DeepCollectionEquality` over a `List` and a
// list compares in order.
//
// This is the same defect the two dict classes had. [MontyDict] was fixed to
// compare order-insensitively (edd9c41); the sets were left behind, so the file
// contradicted itself 20 lines apart.
//
// The sandbox is the authority and it is unambiguous:
//   crates/monty/src/types/set.rs:412  -- length check + per-element `contains`
//   crates/monty/src/types/set.rs:1435 -- "XOR is commutative, so the hash is
//                                         independent of insertion order"
//
// WHY THE 131-TEST PERMUTATION MATRIX DID NOT CATCH THIS: it asserted
// `expect(v, v)`, which exits on the `identical(this, other)` short-circuit on
// line 1 of every `operator==`, and its round trips preserve element order. No
// assertion anywhere PERMUTED a collection. That gap is closed here and in the
// matrix's now-distinct-instance reflexivity test.
@TestOn('vm || browser')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('set equality is order-insensitive', () {
    test('MontySet: {1, 2} == {2, 1}', () {
      const a = MontySet([MontyInt(1), MontyInt(2)]);
      const b = MontySet([MontyInt(2), MontyInt(1)]);
      expect(a, b);
      expect(a.hashCode, b.hashCode, reason: 'equal sets must hash equally');
    });

    test('MontyFrozenSet: {1, 2} == {2, 1}', () {
      const a = MontyFrozenSet([MontyInt(1), MontyInt(2)]);
      const b = MontyFrozenSet([MontyInt(2), MontyInt(1)]);
      expect(a, b);
      expect(a.hashCode, b.hashCode, reason: 'equal sets must hash equally');
    });

    test('order-insensitivity survives a wire round trip', () {
      const a = MontySet([MontyInt(1), MontyString('x'), MontyBool(true)]);
      const shuffled = MontySet([
        MontyBool(true),
        MontyInt(1),
        MontyString('x'),
      ]);
      expect(MontyValue.fromJson(a.toJson()), shuffled);
    });

    test('nested: a set inside a list still compares order-insensitively', () {
      const a = MontyList([
        MontySet([MontyInt(1), MontyInt(2)]),
      ]);
      const b = MontyList([
        MontySet([MontyInt(2), MontyInt(1)]),
      ]);
      expect(a, b);
    });

    test('a set as a DICT KEY compares order-insensitively', () {
      const a = MontyDict([
        (MontyFrozenSet([MontyInt(1), MontyInt(2)]), MontyInt(9)),
      ]);
      const b = MontyDict([
        (MontyFrozenSet([MontyInt(2), MontyInt(1)]), MontyInt(9)),
      ]);
      expect(a, b);
    });
  });

  group('order-insensitive must not become "everything is equal"', () {
    test('different MEMBERS are still unequal', () {
      const a = MontySet([MontyInt(1), MontyInt(2)]);
      const b = MontySet([MontyInt(1), MontyInt(3)]);
      expect(a, isNot(b));
    });

    test('different LENGTHS are still unequal', () {
      const a = MontySet([MontyInt(1), MontyInt(2)]);
      const b = MontySet([MontyInt(1)]);
      expect(a, isNot(b));
    });

    test('a subset is NOT equal -- multiset consumption, not subset', () {
      const a = MontySet([MontyInt(1), MontyInt(1)]);
      const b = MontySet([MontyInt(1), MontyInt(2)]);
      expect(a, isNot(b));
    });

    // `MontySet` vs `MontyFrozenSet` inequality is NOT asserted here: it is
    // already asserted at monty_value_test.dart:438, which is the established
    // home for MontySet basics. A second copy is how two files come to
    // disagree.
  });

  test('a FORGED duplicate does not hash like the empty set', () {
    // Upstream XORs element hashes, which cancels duplicates. Monty collapses
    // equal elements before the wire, so upstream never sees a duplicate -- but
    // this decoder parses whatever arrives, and `{"__type": "set",
    // "value": [1, 1]}` is a payload a sandbox can emit. Under XOR that hashes
    // to 0, identical to the empty set. Folding with `+` is what makes this
    // assertion pass.
    final one = const MontyInt(1).toJson();
    final forged = MontyValue.fromJson({
      '__type': 'set',
      'value': [one, one],
    });
    expect(forged, isA<MontySet>());
    expect(
      forged.hashCode,
      isNot(const MontySet([]).hashCode),
      reason: 'a duplicate-bearing set must not collide with the empty set',
    );
  });
}
