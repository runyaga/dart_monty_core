// The generated bindings speak upstream's wire format on every compiler.
//
// The two golden frames below were written by upstream monty-proto 1.1.0's
// own Rust encoder (`encode_framed_into`, prost) from a value graph chosen for
// the cases a JavaScript number cannot hold or a naive encoder loses: integers
// beyond 2^53 in both signs, -0.0, a uint64 beyond 2^53, and one sub-list
// referenced twice. Decoding them, and re-encoding to the same bytes, on the
// VM, dart2js and dart2wasm is what shows the generated code and package:
// protobuf are wire-compatible with the worker, not merely self-consistent.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';

const List<int> _feedFrame = [
  152, 0, 0, 0, 26, 149, 1, 10, 14, 100, 91, 52, 48, 93, 32, 105, 115, 32, //
  100, 91, 53, 48, 93, 18, 5, 10, 1, 100, 16, 13, 26, 124, 8, 14, 18, 9, 40,
  130, 128, 128, 128, 128, 128, 128, 32, 18, 9, 57, 0, 0, 0, 0, 0, 0, 16, 64,
  18, 9, 57, 0, 0, 0, 0, 0, 0, 0, 128, 18, 2, 40, 2, 18, 2, 40, 4, 18, 6, 90,
  4, 10, 2, 3, 4, 18, 9, 40, 129, 128, 128, 128, 128, 128, 128, 32, 18, 2, 40,
  20, 18, 2, 40, 40, 18, 2, 40, 60, 18, 2, 40, 80, 18, 2, 40, 100, 18, 2, 40,
  120, 18, 36, 114, 34, 10, 2, 8, 7, 10, 4, 8, 8, 16, 1, 10, 4, 8, 9, 16, 2,
  10, 4, 8, 10, 16, 5, 10, 4, 8, 11, 16, 5, 10, 4, 8, 12, 16, 6,
];

const List<int> _completeFrame = [
  148, 0, 0, 0, 50, 128, 1, 8, 13, 18, 124, 8, 14, 18, 9, 40, 130, 128, 128, //
  128, 128, 128, 128, 32, 18, 9, 57, 0, 0, 0, 0, 0, 0, 16, 64, 18, 9, 57, 0,
  0, 0, 0, 0, 0, 0, 128, 18, 2, 40, 2, 18, 2, 40, 4, 18, 6, 90, 4, 10, 2, 3,
  4, 18, 9, 40, 129, 128, 128, 128, 128, 128, 128, 32, 18, 2, 40, 20, 18, 2,
  40, 40, 18, 2, 40, 60, 18, 2, 40, 80, 18, 2, 40, 100, 18, 2, 40, 120, 18,
  36, 114, 34, 10, 2, 8, 7, 10, 4, 8, 8, 16, 1, 10, 4, 8, 9, 16, 2, 10, 4, 8,
  10, 16, 5, 10, 4, 8, 11, 16, 5, 10, 4, 8, 12, 16, 6, 160, 1, 129, 128, 128,
  128, 128, 128, 128, 32, 176, 1, 232, 7, 192, 1, 42,
];

/// 2^53 + 1: the smallest positive integer a JavaScript number cannot hold.
const _big = '9007199254740993';

/// The value graph both goldens carry; node 13 is the root dict.
pb.Arena _arena() {
  return pb.Arena(
    nodeCount: 14,
    nodes: [
      bigIntNode(BigInt.parse(_big)),
      floatNode(4),
      // A double literal on purpose: the sign of zero is the point.
      // ignore: prefer_int_literals
      floatNode(-0.0),
      intNode(1),
      intNode(2),
      pb.MontyNode(list: pb.Indexes(items: [3, 4])),
      bigIntNode(BigInt.parse('-$_big')),
      for (final k in [10, 20, 30, 40, 50, 60]) intNode(k),
      pb.MontyNode(
        dict: pb.NodePairs(
          pairs: [
            // Value 0 is proto3's default, so prost omits it; leaving it unset
            // here is what keeps the Dart encoding byte-identical.
            pb.NodePair(key: 7),
            pb.NodePair(key: 8, value: 1),
            pb.NodePair(key: 9, value: 2),
            pb.NodePair(key: 10, value: 5),
            pb.NodePair(key: 11, value: 5),
            pb.NodePair(key: 12, value: 6),
          ],
        ),
      ),
    ],
  );
}

