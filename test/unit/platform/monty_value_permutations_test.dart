// EXHAUSTIVE property matrix over every MontyValue subtype.
//
// Table-driven on purpose: a hand-written test per subtype drifts, and the
// count silently falls behind when a subtype is added. Here the sample table IS
// the coverage claim, and `every subtype has a sample` is itself asserted.
//
// Prior coverage was sampled, not exhaustive -- measured before this file:
// 26 subtypes, but only 3 (MontyString, MontyInt, MontyTuple) were ever
// exercised as a DICT KEY, and the wire contract pinned one position only.
@TestOn('vm || browser')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_hierarchy_registry.dart';

void main() {
  group('permutation matrix', () {
    test('the table covers EVERY MontyValue subtype', () {
      // The guard that stops this file rotting: adding a subtype without a
      // sample must fail here, not silently reduce coverage.
      expect(
        hierarchySamples.length,
        26,
        reason:
            'a MontyValue subtype was added or removed; update `samples` '
            'so the matrix stays exhaustive',
      );
      expect(
        hierarchySamples.entries.every(
          (e) => e.value.runtimeType.toString() == e.key,
        ),
        isTrue,
        reason: 'a sample does not match its key',
      );
    });

    for (final entry in hierarchySamples.entries) {
      final name = entry.key;
      final v = entry.value;

      test('$name: two DISTINCT equal instances compare and hash equally', () {
        // Was `expect(v, v)`, which is vacuous: every `operator==` in this
        // library opens with `identical(this, other)`, so the comparison exits
        // on line 1 and no equality logic runs at all. It passed for
        // MontySet/MontyFrozenSet while `{1, 2} != {2, 1}` -- see
        // monty_set_order_equality_test.dart.
        //
        // A wire round trip is what makes the second instance genuinely
        // distinct, so `==` and `hashCode` are actually exercised. Equal-but-
        // not-identical hashing is the real contract; `v.hashCode ==
        // v.hashCode` never tested it.
        // NOT asserted: that `other` is non-identical. Dart canonicalises
        // const instances, so MontyNone/MontyEllipsis/MontyNotImplemented
        // round-trip to the SAME object and identity equality is the correct
        // answer for them. Asserting distinctness failed on those three.
        // The types that carry the equality logic worth testing -- every
        // collection -- do produce a distinct instance here.
        final other = MontyValue.fromJson(v.toJson());
        expect(other, v);
        expect(
          other.hashCode,
          v.hashCode,
          reason: 'equal values must hash equally',
        );
      });

      test('$name: survives a toJson/fromJson round trip', () {
        final back = MontyValue.fromJson(v.toJson());
        expect(back, v, reason: 'round trip changed the value');
      });

      test('$name: round-trips nested inside a MontyList', () {
        final back = MontyValue.fromJson(MontyList([v]).toJson());
        expect(back, MontyList([v]));
      });

      test('$name: round-trips as a DICT KEY', () {
        // Only 3 of 26 subtypes were ever exercised in key position before.
        final d = MontyDict([(v, const MontyInt(0))]);
        expect(MontyValue.fromJson(d.toJson()), d);
      });

      test('$name: dartValue does not throw', () {
        expect(() => v.dartValue, returnsNormally);
      });
    }
  });
}
