// The identity-aware walk gives the reference results.
//
// Reference: _reference_value_ops.dart, a plain recursion over the aligned
// rules (Python's equality for named tuples, set/frozenset, repeated set
// members and dict keys, class proxies). It shares no code with
// monty_value_graph.dart; equal values must hash equal on both paths.
// Every value is checked twice, once on the recursive fast path and once with
// the budget at zero, which
// forces the memoised fallback; ValueGraphBudget.fallbacks proves the second
// really ran.
//
// Breaks applied and seen red, one at a time: `_DictFrame` never comparing
// the value; the fallback summing set hashes without `_mixElementHash`; the
// string-keyed dict projection keeping each key's first value; `_take` not
// consuming a matched element; the hashed dict match on the fast path (more
// than eight pairs) ignoring the value; a tuple's toJson map typed
// Map<String, Object>; a comparison of two kinds left uncharged; attribute
// maps with a repeated key compared only in step, or as pairs on the
// fallback only; the fallback projecting a dict's overwritten values; field
// name lengths read before their count is charged; only the left-hand
// leaf's payload charged.
@Timeout(Duration(minutes: 5))
library;

import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show
        MontyClassProxyInternal,
        MontyValueInternal,
        montyClassProxy,
        montyClassTypeProxy;
import 'package:dart_monty_core/src/platform/value_graph_budget.dart';
import 'package:test/test.dart';

import '_random_values.dart';
import '_reference_value_ops.dart';

const _cases = 3000;

bool _isNode(MontyValue v) =>
    v is MontyList ||
    v is MontyTuple ||
    v is MontySet ||
    v is MontyFrozenSet ||
    v is MontyDict ||
    v is MontyNamedTuple ||
    v is MontyClassProxy;

/// Deep equality of projection output: same shape, the same nullability of
/// map values and list elements, same key order, doubles
/// equal bit for bit (NaN equal to NaN, -0.0 distinct from 0.0).
bool _sameOutput(Object? a, Object? b) {
  if (a is double && b is double) {
    return (a.isNaN && b.isNaN) || (a == b && a.isNegative == b.isNegative);
  }
  // Whether null can be written in: Map<String, Object> versus
  // Map<String, Object?>. Not runtimeType, which dart2js may erase.
  if ((a is Map<String, Object>) != (b is Map<String, Object>) ||
      (a is List<Object>) != (b is List<Object>)) {
    return false;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    final other = b.iterator;
    for (final e in a) {
      other.moveNext();
      if (!_sameOutput(e, other.current)) return false;
    }

    return true;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    final other = b.entries.iterator;
    for (final MapEntry(:key, :value) in a.entries) {
      other.moveNext();
      if (key != other.current.key ||
          !_sameOutput(value, other.current.value)) {
        return false;
      }
    }

    return true;
  }

  return a == b;
}

typedef _Result = ({
  bool eqXY,
  bool eqYX,
  int hashX,
  int hashY,
  String jsonX,
  Object? toJsonX,
  Object? dartX,
});

_Result _measure(MontyValue x, MontyValue y) => (
  eqXY: x == y,
  eqYX: y == x,
  hashX: x.hashCode,
  hashY: y.hashCode,
  jsonX: json.encode(x.toJson()),
  toJsonX: x.toJson(),
  dartX: x.dartValue,
);

