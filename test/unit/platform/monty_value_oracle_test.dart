// The value family's equality against upstream's, recorded from
// pydantic-monty 1.1.0 by tool/generate_value_oracle.py
// (_value_oracle.g.dart): the numeric tower (bool, int, big int, float and
// complex compare and hash as one), named tuples as tuples, sets with
// frozensets, aware datetimes and times by instant, time zones by offset,
// paths as PurePosixPath, and caller-built sets and dicts collapsing equal
// members as Python's constructors do (C5D q4, AGY1 Q7, Q41, Q53).
//
// Each pair is checked both ways (symmetry) and on the fast and the
// memoised path; an equal pair must hash equal. NaN is the one recorded
// divergence: Dart's == is reflexive for it, so a value holding NaN can be a
// map key.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/value_graph_budget.dart';
import 'package:test/test.dart';

import '_value_oracle.g.dart';

/// a == b on both paths, which must agree.
bool eqBothPaths(MontyValue a, MontyValue b) {
  final fast = a == b;
  final wrappedFast = MontyList([a]) == MontyList([b]);
  final forced = ValueGraphBudget(maxVisits: 0);
  final slow = forced.run(() => MontyList([a]) == MontyList([b]));
  expect(wrappedFast, fast, reason: 'a list of each disagrees with ==');
  expect(slow, fast, reason: 'the fallback disagrees with the fast path');

  return fast;
}

/// Both hash paths of [v]: its own hashCode and, wrapped, the fallback's.
int hashOf(MontyValue v) {
  final forced = ValueGraphBudget(maxVisits: 0);
  final slow = forced.run(() => MontyList([v]).hashCode);
  expect(slow, MontyList([v]).hashCode, reason: 'the fallback hash differs');

  return v.hashCode;
}

double _float(Object? text) => switch (text) {
  'nan' => double.nan,
  'inf' => double.infinity,
  '-inf' => double.negativeInfinity,
  _ => double.parse('$text'),
};

/// An integer as the reader builds it: MontyInt within 2^53, else
/// MontyBigInt, so the value is the same on every compiler.
MontyValue _int(String digits) {
  final big = BigInt.parse(digits);

  return big.abs() <= BigInt.two.pow(53)
      ? MontyInt(big.toInt())
      : MontyBigInt(big);
}

MontyValue build(Object? spec) => switch (spec) {
  ['bool', final bool b] => MontyBool(b),
  ['int', final String d] => _int(d),
  ['float', final t] => MontyFloat(_float(t)),
  ['complex', final re, final im] => MontyComplex(_float(re), _float(im)),
  ['str', final String s] => MontyString(s),
  ['list', final List<Object?> xs] => MontyList(_all(xs)),
  ['tuple', final List<Object?> xs] => MontyTuple(_all(xs)),
  [
    'namedtuple',
    final String name,
    final List<Object?> fields,
    final List<Object?> xs,
  ] =>
    MontyNamedTuple(
      typeName: name,
      fieldNames: [for (final f in fields) '$f'],
      values: _all(xs),
    ),
  ['set', final List<Object?> xs] => MontySet(_all(xs)),
  ['frozenset', final List<Object?> xs] => MontyFrozenSet(_all(xs)),
  ['dict', final List<Object?> pairs] => MontyDict([
    for (final [k, v] in pairs.cast<List<Object?>>()) (build(k), build(v)),
  ]),
  ['tz', final int offset, final String? name] => MontyTimeZone(
    offsetSeconds: offset,
    name: name,
  ),
  [
    'dt',
    final int y,
    final int mo,
    final int d,
    final int h,
    final int mi,
    final int s,
    final int us,
    final int? offset,
    final String? name,
  ] =>
    MontyDateTime(
      year: y,
      month: mo,
      day: d,
      hour: h,
      minute: mi,
      second: s,
      microsecond: us,
      offsetSeconds: offset,
      timezoneName: name,
    ),
  [
    'time',
    final int h,
    final int mi,
    final int s,
    final int us,
    final int? offset,
    final int fold,
  ] =>
    MontyTime(
      hour: h,
      minute: mi,
      second: s,
      microsecond: us,
      offsetSeconds: offset,
      fold: fold,
    ),
  ['path', final String p] => MontyPath(p),
  _ => throw ArgumentError.value(spec, 'spec'),
};

List<MontyValue> _all(List<Object?> specs) => [
  for (final s in specs) build(s),
];

/// The pairs Python calls unequal (NaN is not equal to itself) where Dart's
/// reflexive NaN, and a zero-imaginary complex comparing as its real part,
/// make them equal: the recorded divergence.
const Set<(String, String)> nanDivergence = {
  ('float_nan', 'float_nan'),
  ('float_nan', 'complex_nan'),
  ('complex_nan', 'complex_nan'),
  ('complex_nan_imag', 'complex_nan_imag'),
};

void main() {
  group('equality as upstream records it', () {
    for (final (a, b, relation) in valueEqualities) {
      final python = relation.startsWith('eq');
      final dart = python || nanDivergence.contains((a, b));
      test('$a vs $b: ${dart ? 'equal' : 'unequal'}'
          '${dart != python ? ' (NaN divergence C-10)' : ''}', () {
        final x = build(valueSpecs[a]);
        final y = build(valueSpecs[b]);
        expect(eqBothPaths(x, y), dart, reason: '$a == $b');
        expect(eqBothPaths(y, x), dart, reason: '$b == $a (symmetry)');
        if (dart) {
          expect(hashOf(x), hashOf(y), reason: 'equal values hash equal');
        }
      });
    }
  });

  group('MontyPath normalises as PurePosixPath', () {
    for (final MapEntry(key: text, value: normal) in pathOracle.entries) {
      test('${text.isEmpty ? '(empty)' : text} -> $normal', () {
        expect(MontyPath(text).value, normal);
        expect(MontyPath(text), MontyPath(normal));
      });
    }
  });
}
