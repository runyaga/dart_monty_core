// The worker value arena (lib/src/worker/arena.dart): every kind of the M2
// subset both ways, identity, integer and float edge cases, malformed input,
// and depth. Pure Dart, so the unit and unit_web steps run it on the VM,
// dart2js and dart2wasm.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';

pb.Arena _arena(List<pb.MontyNode> nodes) =>
    pb.Arena(nodeCount: nodes.length, nodes: nodes);

pb.MontyNode _int(int v) => pb.MontyNode(int_5: Int64(v));

pb.Indexes _ix(List<int> items) => pb.Indexes(items: items);

/// The value at the last node of [nodes], after a wire round trip.
MontyValue _decode(List<pb.MontyNode> nodes, [int? root]) {
  final arena = pb.Arena.fromBuffer(_arena(nodes).writeToBuffer());

  return ArenaReader(arena)[root ?? nodes.length - 1];
}

/// [value] written to an arena, sent over the wire and read back.
MontyValue _roundTrip(MontyValue value) {
  final writer = ArenaWriter();
  final root = writer.add(value);
  final arena = pb.Arena.fromBuffer(writer.arena.writeToBuffer());

  return ArenaReader(arena)[root];
}

/// The 8 bytes of [v], most significant first, as hex.
String _bits(double v) {
  final data = ByteData(8)..setFloat64(0, v);

  return [
    for (var i = 0; i < 8; i++)
      data.getUint8(i).toRadixString(16).padLeft(2, '0'),
  ].join();
}

final BigInt _two53 = BigInt.two.pow(53);

