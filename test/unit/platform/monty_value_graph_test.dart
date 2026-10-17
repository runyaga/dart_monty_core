// Shared, deep, wide and cyclic values through ==, hashCode, toJson,
// dartValue and fromDart.
//
// Before the identity-aware walk each of the shared and deep cases hung or
// overflowed the stack: a value shared d times over cost 2^d, and 10,000
// levels of nesting overflowed on the VM (2,000 on dart2js). The expected
// answers come from how each value is built (two independent builds of the
// same recipe are equal; a different leaf makes them unequal), never from
// running the code under test.
//
// The time bounds are loose on purpose, 100x or more above what the walk takes
// on a laptop, so that only a return to exponential or quadratic work trips
// them. The public API is all these tests touch.
@Timeout(Duration(minutes: 5))
library;

import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show
        MontyClassProxyInternal,
        MontyValueInternal,
        montyClassProxy,
        montyClassTypeProxy;
import 'package:test/test.dart';

/// x0 = leaf; x(k+1) = [xk, xk]: d+1 distinct nodes, 2^(d+1)-1 tree nodes.
MontyValue chain(int d, {MontyValue leaf = const MontyInt(1)}) {
  var v = leaf;
  for (var i = 0; i < d; i++) {
    v = MontyList([v, v]);
  }

  return v;
}

/// [[[...[leaf]...]]], d lists deep, nothing shared.
MontyValue nested(int d, {MontyValue leaf = const MontyInt(1)}) {
  var v = leaf;
  for (var i = 0; i < d; i++) {
    v = MontyList([v]);
  }

  return v;
}

/// Runs [f], failing if it takes longer than [limit].
T within<T>(Duration limit, T Function() f) {
  final sw = Stopwatch()..start();
  final r = f();
  sw.stop();
  expect(
    sw.elapsed,
    lessThan(limit),
    reason: 'took ${sw.elapsedMilliseconds} ms',
  );

  return r;
}

const _fast = Duration(seconds: 5);
const _slow = Duration(seconds: 20);

/// Follows `[x]` or `[x, x]` lists down to the leaf, without recursion.
(int, Object?) descend(Object? json) {
  var depth = 0;
  var v = json;
  while (v is List<Object?>) {
    depth++;
    v = v.firstOrNull;
  }

  return (depth, v);
}

/// Deep equality of two toJson outputs, without recursion.
bool sameJson(Object? a, Object? b) {
  final stack = [(a, b)];
  while (stack.isNotEmpty) {
    final (x, y) = stack.removeLast();
    if (x is List<Object?> && y is List<Object?>) {
      if (x.length != y.length) return false;
      final ys = y.iterator;
      for (final e in x) {
        ys.moveNext();
        stack.add((e, ys.current));
      }
    } else if (x is Map<String, Object?> && y is Map<String, Object?>) {
      if (x.length != y.length) return false;
      for (final MapEntry(:key, :value) in x.entries) {
        if (!y.containsKey(key)) return false;
        stack.add((value, y[key]));
      }
    } else if (x != y) {
      return false;
    }
  }

  return true;
}

/// Two independent builds from one recipe.
(T, T) two<T>(T Function() build) => (build(), build());

