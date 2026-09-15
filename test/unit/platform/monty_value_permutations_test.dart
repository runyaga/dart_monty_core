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

/// One constructible sample per MontyValue subtype.
final samples = <String, MontyValue>{
  'MontyNone': const MontyNone(),
  'MontyBool': const MontyBool(true),
  'MontyInt': const MontyInt(42),
  'MontyBigInt': MontyBigInt(BigInt.parse('123456789012345678901234567890')),
  'MontyFloat': const MontyFloat(1.5),
  'MontyString': const MontyString('s'),
  'MontyBytes': const MontyBytes([1, 2, 3]),
  'MontyList': const MontyList([MontyInt(1)]),
  'MontyTuple': const MontyTuple([MontyInt(1)]),
  'MontyDict': const MontyDict([(MontyString('k'), MontyInt(1))]),
  'MontySet': const MontySet([MontyInt(1)]),
  'MontyFrozenSet': const MontyFrozenSet([MontyInt(1)]),
  'MontyEllipsis': const MontyEllipsis(),
  'MontyNotImplemented': const MontyNotImplemented(),
  'MontyPath': const MontyPath('/x'),
  'MontyDate': const MontyDate(year: 2026, month: 1, day: 2),
  'MontyDateTime': const MontyDateTime(
    year: 2026,
    month: 1,
    day: 2,
    hour: 3,
    minute: 4,
    second: 5,
    microsecond: 6,
  ),
  'MontyTime': const MontyTime(hour: 1, minute: 2, second: 3, microsecond: 4),
  'MontyTimeDelta': const MontyTimeDelta(days: 1, seconds: 2),
  'MontyTimeZone': const MontyTimeZone(offsetSeconds: 0),
  'MontyExceptionValue': const MontyExceptionValue(
    excType: 'ValueError',
    message: 'm',
  ),
  'MontyOpaque': const MontyOpaque(MontyOpaqueKind.repr, 'x'),
  'MontyNamedTuple': const MontyNamedTuple(
    typeName: 'P',
    fieldNames: ['x'],
    values: [MontyInt(1)],
  ),
  'MontyFileHandle': const MontyFileHandle(path: '/f', mode: 'r'),
  'MontyClassInstance': const MontyClassInstance(
    classType: MontyClassType(
      name: 'C',
      id: '1',
      hostDefined: false,
      isDataclass: false,
      attrs: {},
    ),
    instanceId: 'i',
    attrs: {},
  ),
  'MontyDataclass': const MontyDataclass(
    name: 'D',
    typeId: 1,
    fieldNames: ['f'],
    attrs: {'f': MontyInt(1)},
  ),
};

void main() {
  group('permutation matrix', () {
    test('the table covers EVERY MontyValue subtype', () {
      // The guard that stops this file rotting: adding a subtype without a
      // sample must fail here, not silently reduce coverage.
      expect(
        samples.length,
        26,
        reason:
            'a MontyValue subtype was added or removed; update `samples` '
            'so the matrix stays exhaustive',
      );
      expect(
        samples.entries.every((e) => e.value.runtimeType.toString() == e.key),
        isTrue,
        reason: 'a sample does not match its key',
      );
    });

    for (final entry in samples.entries) {
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
