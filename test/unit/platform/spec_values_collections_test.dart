// Spec-requirement tests for the collection members of the MontyValue family
// (T-values). Each test name starts with the REQ id it asserts.
// The ordering-operator test calls members that must not exist, so it calls
// them on a `dynamic` target.
// ignore_for_file: avoid_dynamic_calls
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show MontyValueInternal;
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

MontyValue _roundTrip(MontyValue value) {
  final writer = ArenaWriter();
  final root = writer.add(value);

  return ArenaReader(pb.Arena.fromBuffer(writer.arena.writeToBuffer()))[root];
}

int _n(int v) => v;

/// A fresh instance: a `const` twin would be the same object.
MontyBytes _bytes(List<int> v) => MontyBytes(v);

/// A fresh NaN each call: never const, so no two are one instance.
MontyFloat _nan() => MontyFloat(double.parse('NaN'));

/// A list that contains itself, as a cyclic caller-built value.
MontyList _cyclicList() {
  final items = <MontyValue>[];
  final list = MontyList(items);
  items.add(list);

  return list;
}

void main() {
  group('MontyBytes', () {
    test('REQ-MontyBytes-4: out-of-range ints are stored without error', () {
      const b = MontyBytes([300, -1, 0, 255, 256]);
      expect(b.value, [300, -1, 0, 255, 256]);
      expect(const MontyBytes([1 << 40]).value, [1 << 40]);
    });
    test('REQ-MontyBytes-5: dartValue is the same list instance', () {
      final list = [1, 2, 3];
      final b = MontyBytes(list);
      expect(identical(b.dartValue, list), isTrue);
      expect(identical(b.value, list), isTrue);
    });
    test(
      'REQ-MontyBytes-7: equal only for the same length, bytes and order',
      () {
        expect(_bytes([1, 2, 3]) == _bytes([1, 2, 3]), isTrue);
        expect(_bytes([]) == _bytes([]), isTrue);
        expect(_bytes([1, 2, 3]) == _bytes([3, 2, 1]), isFalse);
        expect(_bytes([1, 2, 3]) == _bytes([1, 2]), isFalse);
        expect(_bytes([1, 2]) == _bytes([1, 2, 3]), isFalse);
        expect(_bytes([1, 2, 3]) == _bytes([1, 2, 4]), isFalse);
        expect(_bytes([]) == _bytes([0]), isFalse);
        expect(_bytes([1]) == const MontyInt(1), isFalse);
        expect(_bytes([1, 2, 3]).hashCode, _bytes([1, 2, 3]).hashCode);
        expect(_bytes([]).hashCode, _bytes([]).hashCode);
        // The length and every byte take part in the hash (the statements do
        // not promise that two particular values differ).
        expect(
          {
            for (var n = 0; n < 12; n++) _bytes(List.filled(n, 7)).hashCode,
          }.length,
          greaterThan(1),
        );
        expect(
          {
            for (var v = 0; v < 12; v++) _bytes([1, 2, v]).hashCode,
          }.length,
          greaterThan(1),
        );
      },
    );
    test('REQ-MontyBytes-9: no ordering operators and no compareTo', () {
      const dynamic b = MontyBytes([1]);
      const dynamic c = MontyBytes([2]);
      expect(() => b < c, throwsNoSuchMethodError);
      expect(() => b <= c, throwsNoSuchMethodError);
      expect(() => b > c, throwsNoSuchMethodError);
      expect(() => b >= c, throwsNoSuchMethodError);
      expect(() => b.compareTo(c), throwsNoSuchMethodError);
    });
    test(
      'REQ-MontyBytes-14: caller mutation changes equality, hash, encoding',
      () {
        final list = [1, 2, 3];
        final b = MontyBytes(list);
        expect(b.hashCode, _bytes([1, 2, 3]).hashCode);
        expect(b == const MontyBytes([1, 2, 3]), isTrue);
        expect(_roundTrip(b), const MontyBytes([1, 2, 3]));

        list[1] = 9;
        expect(b == const MontyBytes([1, 2, 3]), isFalse);
        expect(b == const MontyBytes([1, 9, 3]), isTrue);
        expect(b.hashCode, const MontyBytes([1, 9, 3]).hashCode);
        expect(_roundTrip(b), const MontyBytes([1, 9, 3]));

        list.add(4);
        expect(b == const MontyBytes([1, 9, 3, 4]), isTrue);
        expect(_roundTrip(b), const MontyBytes([1, 9, 3, 4]));
      },
    );
    test('REQ-MontyBytes-15: fromDart returns an existing MontyBytes', () {
      final v = _bytes([1, 2]);
      expect(identical(MontyValue.fromDart(v), v), isTrue);
    });
    test('REQ-MontyBytes-17: MontyBytes(N bytes)', () {
      expect(const MontyBytes([]).toString(), 'MontyBytes(0 bytes)');
      expect(const MontyBytes([1]).toString(), 'MontyBytes(1 bytes)');
      expect(MontyBytes(List.filled(37, 7)).toString(), 'MontyBytes(37 bytes)');
    });
    test(
      'REQ-MontyBytes-25: invalid bytes are stored, refused on encoding',
      () {
        const bad = MontyBytes([1, 256]);
        expect(bad.value, [1, 256]);
        expect(() => ArenaWriter().add(bad), throwsArgumentError);
        expect(
          () => ArenaWriter().add(const MontyBytes([-1])),
          throwsArgumentError,
        );
        expect(
          () => ArenaWriter().add(const MontyList([bad])),
          throwsArgumentError,
        );
        expect(
          _roundTrip(const MontyBytes([0, 255])),
          const MontyBytes([0, 255]),
        );
      },
    );
  });

  group('constructors keep the supplied list', () {
    test('REQ-MontyTuple-3: MontyTuple stores items', () {
      final items = <MontyValue>[const MontyInt(1)];
      final t = MontyTuple(items);
      expect(identical(t.items, items), isTrue);
      items.add(const MontyInt(2));
      expect(t.items, hasLength(2));
    });
    test('REQ-MontySet-3: MontySet stores items', () {
      final items = <MontyValue>[const MontyInt(1)];
      final s = MontySet(items);
      expect(identical(s.items, items), isTrue);
      items.add(const MontyInt(2));
      expect(s.items, hasLength(2));
    });
    test('REQ-MontyFrozenSet-3: MontyFrozenSet stores items', () {
      final items = <MontyValue>[const MontyInt(1)];
      final s = MontyFrozenSet(items);
      expect(identical(s.items, items), isTrue);
      items.add(const MontyInt(2));
      expect(s.items, hasLength(2));
    });
    test('REQ-MontyNamedTuple-3: MontyNamedTuple stores its three members', () {
      final names = ['a', 'b'];
      final values = <MontyValue>[const MontyInt(1), const MontyInt(2)];
      final nt = MontyNamedTuple(
        typeName: 'Point',
        fieldNames: names,
        values: values,
      );
      expect(nt.typeName, 'Point');
      expect(identical(nt.fieldNames, names), isTrue);
      expect(identical(nt.values, values), isTrue);
    });
  });

  group('toString', () {
    test('REQ-MontyList-20: MontyList(N items)', () {
      expect(const MontyList([]).toString(), 'MontyList(0 items)');
      expect(
        const MontyList([MontyInt(1), MontyInt(2), MontyInt(3)]).toString(),
        'MontyList(3 items)',
      );
    });
    test('REQ-MontyTuple-20: MontyTuple(N items)', () {
      expect(const MontyTuple([]).toString(), 'MontyTuple(0 items)');
      expect(
        const MontyTuple([MontyInt(1), MontyInt(2)]).toString(),
        'MontyTuple(2 items)',
      );
    });
    test('REQ-MontyNamedTuple-17: MontyNamedTuple(T, N fields)', () {
      expect(
        const MontyNamedTuple(
          typeName: 'Point',
          fieldNames: ['x', 'y'],
          values: [MontyInt(1), MontyInt(2)],
        ).toString(),
        'MontyNamedTuple(Point, 2 fields)',
      );
      expect(
        const MontyNamedTuple(
          typeName: 'E',
          fieldNames: [],
          values: [],
        ).toString(),
        'MontyNamedTuple(E, 0 fields)',
      );
      // The count is the field names', whatever the values hold.
      expect(
        const MontyNamedTuple(
          typeName: 'T',
          fieldNames: ['a', 'b'],
          values: [MontyInt(1)],
        ).toString(),
        'MontyNamedTuple(T, 2 fields)',
      );
      expect(
        const MontyNamedTuple(
          typeName: 'T',
          fieldNames: ['a'],
          values: [MontyInt(1), MontyInt(2), MontyInt(3)],
        ).toString(),
        'MontyNamedTuple(T, 1 fields)',
      );
    });
  });

  group('fromDart identity', () {
    test('REQ-MontyTuple-17: an existing MontyTuple is returned unchanged', () {
      final v = MontyTuple([MontyInt(_n(1))]);
      expect(identical(MontyValue.fromDart(v), v), isTrue);
    });
  });

  group('cycles', () {
    MontyTuple cyclicTuple() {
      final items = <MontyValue>[];
      final t = MontyTuple(items);
      items.add(t);

      return t;
    }

    MontyFrozenSet cyclicFrozen() {
      final items = <MontyValue>[];
      final t = MontyFrozenSet(items);
      items.add(t);

      return t;
    }

    MontyNamedTuple cyclicNamed() {
      final values = <MontyValue>[];
      final t = MontyNamedTuple(
        typeName: 'T',
        fieldNames: const ['a'],
        values: values,
      );
      values.add(t);

      return t;
    }

    test('REQ-MontyTuple-21: a cyclic tuple equals itself by identity', () {
      final t = cyclicTuple();
      expect(t == t, isTrue);
      expect(t.items.single == t, isTrue);
    });
    test('REQ-MontyTuple-22: == and hashCode throw StateError on a cycle', () {
      final t = cyclicTuple();
      expect(() => t.hashCode, throwsStateError);
      expect(() => t == cyclicTuple(), throwsStateError);
      expect(() => MontyList([t]).hashCode, throwsStateError);
    });
    test('REQ-MontyTuple-23: dartValue refuses a cyclic tuple', () {
      final t = cyclicTuple();
      expect(() => t.dartValue, throwsStateError);
      expect(() => MontyList([t]).dartValue, throwsStateError);
      // Acyclic tuples still project.
      expect(const MontyTuple([MontyInt(1)]).dartValue, [1]);
    });
    test('REQ-MontyNamedTuple-24: graph operations refuse cycles', () {
      final t = cyclicNamed();
      expect(t == t, isTrue);
      expect(() => t.hashCode, throwsStateError);
      expect(() => t.dartValue, throwsStateError);
      expect(t.toJson, throwsStateError);
      expect(() => t == cyclicNamed(), throwsStateError);
    });
    test(
      'REQ-MontyFrozenSet-28: equality, hashing, projection refuse cycles',
      () {
        final t = cyclicFrozen();
        expect(t == t, isTrue);
        expect(() => t == cyclicFrozen(), throwsStateError);
        expect(() => t.hashCode, throwsStateError);
        expect(() => t.dartValue, throwsStateError);
        expect(t.toJson, throwsStateError);
      },
    );
  });

  group('MontySet', () {
    test(
      'REQ-MontySet-28: a cycle refuses hashing, projection and a comparison '
      'that reaches it; a shared cyclic element equals itself by identity',
      () {
        final c = _cyclicList();
        // Hashing and projection walk into the cycle.
        expect(() => MontySet([c]).hashCode, throwsStateError);
        expect(() => MontySet([c]).dartValue, throwsStateError);
        expect(MontySet([c]).toJson, throwsStateError);
        // Distinct cyclic elements: the comparison reaches the cycle.
        expect(
          () => MontySet([_cyclicList()]) == MontySet([_cyclicList()]),
          throwsStateError,
        );
        // The same cyclic object on both sides is identity-equal (upstream
        // `Value::py_eq` returns true for `is`, value.rs:1548), so the
        // comparison never descends into it.
        expect(MontySet([c]) == MontySet([c]), isTrue);
        final s = MontySet([c]);
        expect(s == s, isTrue);
        expect(MontySet([c]) == MontySet([c, const MontyInt(1)]), isFalse);
      },
    );
    test(
      'REQ-MontySet-18: projections share objects; the writer shares roots',
      () {
        const inner = MontySet([MontyInt(1), MontyInt(2)]);
        const list = MontyList([inner, inner]);
        final direct = list.dartValue as List;
        expect(identical(direct[0], direct[1]), isTrue);
        expect(direct[0], [1, 2]);
        final json = list.toJson()! as List;
        expect(identical(json[0], json[1]), isTrue);
        expect((json[0] as Map)['__type'], 'set');

        const dict = MontyDict([
          (MontyString('a'), inner),
          (MontyString('b'), inner),
        ]);
        final map = dict.dartValue! as Map;
        expect(identical(map['a'], map['b']), isTrue);

        // Sharing is kept inside a set too: a container met under two of
        // its members is one projected object.
        const shared = MontyList([MontyInt(1)]);
        const holder = MontySet([
          shared,
          MontyTuple([shared]),
        ]);
        final members = holder.dartValue as List;
        expect(members[0], [1]);
        expect(identical((members[1] as List)[0], members[0]), isTrue);
        final tagged = (holder.toJson()! as Map)['value'] as List;
        final taggedTuple = tagged[1] as Map;
        expect(identical((taggedTuple['value'] as List)[0], tagged[0]), isTrue);

        final writer = ArenaWriter();
        final first = writer.add(inner);
        final nodes = writer.arena.nodes.length;
        final second = writer.add(inner);
        expect(second, first);
        expect(writer.arena.nodes.length, nodes);
        final listRoot = writer.add(list);
        expect(listRoot, isNot(first));
        expect(writer.arena.nodes.length, nodes + 1);
      },
    );
    test(
      'value-level NaN set equality (MontySet-34 not claimed)',
      () {
        final nan = _nan();
        final s = MontySet([nan, const MontyInt(1)]);
        expect(s == s, isTrue);
        expect(MontySet([nan]) == MontySet([nan]), isTrue);
        expect(
          MontySet([_nan()]) == MontySet([_nan()]),
          isTrue,
        );
        expect(MontySet([nan]) == const MontySet([MontyFloat(1)]), isFalse);
        expect(nan == nan, isTrue);
      },
    );
  });

  group('MontyFrozenSet', () {
    test(
      'equality half of FrozenSet-35 (wire half untested; row not claimed)',
      () {
        final nan = _nan();
        final s = MontyFrozenSet([nan]);
        expect(s == s, isTrue);
        expect(s == MontyFrozenSet([_nan()]), isTrue);
        expect(
          s.hashCode,
          MontyFrozenSet([_nan()]).hashCode,
        );
        expect(s == const MontyFrozenSet([MontyFloat(0)]), isFalse);
      },
    );
    test(
      'REQ-MontyFrozenSet-36: exceptions and file handles compare by field',
      () {
        MontyFrozenSet exc(String msg) => MontyFrozenSet([
          MontyExceptionValue('ValueError', msg, {'k': MontyInt(_n(1))}),
        ]);
        expect(exc('m') == exc('m'), isTrue);
        expect(exc('m').hashCode, exc('m').hashCode);
        expect(exc('m') == exc('n'), isFalse);
        MontyFrozenSet withAttr(int v) => MontyFrozenSet([
          MontyExceptionValue('E', 'm', {'k': MontyInt(_n(v))}),
        ]);
        expect(withAttr(1) == withAttr(1), isTrue);
        expect(withAttr(1) == withAttr(2), isFalse);
        expect(
          MontyFrozenSet([MontyExceptionValue('A', 'm')]) ==
              MontyFrozenSet([MontyExceptionValue('B', 'm')]),
          isFalse,
        );

        MontyFrozenSet fh(String path, String mode, int pos) => MontyFrozenSet([
          MontyFileHandle(path, mode, position: BigInt.from(pos)),
        ]);
        expect(fh('/a', 'r', 3) == fh('/a', 'r', 3), isTrue);
        expect(fh('/a', 'r', 3).hashCode, fh('/a', 'r', 3).hashCode);
        expect(fh('/a', 'r', 3) == fh('/b', 'r', 3), isFalse);
        expect(fh('/a', 'r', 3) == fh('/a', 'w', 3), isFalse);
        expect(fh('/a', 'r', 3) == fh('/a', 'r', 4), isFalse);
      },
    );
  });

  group('MontyDict', () {
    final cyclic = _cyclicList();

    test(
      'REQ-MontyDict-16: all-string keys keep first position, last value',
      () {
        const d = MontyDict([
          (MontyString('a'), MontyInt(1)),
          (MontyString('b'), MontyInt(9)),
          (MontyString('a'), MontyInt(2)),
        ]);
        final out = d.dartValue! as Map<String, Object?>;
        expect(out.keys.toList(), ['a', 'b']);
        expect(out, {'a': 2, 'b': 9});
        expect((d.toJson()! as Map)['value'], {'a': 2, 'b': 9});

        // A cycle reachable only through an overwritten value is not met.
        final hidden = MontyDict([
          (const MontyString('a'), cyclic),
          (const MontyString('a'), const MontyInt(2)),
        ]);
        expect(hidden.dartValue, {'a': 2});
        expect(hidden.toJson(), {
          '__type': 'dict',
          'value': {'a': 2},
        });
        // The surviving value is projected, so a cycle there still fails.
        final live = MontyDict([
          (const MontyString('a'), const MontyInt(2)),
          (const MontyString('a'), cyclic),
        ]);
        expect(() => live.dartValue, throwsStateError);
      },
    );
    test(
      'REQ-MontyDict-17: a non-string key keeps every pair, duplicates too',
      () {
        const d = MontyDict([
          (MontyString('a'), MontyInt(1)),
          (MontyString('a'), MontyInt(2)),
          (MontyInt(1), MontyInt(3)),
        ]);
        expect(d.dartValue, [
          ['a', 1],
          ['a', 2],
          [1, 3],
        ]);
        expect((d.toJson()! as Map)['entries'], [
          ['a', 1],
          ['a', 2],
          [1, 3],
        ]);
        // Every pair is traversed, so a cycle in an overwritten value is met.
        final hidden = MontyDict([
          (const MontyString('a'), cyclic),
          (const MontyString('a'), const MontyInt(2)),
          (const MontyInt(1), const MontyInt(3)),
        ]);
        expect(() => hidden.dartValue, throwsStateError);
      },
    );
    test(
      'REQ-MontyDict-34: dartValue throws StateError on an encountered cycle',
      () {
        expect(
          () => MontyDict([(const MontyString('k'), cyclic)]).dartValue,
          throwsStateError,
        );
        expect(
          () => MontyDict([(const MontyInt(1), cyclic)]).dartValue,
          throwsStateError,
        );
        expect(
          () => MontyDict([(cyclic, const MontyInt(1))]).dartValue,
          throwsStateError,
        );
        // Overwritten values of an all-string dictionary are skipped.
        expect(
          MontyDict([
            (const MontyString('k'), cyclic),
            (const MontyString('k'), const MontyInt(5)),
          ]).dartValue,
          {'k': 5},
        );
      },
    );
    test('REQ-MontyDict-43: distinct NaN keys compare equal', () {
      MontyDict d(int v) => MontyDict([(_nan(), MontyInt(v))]);
      expect(d(1) == d(1), isTrue);
      expect(d(1).hashCode, d(1).hashCode);
      expect(d(1) == d(2), isFalse);
      final twoNan = MontyDict([
        (_nan(), const MontyInt(1)),
        (_nan(), const MontyInt(2)),
      ]);
      expect(twoNan == d(2), isTrue);
    });
    test('REQ-MontyDict-21: fromDart keeps Python-equal keys apart', () {
      final shared = <Object?>[1, 2];
      final v =
          MontyValue.fromDart({true: 'a', 1: 'b', 'x': shared, 'y': shared})
              as MontyDict;
      expect(v.pairs, hasLength(4));
      expect(v.pairs[0].$1, isA<MontyBool>());
      expect(v.pairs[0].$2, const MontyString('a'));
      expect(v.pairs[1].$1, isA<MontyInt>());
      expect(v.pairs[1].$2, const MontyString('b'));
      // Equal as Python keys, yet two pairs were kept.
      expect(v.pairs[0].$1 == v.pairs[1].$1, isTrue);
      expect(identical(v.pairs[2].$2, v.pairs[3].$2), isTrue);
      expect((v.pairs[2].$2 as MontyList).items, hasLength(2));
      final twice = MontyValue.fromDart([shared, shared]) as MontyList;
      expect(identical(twice.items[0], twice.items[1]), isTrue);
      final mapShared = <Object?, Object?>{'k': 1};
      final m2 = MontyValue.fromDart([mapShared, mapShared]) as MontyList;
      expect(identical(m2.items[0], m2.items[1]), isTrue);
    });
    test('REQ-MontyDict-36: fromDart refuses cycles and unsupported types', () {
      final list = <Object?>[];
      list.add(list);
      expect(() => MontyValue.fromDart(list), throwsArgumentError);
      final map = <Object?, Object?>{};
      map['self'] = map;
      expect(() => MontyValue.fromDart(map), throwsArgumentError);
      final nested = <Object?>[
        <Object?, Object?>{'k': <Object?>[]},
      ];
      ((nested[0]! as Map)['k']! as List).add(nested);
      expect(() => MontyValue.fromDart(nested), throwsArgumentError);

      expect(() => MontyValue.fromDart(Object()), throwsArgumentError);
      expect(() => MontyValue.fromDart({Object(): 1}), throwsArgumentError);
      expect(() => MontyValue.fromDart({'a': Object()}), throwsArgumentError);
      expect(
        () => MontyValue.fromDart({
          'a': {'b': Object()},
        }),
        throwsArgumentError,
      );
      expect(
        () => MontyValue.fromDart({
          'a': [Object()],
        }),
        throwsArgumentError,
      );
      expect(() => MontyValue.fromDart(<int>{1}), throwsArgumentError);
    });
  });

  group('MontyValue projections', () {
    test('REQ-MontyValue-15: named-tuple children use the toJson form', () {
      const date = MontyDate(year: 2024, month: 3, day: 5);
      const nt = MontyNamedTuple(
        typeName: 'T',
        fieldNames: ['a'],
        values: [date],
      );
      final out = const MontyList([date, nt, date]).dartValue as List;
      expect(out[0], isA<DateTime>());
      expect(out[2], isA<DateTime>());
      final inner = ((out[1] as Map)['values']! as List)[0];
      expect(inner, isA<Map<String, Object?>>());
      expect(inner, {'__type': 'date', 'year': 2024, 'month': 3, 'day': 5});
      expect(inner, isNot(out[0]));
    });
  });
}
