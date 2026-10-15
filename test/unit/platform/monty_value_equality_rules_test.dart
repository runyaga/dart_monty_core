// The per-class equality rules the identity-aware walk keeps, including the
// ones that differ from Python.
//
// These are not defects written down as correct. Each Dart rule is the one
// the class documents, and the design for this change (C2, "per-class
// equality is unchanged") carries it on purpose, recording where Python
// answers differently. The test pins each rule so that changing one is a
// decision, and states Python's answer next to it. Python's answers are the
// language's, checked against CPython's documented `==` for each type.
//
// Each rule is checked on the fast path and on the memoised fallback, by
// wrapping both values in a list and forcing the fallback.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show MontyValueInternal, montyClassProxy, montyClassTypeProxy;
import 'package:dart_monty_core/src/platform/value_graph_budget.dart';
import 'package:test/test.dart';

/// a == b on both paths, which must agree.
bool eqBothPaths(MontyValue a, MontyValue b) {
  final fast = MontyList([a]) == MontyList([b]);
  final forced = ValueGraphBudget(maxVisits: 0);
  final slow = forced.run(() => MontyList([a]) == MontyList([b]));
  expect(forced.fallbacks, 1, reason: 'the fallback did not run');
  expect(slow, fast, reason: 'the fallback disagrees with the fast path');

  return fast;
}