/// Checks [x] against [y] on both paths; returns the disagreements.
List<String> _check(int i, MontyValue x, MontyValue y) {
  final bad = <String>[];
  final oldXY = referenceEquals(x, y);
  final oldYX = referenceEquals(y, x);
  final oldToJson = referenceToJson(x);
  final oldJson = json.encode(oldToJson);
  final oldDart = referenceDartValue(x);

  final fast = _measure(x, y);
  // A budget of zero gives up at the first visit: every walk falls back.
  final forced = ValueGraphBudget(maxDepth: 0, maxVisits: 0);
  final slow = forced.run(() => _measure(x, y));
  final fellBack = forced.fallbacks;

  for (final (path, r) in [('fast', fast), ('fallback', slow)]) {
    if (r.eqXY != oldXY) bad.add('#$i $path: x == y is ${r.eqXY}, was $oldXY');
    if (r.eqYX != oldYX) bad.add('#$i $path: y == x is ${r.eqYX}, was $oldYX');
    if (r.eqXY && r.hashX != r.hashY) {
      bad.add('#$i $path: equal values hash differently');
    }
    if (r.jsonX != oldJson) {
      bad.add('#$i $path: toJson ${r.jsonX}, was $oldJson');
    }
    if (!_sameOutput(r.toJsonX, oldToJson)) {
      bad.add('#$i $path: toJson output types differ');
    }
    if (!_sameOutput(r.dartX, oldDart)) bad.add('#$i $path: dartValue differs');
  }
  if (fast.hashX != slow.hashX || fast.hashY != slow.hashY) {
    bad.add('#$i: the two paths hash differently');
  }
  // hashCode, toJson and dartValue on a container each walk it.
  if (_isNode(x) && fellBack < 3) {
    bad.add('#$i: the fallback ran $fellBack times, not at least 3');
  }

  return bad;
}