void main() {
  group('decode', () {
    test('scalars', () {
      expect(_decode([pb.MontyNode(none: pb.Unit())]), const MontyNone());
      expect(_decode([pb.MontyNode(boolean: true)]), const MontyBool(true));
      expect(_decode([_int(-41)]), const MontyInt(-41));
      expect(_decode([pb.MontyNode(float: 1.5)]), const MontyFloat(1.5));
      expect(
        _decode([pb.MontyNode(str: 'héllo ✓')]),
        const MontyString('héllo ✓'),
      );
      expect(
        _decode([
          pb.MontyNode(bytes: [0, 255]),
        ]),
        const MontyBytes([0, 255]),
      );
      expect(_decode([pb.MontyNode(path: '/x')]), const MontyPath('/x'));
    });

    test('an integral float stays a float on every compiler', () {
      final v = _decode([pb.MontyNode(float: 4)]);
      expect(v, isA<MontyFloat>());
    });

    test('-0.0 keeps its sign', () {
      // ignore: prefer_int_literals -- the sign of zero is the point.
      final zero = _decode([pb.MontyNode(float: -0.0)]);
      expect(_bits((zero as MontyFloat).value), '8000000000000000');
    });

    test('ints: MontyInt within 2^53, MontyBigInt beyond, either arm', () {
      final cases = <String, Object>{
        '9007199254740992': const MontyInt(9007199254740992),
        '-9007199254740992': const MontyInt(-9007199254740992),
        '9007199254740993': MontyBigInt(_two53 + BigInt.one),
        '-9007199254740993': MontyBigInt(-_two53 - BigInt.one),
        // The int arm's edge for this PR: package:protobuf decodes sint64
        // wrongly from |v| >= 2^62 (a known bug, worked around in M3).
        '4611686018427387903': MontyBigInt(BigInt.parse('4611686018427387903')),
        '-4611686018427387904': MontyBigInt(
          BigInt.parse('-4611686018427387904'),
        ),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        final v = _decode([pb.MontyNode(int_5: Int64.parseInt(key))]);
        expect(v, value, reason: key);
        expect(v.runtimeType, value.runtimeType, reason: key);
      }
    });

    test('bigint: sign and big-endian magnitude', () {
      final twoTo70 = BigInt.two.pow(70);
      // 2^70 is 0x40 followed by 8 zero bytes.
      final magnitude = [0x40, 0, 0, 0, 0, 0, 0, 0, 0];
      expect(
        _decode([pb.MontyNode(bigint: pb.BigInt(magnitude: magnitude))]),
        MontyBigInt(twoTo70),
      );
      expect(
        _decode([
          pb.MontyNode(
            bigint: pb.BigInt(negative: true, magnitude: magnitude),
          ),
        ]),
        MontyBigInt(-twoTo70),
      );
    });

    test('containers, in order', () {
      final one = _int(1);
      final v = _decode([
        one,
        pb.MontyNode(str: 'one'),
        _int(-3),
        pb.MontyNode(none: pb.Unit()),
        pb.MontyNode(list: _ix([0])),
        pb.MontyNode(
          dict: pb.NodePairs(
            pairs: [
              pb.NodePair(key: 0, value: 1),
              pb.NodePair(key: 2, value: 3),
              pb.NodePair(key: 1, value: 4),
            ],
          ),
        ),
      ]);
      final dict = v as MontyDict;
      expect(dict.pairs, [
        (const MontyInt(1), const MontyString('one')),
        (const MontyInt(-3), const MontyNone()),
        (const MontyString('one'), const MontyList([MontyInt(1)])),
      ]);
      final three = _int(3);
      expect(
        _decode([
          three,
          one,
          pb.MontyNode(set: _ix([0, 1])),
        ]),
        const MontySet([MontyInt(3), MontyInt(1)]),
      );
      expect(
        _decode([
          three,
          pb.MontyNode(frozenSet: _ix([0])),
        ]),
        const MontyFrozenSet([MontyInt(3)]),
      );
      expect(
        _decode([
          pb.MontyNode(str: 'a'),
          pb.MontyNode(bytes: [0]),
          pb.MontyNode(tuple: _ix([0, 1])),
        ]),
        const MontyTuple([
          MontyString('a'),
          MontyBytes([0]),
        ]),
      );
    });

    test('a node referenced three times is one Dart object (E0 s04)', () {
      // a = [1, 2]; [a, a, [a]]
      final v = _decode([
        _int(1),
        _int(2),
        pb.MontyNode(list: _ix([0, 1])),
        pb.MontyNode(list: _ix([2])),
        pb.MontyNode(list: _ix([2, 2, 3])),
      ]);
      final items = (v as MontyList).items;
      final inner = (itemAt(items, 2) as MontyList).items;
      expect(identical(itemAt(items, 0), itemAt(items, 1)), isTrue);
      expect(identical(itemAt(items, 0), onlyItem(inner)), isTrue);
    });

    test('two roots naming one node give one object', () {
      final reader = ArenaReader(
        _arena([
          pb.MontyNode(list: _ix([])),
        ]),
      );
      expect(identical(reader[0], reader[0]), isTrue);
    });

    test('decoded containers are unmodifiable', () {
      final v = _decode([
        _int(1),
        pb.MontyNode(list: _ix([0])),
      ]);
      expect(
        () => (v as MontyList).items.add(const MontyNone()),
        throwsUnsupportedError,
      );
    });

    test('kinds outside the subset are refused by name', () {
      for (final node in [
        pb.MontyNode(ellipsis: pb.Unit()),
        pb.MontyNode(complex: pb.Complex(real: 1, imag: 2)),
        pb.MontyNode(repr: '<object>'),
        pb.MontyNode(cycle: '[...]'),
        pb.MontyNode(date: pb.Date(year: 2026, month: 1, day: 2)),
        pb.MontyNode(),
      ]) {
        expect(
          () => _decode([node]),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              contains(node.whichKind().name),
            ),
          ),
        );
      }
    });

    test('a malformed arena is a FormatException', () {
      // A child at or above its holder breaks post-order.
      expect(
        () => _decode([
          pb.MontyNode(list: _ix([0])),
        ]),
        throwsFormatException,
      );
      expect(
        () => _decode([
          _int(1),
          pb.MontyNode(list: _ix([5])),
        ]),
        throwsFormatException,
      );
      expect(() => _decode([_int(1)], 1), throwsFormatException);
      expect(() => _decode([_int(1)], -1), throwsFormatException);
    });

    test('100,000 levels of nesting decode without recursion', () {
      const depth = 100000;
      final v = _decode([
        pb.MontyNode(none: pb.Unit()),
        for (var i = 0; i < depth; i++) pb.MontyNode(list: _ix([i])),
      ]);
      var level = 0;
      var cur = v;
      while (cur is MontyList) {
        cur = onlyItem<MontyValue>(cur.items);
        level++;
      }
      expect(level, depth);
    });

    test('a 64-level shared DAG decodes in one pass', () {
      // x = [x, x] sixty-four times: 2^64 paths, 65 nodes. A decoder that
      // expanded the graph into a tree would never finish.
      final v = _decode([
        pb.MontyNode(none: pb.Unit()),
        for (var i = 0; i < 64; i++) pb.MontyNode(list: _ix([i, i])),
      ]);
      expect((v as MontyList).items, hasLength(2));
    });
  });

  group('encode', () {
    test('every kind of the subset round-trips', () {
      final values = <MontyValue>[
        const MontyNone(),
        const MontyBool(false),
        const MontyInt(41),
        const MontyInt(-9007199254740992),
        MontyBigInt(_two53 + BigInt.one),
        MontyBigInt(BigInt.parse('-4611686018427387904')),
        MontyBigInt(BigInt.two.pow(70)),
        MontyBigInt(-BigInt.two.pow(70) + BigInt.one),
        const MontyFloat(1.5),
        const MontyFloat(4),
        const MontyString('héllo ✓'),
        const MontyBytes([0, 255]),
        const MontyPath('/x'),
        const MontyList([MontyInt(1)]),
        const MontyTuple([MontyString('t')]),
        const MontySet([MontyInt(3), MontyInt(1)]),
        const MontyFrozenSet([MontyInt(3)]),
        const MontyDict([
          (MontyInt(1), MontyString('one')),
          (MontyString('k'), MontyList([MontyNone()])),
        ]),
      ];
      for (final v in values) {
        final back = _roundTrip(v);
        expect(back, v, reason: '$v');
        expect(back.runtimeType, v.runtimeType, reason: '$v');
      }
    });

    test('-0.0 keeps its sign', () {
      // ignore: prefer_int_literals -- the sign of zero is the point.
      final f = _roundTrip(const MontyFloat(-0.0)) as MontyFloat;
      expect(_bits(f.value), '8000000000000000');
    });

    test('a bigint beyond 64 bits uses the bigint arm', () {
      final writer = ArenaWriter()..add(MontyBigInt(-BigInt.two.pow(70)));
      final node = onlyItem(writer.arena.nodes);
      expect(node.whichKind(), pb.MontyNode_Kind.bigint);
      expect(node.bigint.negative, isTrue);
      expect(node.bigint.magnitude, [0x40, 0, 0, 0, 0, 0, 0, 0, 0]);
    });

    test('one Dart object passed twice is one node', () {
      const shared = MontyList([MontyInt(1), MontyInt(2)]);
      final writer = ArenaWriter();
      final a = writer.add(const MontyList([shared, shared]));
      final b = writer.add(shared);
      final nodes = writer.arena.nodes;
      expect(writer.arena.nodeCount, nodes.length);
      expect(itemAt(nodes, a).list.items, [b, b]);
      final back = ArenaReader(writer.arena)[a] as MontyList;
      expect(identical(itemAt(back.items, 0), itemAt(back.items, 1)), isTrue);
    });

    test('nodes are in post-order', () {
      final writer = ArenaWriter()
        ..add(
          const MontyDict([
            (
              MontyString('k'),
              MontyList([
                MontyTuple([MontyInt(1)]),
              ]),
            ),
          ]),
        );
      final nodes = writer.arena.nodes;
      for (var i = 0; i < nodes.length; i++) {
        final node = itemAt(nodes, i);
        final children = switch (node.whichKind()) {
          pb.MontyNode_Kind.list => node.list.items,
          pb.MontyNode_Kind.tuple => node.tuple.items,
          pb.MontyNode_Kind.dict => [
            for (final p in node.dict.pairs) ...[p.key, p.value],
          ],
          _ => const <int>[],
        };
        expect(children.every((c) => c < i), isTrue, reason: 'node $i');
      }
    });

    test('a value that contains itself is refused', () {
      final items = <MontyValue>[];
      final loop = MontyList(items);
      items.add(loop);
      expect(() => ArenaWriter().add(loop), throwsArgumentError);
    });

    test('kinds outside the subset are refused', () {
      expect(
        () => ArenaWriter().add(const MontyEllipsis()),
        throwsUnsupportedError,
      );
      expect(
        () => ArenaWriter().add(
          const MontyList([MontyDate(year: 2026, month: 1, day: 2)]),
        ),
        throwsUnsupportedError,
      );
    });

    test('100,000 levels of nesting encode without recursion', () {
      MontyValue v = const MontyNone();
      for (var i = 0; i < 100000; i++) {
        v = MontyList([v]);
      }
      final writer = ArenaWriter();
      expect(writer.add(v), 100000);
    });

    test('a 64-level shared DAG encodes to 65 nodes', () {
      MontyValue v = const MontyNone();
      for (var i = 0; i < 64; i++) {
        v = MontyList([v, v]);
      }
      final writer = ArenaWriter()..add(v);
      expect(writer.arena.nodes, hasLength(65));
    });
  });
}
