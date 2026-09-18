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

/// The three subtypes whose `dartValue` is `=> this`, by deliberate design:
/// there is no Dart primitive for a Python `time`, `Ellipsis` or
/// `NotImplemented`, so the MontyValue IS the most faithful representation.
/// Named here so the matrix asserts that choice instead of being blind to it.
const _selfReturning = {'MontyTime', 'MontyEllipsis', 'MontyNotImplemented'};

/// True if a `dartValue` result still contains a [MontyValue] anywhere.
bool _leaksMontyValue(Object? o) {
  if (o is MontyValue) return true;
  if (o is List) return o.any(_leaksMontyValue);
  if (o is Map) {
    return o.keys.any(_leaksMontyValue) || o.values.any(_leaksMontyValue);
  }

  return false;
}

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

      test('$name: round-trips nested inside a MontyList', () {
        final back = MontyValue.fromJson(MontyList([v]).toJson());
        expect(back, MontyList([v]));
      });

      test('$name: round-trips as a DICT KEY', () {
        // Only 3 of 26 subtypes were ever exercised in key position before.
        final d = MontyDict([(v, const MontyInt(0))]);
        expect(MontyValue.fromJson(d.toJson()), d);
      });

      test('$name: dartValue exposes DART values, not MontyValue', () {
        // Was `expect(() => v.dartValue, returnsNormally)`, which cannot fail
        // for MontyTime, MontyEllipsis and MontyNotImplemented -- their
        // dartValue is `=> this`, so "it returned" is guaranteed by the
        // signature. For the collections it was nearly as weak: returning a
        // list of MontyValue children, un-converted, also "does not throw".
        //
        // The real contract is that dartValue hands back DART values. A
        // wrapper that forgets `.dartValue` on its children leaks MontyValue
        // into the result, and only this assertion sees it.
        final d = v.dartValue;
        if (_selfReturning.contains(name)) {
          expect(
            identical(d, v),
            isTrue,
            reason:
                '$name is documented to return itself; if that changed, '
                'move it out of _selfReturning rather than loosening this',
          );

          return;
        }
        expect(
          _leaksMontyValue(d),
          isFalse,
          reason: 'dartValue leaked a MontyValue: a child was not converted',
        );
      });
    }
  });
}
