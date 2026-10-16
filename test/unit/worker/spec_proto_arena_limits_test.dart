// Independent wire fixtures exercise selected arenas and allocation charges.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart' hide Frame;
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/frame_scan.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_proto_support.dart';

Matcher _budgetError() => isA<FrameDecodeException>().having(
  (e) => e.reason,
  'reason',
  endsWith('frame exceeds decode memory budget'),
);

MontyValue _value(Uint8List bytes, {int budget = Frame.maxDecodeBytes}) {
  final event = FrameScan.decodeChildEvent(bytes, budget: budget);

  return ArenaReader(event.complete.values)[event.complete.value];
}

void main() {
  for (final bad in [
    pb.MontyNode(list: pb.Indexes(items: [999])),
    pb.MontyNode(dict: pb.NodePairs(pairs: [pb.NodePair(key: 0, value: 0)])),
  ]) {
    test(
      'discarded ${bad.whichKind().name} '
      'skips graph construction',
      () {
        final discarded = complete([pb.MontyNode(list: pb.Indexes()), bad]);
        // Switching oneof arms discards the first Complete; repeating Complete
        // without the intervening Ok would merge arenas instead.
        final wire = Uint8List.fromList([
          ...discarded.writeToBuffer(),
          ...ok().writeToBuffer(),
          ...protoInt(42).writeToBuffer(),
        ]);
        expect(_value(wire), const MontyInt(42));
        expect(() => _value(discarded.writeToBuffer()), throwsFormatException);
      },
    );
  }

  test('a node in a discarded arm still receives its per-node check', () {
    final discarded = complete([
      pb.MontyNode(date: pb.Date(year: 10000, month: 1, day: 1)),
    ]);
    final wire = Uint8List.fromList([
      ...discarded.writeToBuffer(),
      ...ok().writeToBuffer(),
      ...protoInt(42).writeToBuffer(),
    ]);
    expect(
      () => _value(wire),
      throwsA(
        predicate<Object>(
          (e) => e.toString().contains('invalid value for Date.year'),
        ),
      ),
    );
  });

  for (final kind in ['str', 'bytes', 'list']) {
    test(
      '$kind above 64 KiB is bounded by decode budget',
      () {
        const length = 70000;
        final nodes = switch (kind) {
          'str' => [pb.MontyNode(str: 'x' * length)],
          'bytes' => [pb.MontyNode(bytes: List.filled(length, 255))],
          _ => [
            pb.MontyNode(none: pb.Unit()),
            pb.MontyNode(list: pb.Indexes(items: List.filled(length, 0))),
          ],
        };
        final event = pb.ChildEvent(
          complete: pb.Complete(
            value: nodes.length - 1,
            values: pb.Arena(nodes: nodes),
          ),
        );
        final wire = event.writeToBuffer();
        // Four arena slots (72 each), plus bytes or packed reference slots
        // (16 each, including upstream's host-container allowance).
        final budget = length * (kind == 'list' ? 16 : 1) + 288;
        expect(FrameScan.childEvent(wire), budget);
        final value = _value(wire, budget: budget);
        expect(value, switch (kind) {
          'str' => MontyString('x' * length),
          'bytes' => MontyBytes(List.filled(length, 255)),
          _ => MontyList(List.filled(length, const MontyNone())),
        });
        expect(() => _value(wire, budget: budget - 1), throwsA(_budgetError()));
      },
    );
  }

  test(
    'packed bytes reserve full replacement capacity',
    () {
      // Complete.values.nodes[0].list: two runs containing one reference each.
      // Second run encodes zero using two bytes, so capacity grows from 1 to
      // existing length 1 + encoded length 2 = 3. Charge (1+3)*16 + 4*72 = 352.
      final wire = Uint8List.fromList([
        0x32,
        13,
        0x12,
        11,
        0x12,
        9,
        0x5a,
        7,
        0x0a,
        1,
        0,
        0x0a,
        2,
        0x80,
        0,
      ]);
      expect(FrameScan.childEvent(wire, budget: 352), 352);
      expect(
        () => FrameScan.childEvent(wire, budget: 351),
        throwsA(_budgetError()),
      );
      final event = FrameScan.decodeChildEvent(wire, budget: 352);
      expect(event.complete.values.nodes.singleOrNull?.list.items, [0, 0]);
    },
  );
}