void main() {
  group('a value shared 10,000 times over (2^10000 tree nodes)', () {
    const d = 10000;

    test('== on two independent builds is true', () {
      expect(within(_fast, () => chain(d) == chain(d)), isTrue);
    });

    test('== against a different leaf is false', () {
      final other = chain(d, leaf: const MontyInt(2));
      expect(within(_fast, () => chain(d) == other), isFalse);
      expect(within(_fast, () => chain(d) == chain(d - 1)), isFalse);
    });

    test('hashCode agrees between two independent builds', () {
      final a = within(_fast, () => chain(d).hashCode);
      expect(within(_fast, () => chain(d).hashCode), a);
    });

    test('toJson and dartValue build each shared node once', () {
      for (final project in [
        (MontyValue v) => v.toJson(),
        (MontyValue v) => v.dartValue,
      ]) {
        final out = within(_fast, () => project(chain(d)));
        if (out case [final first, final second]) {
          expect(first, same(second));
        } else {
          fail('expected a two-element list, got $out');
        }
        expect(descend(out), (d, 1));
      }
    });
  });

  group('100,000 levels of nesting', () {
    const d = 100000;

    test('== is true for equal values, false for a different leaf', () {
      expect(within(_slow, () => nested(d) == nested(d)), isTrue);
      final other = nested(d, leaf: const MontyInt(2));
      expect(within(_slow, () => nested(d) == other), isFalse);
    });

    test('hashCode agrees between two independent builds', () {
      final a = within(_slow, () => nested(d).hashCode);
      expect(within(_slow, () => nested(d).hashCode), a);
    });

    test('toJson and dartValue keep every level', () {
      expect(descend(within(_slow, () => nested(d).toJson())), (d, 1));
      expect(descend(within(_slow, () => nested(d).dartValue)), (d, 1));
    });

    test('a tuple, set, dict, named tuple and instance nest as deep', () {
      MontyValue build(MontyValue leaf) {
        var v = leaf;
        for (var i = 0; i < d; i++) {
          v = switch (i % 5) {
            0 => MontyTuple([v]),
            1 => MontyFrozenSet([
              MontyTuple([v]),
            ]),
            2 => MontyDict([(const MontyString('k'), v)]),
            3 => MontyNamedTuple(
              typeName: 'P',
              fieldNames: const ['x'],
              values: [v],
            ),
            _ => montyClassProxy(
              classType: listType2,
              instanceId: 'i',
              attrs: {'x': v},
            ),
          };
        }

        return v;
      }

      final a = build(const MontyInt(1));
      final b = build(const MontyInt(1));
      expect(within(_slow, () => a == b), isTrue);
      expect(within(_slow, () => a == build(const MontyInt(2))), isFalse);
      expect(within(_slow, () => a.hashCode), b.hashCode);
      // json.encode recurses, so the outputs are compared iteratively.
      expect(
        sameJson(within(_slow, a.toJson), within(_slow, b.toJson)),
        isTrue,
      );
      within(_slow, () => a.dartValue);
    });
  });

  group('100,000 elements', () {
    const n = 100000;
    MontySet ints({int bump = -1, bool reversed = false}) => MontySet([
      for (var i = 0; i < n; i++) MontyInt(reversed ? n - 1 - i : i),
      if (bump >= 0) MontyInt(n + bump),
    ]);

    test('sets compare in either order, without a quadratic scan', () {
      final (x, y) = two(ints);
      final reversed = ints(reversed: true);
      expect(within(_fast, () => x == y), isTrue);
      expect(within(_fast, () => x == reversed), isTrue);
      final other = MontySet([...x.items.skip(1), const MontyInt(n)]);
      expect(within(_fast, () => reversed == other), isFalse);
      expect(x.hashCode, reversed.hashCode);
    });

    test('dicts compare in either order', () {
      MontyDict dict({required bool reversed}) => MontyDict([
        for (var i = 0; i < n; i++)
          (
            MontyString('k${reversed ? n - 1 - i : i}'),
            MontyInt(reversed ? n - 1 - i : i),
          ),
      ]);
      final (x, y) = two(() => dict(reversed: false));
      final reversed = dict(reversed: true);
      expect(within(_fast, () => x == y), isTrue);
      expect(within(_fast, () => x == reversed), isTrue);
      expect(x.hashCode, reversed.hashCode);
    });
  });

  group('one large leaf referenced 100,000 times', () {
    const n = 100000;
    const size = 1 << 20;

    List<MontyValue> refs(MontyValue leaf) => List.filled(n, leaf);

    test('bytes: hashed and compared once, not 100,000 times', () {
      final (a, b) = two(
        () => MontyList(refs(MontyBytes(List.filled(size, 7)))),
      );
      final c = MontyList(refs(MontyBytes(List.filled(size, 8))));
      expect(within(_slow, () => a.hashCode), within(_slow, () => b.hashCode));
      expect(within(_slow, () => a == b), isTrue);
      expect(within(_slow, () => a == c), isFalse);
    });

    test('a path and an exception message', () {
      // 4 MiB: the VM compares long strings fast enough that 1 MiB did not
      // separate the old walk from the new one.
      const text = size << 2;
      for (final make in [
        () => MontyPath('p' * text),
        () => MontyExceptionValue('ValueError', 'm' * text),
      ]) {
        final (a, b) = two(() => MontyList(refs(make())));
        expect(within(_fast, () => a == b), isTrue);
        expect(within(_fast, () => a.hashCode), b.hashCode);
      }
    });
  });

  group('cycles a host builds', () {
    MontyList selfList() {
      final items = <MontyValue>[];
      final x = MontyList(items);
      items.add(x);

      return x;
    }

    test('a value that contains itself equals itself', () {
      final x = selfList();
      expect(x == x, isTrue);
      // Its children are compared by identity first, as Python does.
      expect(MontyList([x]) == MontyList([x]), isTrue);
    });

    test('two distinct self-containing lists: == throws StateError', () {
      expect(() => selfList() == selfList(), throwsStateError);
    });

    test('hashCode, toJson and dartValue throw StateError', () {
      final x = selfList();
      expect(() => x.hashCode, throwsStateError);
      expect(x.toJson, throwsStateError);
      expect(() => x.dartValue, throwsStateError);
    });

    test('through a dict and through instance attributes', () {
      final pairs = <(MontyValue, MontyValue)>[];
      final d = MontyDict(pairs);
      pairs.add((const MontyString('self'), d));
      expect(() => d.hashCode, throwsStateError);
      expect(d.toJson, throwsStateError);

      final attrs = <String, MontyValue>{};
      final i = montyClassProxy(
        classType: montyClassTypeProxy(
          name: 'C',
          id: 'c',
          hostDefined: false,
          isDataclass: false,
          attrs: {},
        ),
        instanceId: 'i',
        attrs: attrs,
      );
      attrs['me'] = i;
      expect(() => i.hashCode, throwsStateError);
      expect(() => i.dartAttrs, throwsStateError);
      expect(i.toString(), 'MontyClassProxy(C, 1 attrs)');
    });

    test('non-identical cyclic instances refuse an in-progress comparison', () {
      MontyClassProxy loop(String id) {
        final attrs = <String, MontyValue>{};
        final instance = montyClassProxy(
          classType: listType2,
          instanceId: id,
          attrs: attrs,
        );
        attrs['self'] = instance;

        return instance;
      }

      expect(() => loop('a') == loop('b'), throwsStateError);
    });

    test('a difference before a cyclic attribute decides equality', () {
      MontyClassProxy loop(String id, int value) {
        final attrs = <String, MontyValue>{'value': MontyInt(value)};
        final instance = montyClassProxy(
          classType: listType2,
          instanceId: id,
          attrs: attrs,
        );
        attrs['self'] = instance;

        return instance;
      }

      expect(loop('a', 1) == loop('b', 2), isFalse);
    });

    test('a cyclic instance remains equal to itself', () {
      final attrs = <String, MontyValue>{};
      final instance = montyClassProxy(
        classType: listType2,
        instanceId: 'self',
        attrs: attrs,
      );
      attrs['self'] = instance;

      expect(instance == instance, isTrue);
    });

    test(
      'a cyclic instance cannot project its attributes or class metadata',
      () {
        final directAttrs = <String, MontyValue>{};
        final direct = montyClassProxy(
          classType: listType2,
          instanceId: 'direct',
          attrs: directAttrs,
        );
        directAttrs['self'] = direct;
        expect(() => direct.dartValue, throwsStateError);

        final classAttrs = <String, MontyValue>{};
        final classType = montyClassTypeProxy(
          name: 'C',
          id: 'metadata',
          hostDefined: false,
          isDataclass: false,
          attrs: classAttrs,
        );
        final throughMetadata = montyClassProxy(
          classType: classType,
          instanceId: 'metadata',
          attrs: const {},
        );
        classAttrs['instance'] = throughMetadata;
        expect(() => throughMetadata.dartValue, throwsStateError);
      },
    );
  });

  group('colliding set elements, 5,000 levels deep', () {
    // MontyInt(k) and MontyFloat(k) hash alike and are unequal, so each level
    // holds two colliding tuples. The two builds list them in opposite
    // orders, so the first candidate tried at every level is the wrong one.
    MontyValue build(int depth, {required bool flip, int leaf = 0}) {
      MontyValue v = MontyInt(leaf);
      for (var k = 0; k < depth; k++) {
        final i = MontyTuple([v, MontyInt(k)]);
        final f = MontyTuple([v, MontyFloat(k.toDouble())]);
        v = MontyFrozenSet(flip ? [f, i] : [i, f]);
      }

      return v;
    }

    test('equal builds compare equal; a different leaf does not', () {
      expect(
        within(
          _fast,
          () => build(5000, flip: false) == build(5000, flip: true),
        ),
        isTrue,
      );
      final other = build(5000, flip: true, leaf: 1);
      expect(within(_fast, () => build(5000, flip: false) == other), isFalse);
      expect(
        build(5000, flip: false).hashCode,
        build(5000, flip: true).hashCode,
      );
    });
  });

  test('crafted collisions stay quadratic (recorded residual, C2 Q4)', () {
    // 2^10 tuples of ten numbers, each an int or the equal-hashing float:
    // pairwise unequal, all one hash. Matching them is quadratic in the bucket.
    // This records the cost; it is not a guarantee.
    List<MontyValue> tuples({required bool reversed}) {
      final out = <MontyValue>[
        for (var mask = 0; mask < 1024; mask++)
          MontyTuple([
            for (var b = 0; b < 10; b++)
              if (mask & (1 << b) == 0)
                MontyInt(b)
              else
                MontyFloat(b.toDouble()),
          ]),
      ];

      return reversed ? out.reversed.toList() : out;
    }

    final a = MontySet(tuples(reversed: false));
    final b = MontySet(tuples(reversed: true));
    final sw = Stopwatch()..start();
    expect(a == b, isTrue);
    printOnFailure('1024 colliding elements: ${sw.elapsedMilliseconds} ms');
    expect(sw.elapsed, lessThan(const Duration(seconds: 60)));
  });

  group('projections share what the value shares', () {
    final listType = montyClassTypeProxy(
      name: 'C',
      id: 'c',
      hostDefined: false,
      isDataclass: false,
      attrs: const {},
    );

    test('a shared list is one object in toJson and in dartValue', () {
      const x = MontyList([MontyInt(1)]);
      const v = MontyList([
        x,
        MontyTuple([x]),
      ]);
      final [j0, j1] = _jsonList(v);
      expect(j1, {
        '__type': 'tuple',
        'value': [same(j0)],
      });
      final [d0, d1] = v.dartValue;
      expect(d1, [same(d0)]);
    });

    test('across named tuples, which project to their toJson map', () {
      const x = MontyList([MontyInt(1)]);
      MontyNamedTuple nt() =>
          // Two distinct named tuples holding the one list: `const` would
          // make them one object and the test trivial.
          // ignore: prefer_const_constructors
          MontyNamedTuple(
            typeName: 'P',
            fieldNames: const ['x'],
            values: const [x],
          );
      final a = nt();
      final b = nt();
      expect(a, isNot(same(b)));
      final [n0, n1] = MontyList([a, b]).dartValue;
      final shared = switch (n0) {
        {'values': [final first]} => first,
        _ => fail('expected a named tuple map, got $n0'),
      };
      expect(n1, containsPair('values', [same(shared)]));
    });

    test('dartAttrs keeps one object for a shared attribute value', () {
      const x = MontyList([MontyInt(1)]);
      final i = montyClassProxy(
        classType: listType,
        instanceId: 'i',
        attrs: const {'a': x, 'b': x},
      );
      final attrs = i.dartAttrs;
      expect(attrs['a'], same(attrs['b']));
      expect(attrs, {
        'a': [1],
        'b': [1],
      });
    });

    test('two instances of one class share its class_type map', () {
      MontyClassProxy inst(String id) => montyClassProxy(
        classType: listType,
        instanceId: id,
        attrs: const {},
      );
      final [i0, i1] = _jsonList(MontyList([inst('1'), inst('2')]));
      final classType = switch (i0) {
        {'class_type': final ct} => ct,
        _ => fail('expected an instance map, got $i0'),
      };
      expect(i1, containsPair('class_type', same(classType)));
    });

    test('a standalone class and its instance share the class_type map', () {
      final instance = montyClassProxy(
        classType: listType,
        instanceId: 'i',
        attrs: const {},
      );
      final [standalone, projectedInstance] = _jsonList(
        MontyList([listType, instance]),
      );
      final classType = switch (projectedInstance) {
        {'class_type': final value} => value,
        _ => fail('expected an instance map, got $projectedInstance'),
      };
      expect(classType, same(standalone));
    });

    test('json.encode still expands the shared output into a tree', () {
      const x = MontyList([MontyInt(1)]);
      expect(json.encode(const MontyList([x, x]).toJson()), '[[1],[1]]');
    });
  });

  test(
    'MontyClassProxy.toString shows the name and the attribute count',
    () {
      final i = montyClassProxy(
        classType: listType2,
        instanceId: 'i',
        attrs: {'big': chain(10000), 'deep': nested(100000)},
      );
      expect(within(_fast, i.toString), 'MontyClassProxy(Point, 2 attrs)');
    },
  );

  test('a dict of 200,000 copies of one pair compares in linear time', () {
    // One hash bucket holding every pair: matching must not shift the bucket
    // once per match.
    MontyDict build() => MontyDict(
      List.filled(200000, (const MontyString('k'), const MontyInt(1))),
    );
    final (a, b) = two(build);
    expect(within(_fast, () => a == b), isTrue);
  });

  test('a shared leaf projects to one object too', () {
    const date = MontyDate(year: 2024, month: 1, day: 2);
    const float = MontyFloat(1);
    for (final leaf in [date, float, const MontyEllipsis()]) {
      final [j0, j1] = _jsonList(MontyList([leaf, leaf]));
      expect(j0, same(j1), reason: '$leaf toJson');
    }
    final [d0, d1] = const MontyList([date, date]).dartValue;
    expect(d0, same(d1));
  });

  group('MontyValue.fromDart', () {
    test('any Dart object reached twice becomes one value', () {
      final at = DateTime.utc(2024);
      final text = String.fromCharCodes([97, 98]);
      final got =
          MontyValue.fromDart([at, at, text, text, 7, 7, true, true, 1.5, 1.5])
              as MontyList;
      final items = got.items;
      for (var i = 0; i < 5; i++) {
        expect(
          items.elementAtOrNull(i * 2),
          same(items.elementAtOrNull(i * 2 + 1)),
          reason: 'pair $i',
        );
      }
      expect(items, hasLength(10));
    });

    test('100,000 levels of nesting convert without recursion', () {
      Object? v = 1;
      for (var i = 0; i < 100000; i++) {
        v = [v];
      }
      final got = within(_slow, () => MontyValue.fromDart(v));
      expect(got == nested(100000), isTrue);
    });

    test('a List or Map reached twice becomes one shared value', () {
      final inner = [1, 2];
      final map = {'k': inner};
      final got = MontyValue.fromDart([inner, inner, map, map]) as MontyList;
      final [l0, l1, m0, m1] = got.items;
      expect(l0, same(l1));
      expect(m0, same(m1));
      final MontyDict(pairs: [(_, shared)]) = m0 as MontyDict;
      expect(shared, same(l0));
    });

    test('a Dart value shared 10,000 times over converts in linear time', () {
      Object? v = 1;
      for (var i = 0; i < 10000; i++) {
        v = [v, v];
      }
      final got = within(_fast, () => MontyValue.fromDart(v));
      expect(got == chain(10000), isTrue);
    });

    test('a List or Map that contains itself is an ArgumentError', () {
      final l = <Object?>[];
      l.add(l);
      expect(() => MontyValue.fromDart(l), throwsArgumentError);
      final m = <String, Object?>{};
      m['m'] = [m];
      expect(() => MontyValue.fromDart(m), throwsArgumentError);
    });

    test('-0.0 and both infinities become MontyFloat on every backend', () {
      // On dart2js all three pass `is int`; -0.0 became MontyInt(0).
      final isFloat = isA<MontyFloat>();
      final negZero = MontyValue.fromDart(-0.0);
      expect(negZero, isFloat);
      expect((negZero as MontyFloat).value.isNegative, isTrue);
      expect(MontyValue.fromDart(double.infinity), isFloat);
      expect(MontyValue.fromDart(double.negativeInfinity), isFloat);
      expect(MontyValue.fromDart([-0.0]), const MontyList([MontyFloat(-0)]));
      // The callback-return path converts through fromDart.
      expect(
        json.encode(MontyValue.fromDart(-0.0).toJson()),
        '{"__type":"float","value":"-0.0"}',
      );
      expect(
        json.encode(MontyValue.fromDart(double.negativeInfinity).toJson()),
        '{"__type":"float","value":"-Infinity"}',
      );
    });

    test('a repeated zero becomes one value too', () {
      for (final zero in [0, 0.0, -0.0]) {
        final got = MontyValue.fromDart([zero, zero]) as MontyList;
        final [first, second] = got.items;
        expect(first, same(second), reason: '$zero');
      }
    });

    test('0 and -0.0 in one list keep their own types, in either order', () {
      // dart2js treats 0 and -0.0 as one identity-map key.
      for (final input in [
        [0, -0.0],
        [-0.0, 0],
      ]) {
        final got = MontyValue.fromDart(input) as MontyList;
        final kinds = [
          for (final v in got.items)
            if (v is MontyFloat) 'float ${v.value.isNegative}' else '$v',
        ];
        expect(kinds, [
          for (final n in input)
            if (n == 0 && n.isNegative) 'float true' else 'MontyInt(0)',
        ]);
      }
    });

    test('a DateTime keeps its milliseconds', () {
      final got =
          MontyValue.fromDart(DateTime.utc(2026, 4, 28, 15, 30, 45, 678, 123))
              as MontyDateTime;
      expect(got.microsecond, 678123);
    });

    test('an unsupported element is still an ArgumentError', () {
      expect(() => MontyValue.fromDart([Object()]), throwsArgumentError);
      expect(() => MontyValue.fromDart({Object(): 1}), throwsArgumentError);
    });
  });
}

final MontyClassTypeProxy listType2 = montyClassTypeProxy(
  name: 'Point',
  id: 'p',
  hostDefined: false,
  isDataclass: false,
  attrs: const {},
);

/// [v]'s toJson projection, which these cases build as a list.
List<Object?> _jsonList(MontyValue v) => switch (v.toJson()) {
  final List<Object?> list => list,
  final other => throw StateError('toJson is not a list: $other'),
};
