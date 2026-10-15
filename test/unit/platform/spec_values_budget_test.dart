// Spec-requirement tests for the equality and hashing budget of MontyValue
// graphs (T-values): 400 levels, 2^22 visits, the charge for variable-length
// leaf payloads, and the memoised fallback that must not change a result.
// Each test name starts with the REQ id it asserts.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/value_graph_budget.dart';
import 'package:test/test.dart';

import 'spec_values_support.dart';

int _n(int v) => v;
String _s(String v) => v;

typedef _Wrap = MontyValue Function(MontyValue);

final Map<String, _Wrap> _kinds = {
  'list': (v) => MontyList([v]),
  'tuple': (v) => MontyTuple([v]),
  'set': (v) => MontySet([v]),
  'frozenset': (v) => MontyFrozenSet([v]),
  'dict': (v) => MontyDict([(const MontyString('k'), v)]),
};

/// How many walks fell back to the memoised walk while running [f] under the
/// given limits (the defaults unless named).
int _fallbacks(
  void Function() f, {
  int maxDepth = ValueGraphBudget.defaultMaxDepth,
  int maxVisits = ValueGraphBudget.defaultMaxVisits,
}) {
  final budget = ValueGraphBudget(maxDepth: maxDepth, maxVisits: maxVisits)
    ..run(f);

  return budget.fallbacks;
}