void main() {
  // (description, a, b, Dart's answer, Python's answer)
  final divergences = <(String, MontyValue, MontyValue, bool, bool)>[
    (
      'named tuples compare type and field names, not just values',
      const MontyNamedTuple(
        typeName: 'P',
        fieldNames: ['x'],
        values: [MontyInt(1)],
      ),
      const MontyNamedTuple(
        typeName: 'Q',
        fieldNames: ['y'],
        values: [MontyInt(1)],
      ),
      false,
      true, // namedtuples compare as tuples
    ),
    (
      'time zones compare offset and name',
      const MontyTimeZone(offsetSeconds: 3600, name: 'A'),
      const MontyTimeZone(offsetSeconds: 3600, name: 'B'),
      false,
      true, // timezone.__eq__ compares the offset only
    ),
    (
      'a user-built MontyPath compares its raw text',
      const MontyPath('a//b'),
      const MontyPath('a/b'),
      false,
      true, // PurePosixPath('a//b') == PurePosixPath('a/b')
    ),
    (
      'a set and a frozenset with the same contents',
      const MontySet([MontyInt(1)]),
      const MontyFrozenSet([MontyInt(1)]),
      false,
      true, // {1} == frozenset({1})
    ),
    (
      'aware datetimes compare fields and offset, not the instant',
      const MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 12,
        minute: 0,
        second: 0,
        offsetSeconds: 3600,
      ),
      const MontyDateTime(
        year: 2024,
        month: 1,
        day: 1,
        hour: 11,
        minute: 0,
        second: 0,
        offsetSeconds: 0,
      ),
      false,
      true, // aware datetimes compare by instant
    ),
    (
      'times compare fold',
      const MontyTime(hour: 1, minute: 0, second: 0, microsecond: 0),
      const MontyTime(hour: 1, minute: 0, second: 0, microsecond: 0, fold: 1),
      false,
      true, // fold is ignored by time.__eq__
    ),
    (
      'exception values compare fields',
      MontyExceptionValue('ValueError', 'x'),
      MontyExceptionValue('ValueError', 'x'),
      true,
      false, // exceptions compare by identity
    ),
    (
      'file handles compare fields',
      const MontyFileHandle(path: '/f', mode: 'r'),
      const MontyFileHandle(path: '/f', mode: 'r'),
      true,
      false, // file objects compare by identity
    ),
    (
      'an int and a float of equal value',
      const MontyInt(1),
      const MontyFloat(1),
      false,
      true, // 1 == 1.0
    ),
  ];

  group('recorded divergences from Python (carried unchanged)', () {
    for (final (what, a, b, dart, python) in divergences) {
      test('$what: Dart $dart, Python $python', () {
        expect(dart, isNot(python), reason: 'listed as a divergence');
        expect(eqBothPaths(a, b), dart);
        expect(eqBothPaths(b, a), dart);
      });
    }
  });

  group('rules shared with Python', () {
    test('order does not matter in a set or a dict', () {
      expect(
        eqBothPaths(
          const MontySet([MontyInt(1), MontyInt(2)]),
          const MontySet([MontyInt(2), MontyInt(1)]),
        ),
        isTrue,
      );
      expect(
        eqBothPaths(
          const MontyDict([
            (MontyString('a'), MontyInt(1)),
            (MontyString('b'), MontyInt(2)),
          ]),
          const MontyDict([
            (MontyString('b'), MontyInt(2)),
            (MontyString('a'), MontyInt(1)),
          ]),
        ),
        isTrue,
      );
    });

    test('order matters in a list and a tuple, and they differ', () {
      const l12 = MontyList([MontyInt(1), MontyInt(2)]);
      expect(
        eqBothPaths(l12, const MontyList([MontyInt(2), MontyInt(1)])),
        isFalse,
      );
      expect(
        eqBothPaths(l12, const MontyTuple([MontyInt(1), MontyInt(2)])),
        isFalse,
      );
    });

    test('an int equals the same integer held as a big integer', () {
      expect(
        eqBothPaths(const MontyInt(5), MontyBigInt(BigInt.from(5))),
        isTrue,
      );
      expect(
        const MontyList([MontyInt(5)]).hashCode,
        MontyList([MontyBigInt(BigInt.from(5))]).hashCode,
      );
    });

    test('NaN equals NaN (so values can be map keys), -0.0 equals 0.0', () {
      expect(
        eqBothPaths(const MontyFloat(double.nan), const MontyFloat(double.nan)),
        isTrue,
      );
      expect(eqBothPaths(const MontyFloat(-0), const MontyFloat(0)), isTrue);
    });
  });

  group(
    'dicts built with a duplicate key compare their pairs as a multiset',
    () {
      // Python cannot build these; a host can. The old rule (each pair consumes
      // one equal pair on the other side) is kept, so they compare as before.
      const a1 = (MontyString('a'), MontyInt(1));
      const a2 = (MontyString('a'), MontyInt(2));

      test('the same pairs in any order are equal', () {
        expect(
          eqBothPaths(const MontyDict([a1, a2]), const MontyDict([a2, a1])),
          isTrue,
        );
        expect(
          eqBothPaths(const MontyDict([a1, a1]), const MontyDict([a1, a1])),
          isTrue,
        );
      });

      test('a repeated pair is not equal to two different pairs', () {
        expect(
          eqBothPaths(const MontyDict([a1, a1]), const MontyDict([a1, a2])),
          isFalse,
        );
        expect(
          eqBothPaths(const MontyDict([a1, a2]), const MontyDict([a1, a1])),
          isFalse,
        );
      });

      test('toJson keeps the first position of a key with its last value', () {
        expect(const MontyDict([a1, a2]).toJson(), {
          '__type': 'dict',
          'value': {'a': 2},
        });
      });
    },
  );

  group('class instances', () {
    final point = montyClassTypeProxy(
      name: 'Point',
      id: 'p',
      hostDefined: false,
      isDataclass: true,
      attrs: const {},
    );

    MontyClassProxy inst(String id, int x, {MontyClassTypeProxy? type}) =>
        montyClassProxy(
          classType: type ?? point,
          instanceId: id,
          attrs: {'x': MontyInt(x)},
        );

    test('compare class, instance id and attributes', () {
      final [a, b] = List.generate(2, (_) => inst('1', 1));
      expect(eqBothPaths(a, b), isTrue);
      expect(eqBothPaths(a, inst('2', 1)), isFalse);
      expect(eqBothPaths(a, inst('1', 2)), isFalse);
      final other = montyClassTypeProxy(
        name: 'Point',
        id: 'q',
        hostDefined: false,
        isDataclass: true,
        attrs: const {},
      );
      expect(eqBothPaths(a, inst('1', 1, type: other)), isFalse);
    });
  });
}