void main() {
  test('$_cases random trees: the old ==, hashCode, toJson and dartValue, '
      'on both paths', () {
    final rnd = Random(42);
    final gen = RandomValues(rnd);
    final bad = <String>[];
    var equalPairs = 0;
    for (var i = 0; i < _cases; i++) {
      final x = gen.value(4);
      final y = switch (rnd.nextInt(3)) {
        0 => cloneReversed(x),
        1 => mutate(cloneReversed(x), rnd),
        _ => gen.value(4),
      };
      if (referenceEquals(x, y)) equalPairs++;
      bad.addAll(_check(i, x, y));
    }
    expect(bad, isEmpty, reason: bad.take(20).join('\n'));
    // Both answers are exercised, not just one.
    expect(equalPairs, inInclusiveRange(_cases ~/ 5, _cases * 4 ~/ 5));
  });

  test('$_cases random DAGs agree with the old operations and with their '
      'own tree expansion', () {
    final rnd = Random(7);
    final bad = <String>[];
    for (var i = 0; i < _cases; i++) {
      final gen = RandomValues(rnd, share: true);
      final x = gen.value(4);
      // The same value with a different sharing layout: no node shared.
      final tree = cloneReversed(x);
      bad.addAll(_check(i, x, tree));
      if (x != tree || tree != x) bad.add('#$i: a DAG != its tree expansion');
      final other = mutate(tree, rnd);
      bad.addAll(_check(i, x, other));
    }
    expect(bad, isEmpty, reason: bad.take(20).join('\n'));
  });

  group('budget edges', () {
    MontyValue nested(int d) {
      MontyValue v = const MontyInt(1);
      for (var i = 0; i < d; i++) {
        v = MontyList([v]);
      }

      return v;
    }

    int fallbacksDuring(
      void Function() f, {
      int maxVisits = ValueGraphBudget.defaultMaxVisits,
    }) {
      final budget = ValueGraphBudget(maxVisits: maxVisits)..run(f);

      return budget.fallbacks;
    }

    final ops = <String, void Function(MontyValue, MontyValue)>{
      '==': (a, b) => expect(a == b, isTrue),
      'hashCode': (a, b) => expect(a.hashCode, b.hashCode),
      'toJson': (a, b) => expect(json.encode(a.toJson()), isNotEmpty),
      'dartValue': (a, b) => expect(a.dartValue, isA<List<Object?>>()),
    };

    for (final MapEntry(key: name, value: op) in ops.entries) {
      test('$name: 400 levels stay on the fast path, 401 fall back', () {
        expect(ValueGraphBudget.defaultMaxDepth, 400);
        final [a400, b400] = List.generate(2, (_) => nested(400));
        final [a401, b401] = List.generate(2, (_) => nested(401));
        expect(fallbacksDuring(() => op(a400, b400)), 0);
        expect(fallbacksDuring(() => op(a401, b401)), isPositive);
      });
    }

    test('dartAttrs: a deep attribute falls back alone', () {
      // One projection serves every attribute; the second must start again
      // on the fast path rather than inherit the first one's depth.
      final i = montyClassProxy(
        classType: montyClassTypeProxy(
          name: 'C',
          id: 'c',
          hostDefined: false,
          isDataclass: false,
          attrs: const {},
        ),
        instanceId: 'i',
        attrs: {
          'deep': nested(401),
          'flat': const MontyList([MontyInt(1)]),
        },
      );
      expect(fallbacksDuring(() => i.dartAttrs), 1);
    });

    test('hashCode: exactly maxVisits visits stay on the fast path', () {
      // One visit for the list and one per element.
      final v = MontyList([for (var i = 0; i < 99; i++) MontyInt(i)]);
      final h = v.hashCode;
      void same() => expect(v.hashCode, h);
      expect(fallbacksDuring(same, maxVisits: 100), 0);
      expect(fallbacksDuring(same, maxVisits: 99), 1);
    });

    test('==: exactly maxVisits visits stay on the fast path', () {
      final a = MontyList([for (var i = 0; i < 99; i++) MontyInt(i)]);
      final b = MontyList([for (var i = 0; i < 99; i++) MontyInt(i)]);
      void equal() => expect(a == b, isTrue);
      expect(fallbacksDuring(equal, maxVisits: 100), 0);
      expect(fallbacksDuring(equal, maxVisits: 99), 1);
    });

    test('a long payload is charged against the visit budget', () {
      // 1 + (1600 >> 4) = 101 for the string, 1 for the list.
      final v = MontyList([MontyString('x' * 1600)]);
      void hash() => v.hashCode;
      expect(fallbacksDuring(hash, maxVisits: 102), 0);
      expect(fallbacksDuring(hash, maxVisits: 101), 1);
    });
  });

  group('work the budget must see', () {
    int fallbacksDuring(void Function() f) {
      final budget = ValueGraphBudget()..run(f);

      return budget.fallbacks;
    }

    test('comparing identical elements is charged', () {
      // Two distinct lists of 3,000 references to one constant, each
      // referenced 3,000 times: 9M element comparisons, all `identical`.
      const n = 3000;
      MontyList refs(MontyValue v) => MontyList(List.filled(n, v));
      final [a, b] = List.generate(2, (_) => refs(const MontyNone()));
      expect(fallbacksDuring(() => expect(refs(a) == refs(b), isTrue)), 1);
    });

    test('comparing values of different kinds is charged', () {
      // An empty list and an empty tuple hash alike and are unequal, so
      // collapsing each set's repeats compares every tuple with the kept
      // list: 2,000 comparisons of two kinds per set. Charged, they take
      // the walk past 18,000 visits (20,000 measured); uncharged, it stays
      // under (16,000 measured).
      MontySet build({required bool listsFirst}) {
        final lists = [for (var i = 0; i < 2000; i++) const MontyList([])];
        final tuples = [for (var i = 0; i < 2000; i++) const MontyTuple([])];

        return MontySet(
          listsFirst ? [...lists, ...tuples] : [...tuples, ...lists],
        );
      }

      final a = build(listsFirst: true);
      final b = build(listsFirst: false);
      final budget = ValueGraphBudget(maxVisits: 18000);
      expect(budget.run(() => a == b), isTrue);
      expect(budget.fallbacks, 1);
    });

    test('a payload on the right-hand side is charged too', () {
      // MontyInt(0) == big runs BigInt.isValidInt over every digit of big.
      final big = MontyBigInt(BigInt.one << (1 << 19));
      final a = MontySet([const MontyInt(0), big]);
      final b = MontySet([big, const MontyInt(0)]);
      final budget = ValueGraphBudget(maxVisits: 100000);
      expect(
        budget.run(
          () =>
              MontyList(List.filled(1000, a)) ==
              MontyList(List.filled(1000, b)),
        ),
        isTrue,
      );
      expect(budget.fallbacks, 1);
    });
  });

  group('attribute maps compare by the value each name keeps', () {
    final type = montyClassTypeProxy(
      name: 'C',
      id: 'c',
      hostDefined: false,
      isDataclass: false,
      attrs: const {},
    );
    MontyClassProxy inst(Map<String, MontyValue> attrs) =>
        montyClassProxy(classType: type, instanceId: 'i', attrs: attrs);

    final caseless = SplayTreeMap<String, MontyValue>(
      (a, b) => a.toLowerCase().compareTo(b.toLowerCase()),
    )..['a'] = const MontyInt(1);
    // Two equal keys that are distinct objects, which only an identity map
    // keeps apart.
    final k1 = String.fromCharCodes([107]);
    final k2 = String.fromCharCodes([107]);
    Map<String, MontyValue> twoKeys(int first, int second) => Map.identity()
      ..[k1] = MontyInt(first)
      ..[k2] = MontyInt(second);

    final oneTwo = inst(twoKeys(1, 2));
    final cases = <String, (MontyValue, MontyValue)>{
      'a map with its own key comparison': (
        inst(caseless),
        inst(const {'A': MontyInt(1)}),
      ),
      'keys in another order': (
        inst(const {'a': MontyInt(1), 'b': MontyInt(2)}),
        inst(const {'b': MontyInt(2), 'a': MontyInt(1)}),
      ),
      'a repeated key, values swapped': (
        inst(twoKeys(3, 4)),
        inst(twoKeys(4, 3)),
      ),
      'a repeated key, values differ': (oneTwo, inst(twoKeys(1, 1))),
      'a repeated key and the value it keeps': (
        oneTwo,
        inst(const {'k': MontyInt(2)}),
      ),
    };
    for (final MapEntry(key: what, value: (x, y)) in cases.entries) {
      test('$what: both directions, both paths', () {
        final forced = ValueGraphBudget(maxDepth: 0, maxVisits: 0);
        for (final (p, q) in [(x, y), (y, x)]) {
          final want = referenceEquals(p, q);
          expect(p == q, want);
          expect(forced.run(() => p == q), want);
          if (want) expect(p.hashCode, q.hashCode, reason: 'equal, so hash');
        }
        expect(forced.fallbacks, 2);
      });
    }
  });

  test('repeated attribute keys holding cycles: both paths agree', () {
    MontyList selfList() {
      final items = <MontyValue>[];
      final x = MontyList(items);
      items.add(x);

      return x;
    }

    final [c1, c2] = List.generate(2, (_) => selfList());
    // Three equal keys, distinct objects, so only an identity map keeps them.
    final keys = List.generate(3, (_) => String.fromCharCodes([107]));
    MontyClassProxy build() => montyClassProxy(
      classType: montyClassTypeProxy(
        name: 'C',
        id: 'c',
        hostDefined: false,
        isDataclass: false,
        attrs: const {},
      ),
      instanceId: 'i',
      attrs: Map.identity()
        ..addEntries([
          for (final (i, v) in [const MontyInt(0), c1, c2].indexed)
            MapEntry(keys.elementAtOrNull(i) ?? '', v),
        ]),
    );
    final [a, b] = List.generate(2, (_) => build());
    final forced = ValueGraphBudget(maxDepth: 0, maxVisits: 0);
    final fast = a == b;
    expect(forced.run(() => a == b), fast);
    expect(fast, isTrue);
  });

  test('a repeated attribute key: only the surviving value is projected', () {
    final items = <MontyValue>[];
    final cyclic = MontyList(items);
    items.add(cyclic);
    final i = montyClassProxy(
      classType: montyClassTypeProxy(
        name: 'C',
        id: 'c',
        hostDefined: false,
        isDataclass: false,
        attrs: const {},
      ),
      instanceId: 'i',
      attrs: Map.identity()
        ..[String.fromCharCodes([107])] = cyclic
        ..[String.fromCharCodes([107])] = const MontyInt(1),
    );
    final want = json.encode(referenceToJson(i));
    expect(want, contains('"attrs":{"__type":"dict","value":{"k":1}}'));
    expect(json.encode(i.toJson()), want);
    final forced = ValueGraphBudget(maxDepth: 0, maxVisits: 0);
    expect(forced.run(() => json.encode(MontyList([i]).toJson())), '[$want]');
  });

  test('a duplicate string key: only the surviving value is projected', () {
    // The overwritten value cannot become a DateTime; the old projection
    // never built it, because the keys collapsed first.
    const d = MontyDict([
      (
        MontyString('k'),
        MontyList([MontyDate(year: 300000, month: 1, day: 1)]),
      ),
      (MontyString('k'), MontyInt(1)),
    ]);
    expect(referenceDartValue(d), {'k': 1});
    expect(d.dartValue, {'k': 1});
    final forced = ValueGraphBudget(maxDepth: 0, maxVisits: 0);
    expect(forced.run(() => const MontyList([d]).dartValue), [
      {'k': 1},
    ]);
  });

  test('a set holding one self-containing value: both paths agree', () {
    final items = <MontyValue>[];
    final x = MontyList(items);
    items.add(x);
    final [a, b] = List.generate(2, (_) => MontySet([x]));
    final [c, d] = List.generate(2, (_) => MontyDict([(x, const MontyInt(1))]));
    final forced = ValueGraphBudget(maxDepth: 0, maxVisits: 0);
    // The element is the same object on both sides, so no hash is needed.
    expect(a == b, isTrue);
    expect(forced.run(() => a == b), isTrue);
    expect(c == d, isTrue);
    expect(forced.run(() => c == d), isTrue);
    expect(forced.fallbacks, 2);
  });

  group('repeats collapse without unbounded work', () {
    test('a 5,000-deep chain of sets whose two members are equal', () {
      // Each level holds two distinct, equal sets of the level below: the
      // fallback collapses them by canonical id, iteratively, in linear
      // time, where comparing each pair afresh doubled per level.
      MontyFrozenSet chain() {
        MontyValue a = const MontyInt(1);
        MontyValue b = MontyBigInt(BigInt.one);
        for (var i = 0; i < 5000; i++) {
          final next = MontyFrozenSet([a, b]);
          b = MontyFrozenSet([b, a]);
          a = next;
        }

        return a as MontyFrozenSet;
      }

      final x = chain();
      final y = chain();
      final watch = Stopwatch()..start();
      expect(x == y, isTrue);
      expect(x.hashCode, y.hashCode);
      expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
    });

    test('an overwritten dict value is never read, on either path', () {
      final cyclic = MontyDict([
        (const MontyString('k'), _selfList()),
        (const MontyString('k'), const MontyInt(1)),
      ]);
      const clean = MontyDict([(MontyString('k'), MontyInt(1))]);
      final forced = ValueGraphBudget(maxDepth: 0, maxVisits: 0);
      expect(cyclic == clean, isTrue);
      expect(forced.run(() => cyclic == clean), isTrue);
      expect(cyclic.hashCode, clean.hashCode);
      expect(forced.run(() => cyclic.hashCode), clean.hashCode);
      expect(forced.fallbacks, 2);
    });

    test('an overwritten attribute value is never read, on either path', () {
      final k1 = String.fromCharCodes([107]);
      final k2 = String.fromCharCodes([107]);
      final type = montyClassTypeProxy(
        name: 'C',
        id: 'c',
        hostDefined: false,
        isDataclass: false,
        attrs: const {},
      );
      MontyClassProxy inst(Map<String, MontyValue> attrs) =>
          montyClassProxy(classType: type, instanceId: 'i', attrs: attrs);
      final repeated = inst(
        Map.identity()
          ..[k1] = _selfList()
          ..[k2] = const MontyInt(1),
      );
      final clean = inst(const {'k': MontyInt(1)});
      final forced = ValueGraphBudget(maxDepth: 0, maxVisits: 0);
      expect(repeated == clean, isTrue);
      expect(forced.run(() => repeated == clean), isTrue);
      expect(repeated.hashCode, clean.hashCode);
      expect(forced.run(() => repeated.hashCode), clean.hashCode);
    });

    test("both attribute maps' names are charged before they are read", () {
      final type = montyClassTypeProxy(
        name: 'C',
        id: 'c',
        hostDefined: false,
        isDataclass: false,
        attrs: const {},
      );
      final empty = montyClassProxy(
        classType: type,
        instanceId: 'i',
        attrs: const {},
      );
      final wide = montyClassProxy(
        classType: type,
        instanceId: 'i',
        attrs: {for (var i = 0; i < 10000; i++) 'a$i': const MontyInt(1)},
      );
      final budget = ValueGraphBudget(maxVisits: 10);
      expect(budget.run(() => empty == wide), isFalse);
      expect(budget.fallbacks, 1);
    });
  });
}

/// A list that holds itself.
MontyList _selfList() {
  final items = <MontyValue>[];
  final x = MontyList(items);
  items.add(x);

  return x;
}
