// The per-class equality rules the identity-aware walk keeps: Python's, with
// the divergences that have a reason (AGY1 Q7, C5D q4).
//
// The C2a §2 rows that C2 carried unchanged are aligned at the cutover, row
// by row (decisions/equality.md): each now answers as Python does. The rows
// kept as divergences are exception values and file handles (a detached
// copy has no Python identity) and NaN (reflexive, so values can be map
// keys). Python's answers are the language's; upstream's recorded ones are
// in _value_oracle.g.dart (monty_value_oracle_test.dart).
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
  final rows = <(String, MontyValue, MontyValue, bool, bool)>[
    (
      'named tuples compare as tuples, whatever the names',
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
      true,
      true, // namedtuples compare as tuples
    ),
    (
      'time zones compare the offset only',
      const MontyTimeZone(offsetSeconds: 3600, name: 'A'),
      const MontyTimeZone(offsetSeconds: 3600, name: 'B'),
      true,
      true, // timezone.__eq__ compares the offset only
    ),
    (
      'a user-built MontyPath is normalised',
      MontyPath('a//b'),
      MontyPath('a/b'),
      true,
      true, // PurePosixPath('a//b') == PurePosixPath('a/b')
    ),
    (
      'a set and a frozenset with the same contents',
      const MontySet([MontyInt(1)]),
      const MontyFrozenSet([MontyInt(1)]),
      true,
      true, // {1} == frozenset({1})
    ),
    (
      'aware datetimes compare the instant',
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
      true,
      true, // aware datetimes compare by instant
    ),
    (
      'times ignore fold',
      const MontyTime(hour: 1, minute: 0, second: 0, microsecond: 0),
      const MontyTime(hour: 1, minute: 0, second: 0, microsecond: 0, fold: 1),
      true,
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
      MontyFileHandle('/f', 'r'),
      MontyFileHandle('/f', 'r'),
      true,
      false, // file objects compare by identity
    ),
    (
      'an int and a float of equal value',
      const MontyInt(1),
      const MontyFloat(1),
      true,
      true, // 1 == 1.0
    ),
  ];

  group('the C2a §2 rows: aligned with Python, or a kept divergence', () {
    for (final (what, a, b, dart, python) in rows) {
      final kept = dart != python;
      test('$what: Dart $dart, Python $python'
          '${kept ? ' (kept divergence)' : ''}', () {
        expect(eqBothPaths(a, b), dart);
        expect(eqBothPaths(b, a), dart);
        if (dart) expect(a.hashCode, b.hashCode, reason: 'equal, so hash');
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

  group('a dict built with a repeated key compares as Python builds it', () {
    // Python cannot hold these; a host can build one. It compares as the
    // dict Python's constructor makes from the same pairs: the first key's
    // position, the last value (Q41).
    const a1 = (MontyString('a'), MontyInt(1));
    const a2 = (MontyString('a'), MontyInt(2));

    test('the value it keeps is the last', () {
      expect(
        eqBothPaths(const MontyDict([a1, a2]), const MontyDict([a2])),
        isTrue,
      );
      expect(
        eqBothPaths(const MontyDict([a1, a2]), const MontyDict([a2, a1])),
        isFalse,
      );
      expect(
        eqBothPaths(const MontyDict([a1, a1]), const MontyDict([a1])),
        isTrue,
      );
      expect(
        const MontyDict([a1, a2]).hashCode,
        const MontyDict([a2]).hashCode,
      );
    });

    test('a set compares by its distinct members', () {
      expect(
        eqBothPaths(
          const MontySet([MontyInt(1), MontyInt(1)]),
          const MontySet([MontyInt(1)]),
        ),
        isTrue,
      );
      expect(
        const MontySet([MontyInt(1), MontyInt(1)]).hashCode,
        const MontySet([MontyInt(1)]).hashCode,
      );
    });

    test('toJson keeps the first position of a key with its last value', () {
      expect(const MontyDict([a1, a2]).toJson(), {
        '__type': 'dict',
        'value': {'a': 2},
      });
    });
  });

  group('class proxies', () {
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

    test('compare class name, dataclass flag and attributes', () {
      // Upstream's MontyClassProxy.__eq__ (class_instance.rs:255-263): the
      // instance id and the class id are not compared.
      final [a, b] = List.generate(2, (_) => inst('1', 1));
      expect(eqBothPaths(a, b), isTrue);
      expect(eqBothPaths(a, inst('2', 1)), isTrue);
      expect(eqBothPaths(a, inst('1', 2)), isFalse);
      MontyClassTypeProxy type({String name = 'Point', bool dc = true}) =>
          montyClassTypeProxy(
            name: name,
            id: 'q',
            hostDefined: true,
            isDataclass: dc,
            attrs: const {},
          );
      expect(eqBothPaths(a, inst('1', 1, type: type())), isTrue);
      expect(a.hashCode, inst('2', 1, type: type()).hashCode);
      expect(eqBothPaths(a, inst('1', 1, type: type(name: 'P'))), isFalse);
      expect(eqBothPaths(a, inst('1', 1, type: type(dc: false))), isFalse);
    });
  });
}