/// The least visit budget under which [f] never falls back: what [f] costs.
int _visits(void Function() f) {
  var lo = 0;
  var hi = 1 << 22;
  while (lo < hi) {
    final mid = (lo + hi) ~/ 2;
    if (_fallbacks(f, maxVisits: mid) == 0) {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }

  return lo;
}

MontyValue _nest(_Wrap wrap, int levels) {
  MontyValue v = const MontyInt(1);
  for (var i = 0; i < levels; i++) {
    v = wrap(v);
  }

  return v;
}

/// Every level holds two parents' worth of the same child: 2^levels visits as
/// a tree, linear in nodes as a graph.
MontyValue _dag(_Wrap wrap, int levels) {
  MontyValue v = const MontyInt(1);
  for (var i = 0; i < levels; i++) {
    final child = v;
    v = MontyList([wrap(child), wrap(child)]);
  }

  return v;
}

void _depthLimit(String kind) {
  final wrap = _kinds[kind]!;
  expect(ValueGraphBudget.defaultMaxDepth, 400);
  expect(ValueGraphBudget().maxDepth, 400);
  for (final levels in [399, 400]) {
    expect(_fallbacks(() => _nest(wrap, levels).hashCode), 0, reason: 'hash');
    expect(
      _fallbacks(() {
        final a = _nest(wrap, levels);
        final b = _nest(wrap, levels);
        expect(a == b, isTrue);
      }),
      0,
      reason: 'eq $levels',
    );
  }
  expect(_fallbacks(() => _nest(wrap, 401).hashCode), 1, reason: 'hash 401');
  expect(
    _fallbacks(() {
      final a = _nest(wrap, 401);
      final b = _nest(wrap, 401);
      expect(a == b, isTrue);
    }),
    1,
    reason: 'eq 401',
  );
  // Past the limit the result is the one the fast path would give.
  final (a, b) = twins(() => _nest(wrap, 401));
  expect(a.hashCode, b.hashCode);
  expect(a == _nest(wrap, 402), isFalse);
}

void _visitLimit(String kind) {
  final wrap = _kinds[kind]!;
  expect(ValueGraphBudget.defaultMaxVisits, 1 << 22);
  expect(ValueGraphBudget().maxVisits, 4194304);
  // 2^30 visits as a tree: only the fallback can finish this.
  final a = _dag(wrap, 30);
  final b = _dag(wrap, 30);
  expect(_fallbacks(() => a.hashCode), 1);
  expect(_fallbacks(() => expect(a == b, isTrue)), 1);
  expect(a.hashCode, b.hashCode);
  expect(a == _dag(wrap, 31), isFalse);
}

void _flatBoundary() {
  // One list visit plus one visit per element: 2^22 - 1 elements stay on the
  // fast path, 2^22 do not.
  final fits = MontyList(List.filled((1 << 22) - 1, const MontyInt(1)));
  final over = MontyList(List.filled(1 << 22, const MontyInt(1)));
  expect(_fallbacks(() => fits.hashCode), 0);
  expect(_fallbacks(() => over.hashCode), 1);
  expect(over.hashCode, isA<int>());
  // Comparing two lists costs the same: one visit for the pair of lists, one
  // for each pair of (here identical) elements.
  MontyList flat(int n) => MontyList(List.filled(n, const MontyInt(1)));
  expect(
    _fallbacks(
      () => expect(flat((1 << 22) - 1) == flat((1 << 22) - 1), isTrue),
    ),
    0,
  );
  expect(_fallbacks(() => expect(flat(1 << 22) == flat(1 << 22), isTrue)), 1);
}

void _charge(
  String kind,
  MontyValue Function(int n) leaf, {
  int? hashUnits,
}) {
  final wrap = _kinds[kind]!;
  int hashOf(int n) => _visits(() => wrap(leaf(n)).hashCode);
  int eqOf(int n) => _visits(() {
    final a = wrap(leaf(n));
    final b = wrap(leaf(n));
    expect(a == b, isTrue);
  });
  // The payload is charged once when hashing and for both sides when
  // comparing two distinct leaves.
  final hashDiff = hashOf(1000) - hashOf(0);
  final eqDiff = eqOf(1000) - eqOf(0);
  if (hashUnits != null) {
    expect(hashDiff, hashUnits, reason: 'hash');
    expect(eqDiff, hashUnits * 2, reason: 'eq');
  } else {
    // The statement says the payload counts, not at what rate.
    final positive = greaterThan(0);
    expect(hashDiff, positive, reason: 'hash');
    expect(eqDiff, positive, reason: 'eq');
  }
}

void main() {
  group('depth limit of 400 levels', () {
    test('REQ-MontyList-14: MontyList', () => _depthLimit('list'));
    test('REQ-MontySet-16: MontySet', () => _depthLimit('set'));
    test(
      'REQ-MontyFrozenSet-16: MontyFrozenSet',
      () => _depthLimit('frozenset'),
    );
    test('REQ-MontyDict-19: MontyDict', () => _depthLimit('dict'));
    test('REQ-MontyValue-20: every container kind', () {
      _kinds.keys.forEach(_depthLimit);
    });
    test('REQ-values-and-equality-69: depth restarts keep the result', () {
      _depthLimit('list');
      _depthLimit('dict');
      for (final kind in _kinds.keys) {
        final wrap = _kinds[kind]!;
        for (final levels in [5, 400, 401, 800]) {
          final fast = _nest(wrap, levels);
          final twin = _nest(wrap, levels);
          expect(fast == twin, isTrue, reason: '$kind $levels');
          expect(fast.hashCode, twin.hashCode, reason: '$kind $levels');
        }
      }
    });
  });

  group('visit limit of 2^22', () {
    test('REQ-MontyList-14: MontyList visits', () {
      _visitLimit('list');
      _flatBoundary();
    });
    test('REQ-MontySet-16: MontySet visits', () => _visitLimit('set'));
    test(
      'REQ-MontyFrozenSet-16: MontyFrozenSet visits',
      () => _visitLimit('frozenset'),
    );
    test('REQ-MontyDict-19: MontyDict visits', () => _visitLimit('dict'));
    test('REQ-MontyValue-20: switches to the explicit-stack walk', () {
      _kinds.keys.forEach(_visitLimit);
      _flatBoundary();
    });
    test('REQ-values-and-equality-69: both limits, same result', () {
      _visitLimit('list');
      _visitLimit('set');
      final forced = ValueGraphBudget(maxDepth: 0, maxVisits: 0);
      // Fresh values on every call: `const` twins would be one object, and
      // the walks would never compare anything.
      final samples = <MontyValue Function()>[
        () => MontyList([MontyInt(_n(1)), MontyString(_s('a'))]),
        () => MontyTuple([MontyFloat(_n(1) + 0.5), const MontyNone()]),
        () => MontySet([MontyInt(_n(3)), MontyInt(_n(1)), MontyInt(_n(2))]),
        () => MontyFrozenSet(List.generate(2, (_) => MontyInt(_n(2)))),
        () => MontyDict([
          for (final v in [1, 2]) (MontyString(_s('a')), MontyInt(_n(v))),
        ]),
        () => MontyNamedTuple(
          typeName: _s('P'),
          fieldNames: [_s('x')],
          values: [MontyInt(_n(1))],
        ),
        () => MontyList([
          MontySet([MontyInt(_n(1))]),
          MontyBytes([_n(1), _n(2)]),
        ]),
      ];
      for (final make in samples) {
        final a = make();
        final b = make();
        expect(identical(a, b), isFalse);
        late int fastHash;
        late bool fastEq;
        expect(
          _fallbacks(() {
            fastHash = a.hashCode;
            fastEq = a == b;
          }),
          0,
        );
        late int slowHash;
        late bool slowEq;
        forced.run(() {
          slowHash = a.hashCode;
          slowEq = a == b;
        });
        expect(slowHash, fastHash, reason: '$a');
        expect(slowEq, fastEq, reason: '$a');
        expect(fastEq, isTrue);
      }
      expect(forced.fallbacks, greaterThan(0));
      forced.run(() {
        expect(
          const MontyList([MontyInt(1)]) == const MontyList([MontyInt(2)]),
          isFalse,
        );
      });
    });
  });

  group('payload charges', () {
    MontyValue str(int n) => MontyString('x' * n);
    MontyValue big(int n) => MontyBigInt(BigInt.one << (n * 8));
    MontyValue bytes(int n) => MontyBytes(List.filled(n, 1));

    test('REQ-MontyBigInt-13: bitLength >> 9 per payload', () {
      // bitLength(1 << 8000) = 8001; 8001 >> 9 = 15.
      MontyValue leaf(int n) => MontyBigInt(BigInt.one << (n == 0 ? 0 : 8000));
      final hashDiff =
          _visits(() => MontyList([leaf(1)]).hashCode) -
          _visits(() => MontyList([leaf(0)]).hashCode);
      expect(hashDiff, 15);
      int eqOf(int n) => _visits(() {
        final a = MontyList([leaf(n)]);
        final b = MontyList([leaf(n)]);
        expect(a == b, isTrue);
      });
      expect(eqOf(1) - eqOf(0), 30);
      // Sub-512-bit integers are free.
      expect(
        _visits(() => MontyList([MontyBigInt(BigInt.one << 500)]).hashCode),
        _visits(() => MontyList([MontyBigInt(BigInt.one)]).hashCode),
      );
    });
    test(
      'REQ-MontyBytes-13: bytes payload is charged in hashing and equality',
      () {
        _charge('list', bytes);
        _charge('set', bytes);
      },
    );
    test('REQ-MontySet-17: set payloads count against the budget', () {
      _charge('set', str);
      _charge('set', big);
      _charge('set', bytes);
    });
    test('REQ-MontyList-14: list payloads count against the budget', () {
      _charge('list', str);
    });
    test(
      'REQ-MontyFrozenSet-16: frozenset payloads count against the budget',
      () {
        _charge('frozenset', str);
      },
    );
    test('REQ-MontyDict-19: dict payloads count against the budget', () {
      _charge('dict', str);
    });
  });
}