void _checkArena(pb.Arena arena, int root) {
  expect(root, 13);
  pb.MontyNode node(int i) => itemAt(arena.nodes, i);
  expect(intOfNode(node(0)).toString(), _big);
  expect(intOfNode(node(6)).toString(), '-$_big');
  expect(floatOfNode(node(1)), 4.0);
  final negativeZero = node(2);
  expect(negativeZero.whichKind(), pb.MontyNode_Kind.float);
  expect(
    floatOfNode(negativeZero).isNegative,
    isTrue,
    reason: '-0.0 keeps its sign',
  );
  final pairs = node(root).dict.pairs;
  expect(
    [for (final p in pairs) intOfNode(node(p.key)).toInt()],
    [
      10,
      20,
      30,
      40,
      50,
      60,
    ],
  );
  final shared = itemAt(pairs, 3).value;
  expect(itemAt(pairs, 4).value, shared, reason: 'one shared sub-list');
  expect(node(shared).list.items, [3, 4]);
}

void main() {
  test('a ParentRequest Feed from upstream decodes and re-encodes', () {
    final req = pb.ParentRequest.fromBuffer(
      onlyItem(Frame.split(_bytes(_feedFrame))),
    );
    expect(req.whichKind(), pb.ParentRequest_Kind.feed);
    expect(req.feed.code, 'd[40] is d[50]');
    final input = onlyItem(req.feed.inputs);
    expect(input.name, 'd');
    _checkArena(req.feed.values, input.value);
    expect(Frame.encode(req), _feedFrame);
  });

  test('a ChildEvent Complete from upstream decodes and re-encodes', () {
    final ev = pb.ChildEvent.fromBuffer(
      onlyItem(Frame.split(_bytes(_completeFrame))),
    );
    expect(ev.whichKind(), pb.ChildEvent_Kind.complete);
    _checkArena(ev.complete.values, ev.complete.value);
    // 2^54 + 1, a uint64 past 2^53.
    expect(ev.totalExecutionMicros.toString(), '18014398509481985');
    expect(ev.feedExecutionMicros.toInt(), 42);
    expect(ev.maxSuspensions.toInt(), 1000);
    expect(Frame.encode(ev), _completeFrame);
  });

  test('the same messages built in Dart encode to upstream bytes', () {
    final arena = _arena();
    final req = pb.ParentRequest(
      feed: pb.Feed(
        code: 'd[40] is d[50]',
        inputs: [pb.NamedRef(name: 'd', value: 13)],
        values: arena,
      ),
    );
    expect(Frame.encode(req), _feedFrame);

    final ev = pb.ChildEvent(
      complete: pb.Complete(value: 13, values: arena),
      totalExecutionMicros: Int64.parseInt('18014398509481985'),
      feedExecutionMicros: Int64(42),
      maxSuspensions: Int64(1000),
    );
    expect(Frame.encode(ev), _completeFrame);
  });

  test("upstream's Complete reads as values, sharing kept", () {
    final ev = pb.ChildEvent.fromBuffer(
      onlyItem(Frame.split(_bytes(_completeFrame))),
    );
    final dict =
        ArenaReader(ev.complete.values)[ev.complete.value] as MontyDict;
    final byKey = {
      for (final (k, v) in dict.pairs) (k as MontyInt).value: v,
    };
    MontyValue at(int key) => byKey[key] ?? fail('no key $key');
    final four = at(20);
    final shared = at(40);
    expect(at(10), MontyBigInt(BigInt.parse(_big)));
    expect(four, const MontyFloat(4));
    expect(four, isA<MontyFloat>());
    final zero = at(30) as MontyFloat;
    expect(zero.value.isNegative, isTrue, reason: '-0.0 keeps its sign');
    expect(shared, const MontyList([MontyInt(1), MontyInt(2)]));
    expect(identical(shared, at(50)), isTrue, reason: 'one shared sub-list');
    expect(at(60), MontyBigInt(BigInt.parse('-$_big')));
  });

  test('both goldens decode from one stream split at every byte', () {
    final stream = [..._feedFrame, ..._completeFrame];
    final decoder = FrameDecoder();
    final frames = [
      for (final b in stream) ...decoder.add([b]),
    ];
    decoder.close();
    expect(frames, hasLength(2));
    expect(
      pb.ParentRequest.fromBuffer(itemAt(frames, 0)).feed.code,
      'd[40] is d[50]',
    );
    expect(
      pb.ChildEvent.fromBuffer(itemAt(frames, 1)).whichKind(),
      pb.ChildEvent_Kind.complete,
    );
  });
}

Uint8List _bytes(List<int> l) => Uint8List.fromList(l);
