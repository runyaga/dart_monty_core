// FrameScan (lib/src/worker/frame_scan.dart) against upstream's decoder:
// every fixture's verdict, decoded values and decode budget were recorded
// from monty-proto 1.1.0 (_frame_fixtures.dart). Pure Dart, so it runs on the
// VM, dart2js and dart2wasm.
import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/frame_scan.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart';
import 'package:test/test.dart';

import '_frame_fixtures.g.dart';

Uint8List _bytes(String hex) => Uint8List.fromList([
  for (var i = 0; i < hex.length; i += 2)
    int.parse(hex.substring(i, i + 2), radix: 16),
]);

/// The `optional` scalar fields a `ChildEvent` can hold: explicit presence,
/// so a value equal to the default still counts.
const _explicit = {
  'Complex.real', 'Complex.imag', 'DateTime.offsetSeconds', //
  'DateTime.timezoneName', 'Time.offsetSeconds', 'Time.timezoneName',
  'TimeZone.name', 'Exception.arg', 'Function.docstring',
  'RaisedException.message', 'JsonErrorData.doc', 'StackFrame.frameName',
  'StackFrame.previewLine', 'ChildEvent.maxSuspensions',
  'ChildEvent.maxFeedDurationMicros', 'ChildEvent.maxTurnDurationMicros',
  'ChildEvent.maxTotalSleepMicros', 'ChildEvent.restoredScriptName',
  'ChildEvent.sessionId', 'ShutdownDump.dump',
};

/// prost's re-encoding [hex], parsed by package:protobuf with every string
/// decoded as Rust decodes it (keeping a leading U+FEFF). The strings
/// themselves are checked apart, against [FrameFixture.strings].
pb.ChildEvent _canonical(String hex) {
  final reader = _KeepBom(_bytes(hex));
  final event = pb.ChildEvent()..mergeFromCodedBufferReader(reader);
  reader.checkLastTagWas(0);

  return event;
}

final class _KeepBom extends CodedBufferReader {
  _KeepBom(super.buffer);

  @override
  String readString() {
    final bytes = readBytesAsView();
    final text = utf8.decode(bytes);
    final bom = bytes.take(3).toList();

    return const ListEquality<int>().equals(bom, [0xEF, 0xBB, 0xBF])
        ? '\u{FEFF}$text'
        : text;
  }
}

/// [message] as the values upstream's decoder keeps, so two decodings
/// compare by value:
///
/// - no unknown fields: prost drops them, package:protobuf keeps them;
/// - no arena `node_count`: upstream reads it as a reservation hint, and its
///   re-encoding writes the arena's length;
/// - no implicit-presence scalar holding its default: prost cannot tell one
///   from an absent field, package:protobuf can;
/// - a big integer's magnitude without leading zeros, and zero unsigned, as
///   upstream's `BigInt` holds it.
T _known<T extends GeneratedMessage>(T message) {
  final pending = <GeneratedMessage>[message];
  while (pending.isNotEmpty) {
    final current = pending.removeLast()..unknownFields.clear();
    if (current is pb.Arena) current.clearNodeCount();
    if (current is pb.BigInt) {
      final magnitude = current.magnitude;
      final first = magnitude.indexWhere((byte) => byte != 0);
      current.magnitude = first < 0 ? [] : magnitude.sublist(first);
      if (first < 0) current.clearNegative();
    }
    final type = current.info_.qualifiedMessageName.split('.').lastOrNull;
    for (final info in current.info_.sortedByTag) {
      final Object? value = current.getFieldOrNull(info.tagNumber);
      switch (value) {
        case final GeneratedMessage child:
          pending.add(child);
        case final List<Object?> children:
          pending.addAll(children.whereType());
        case null:
          break;
        case _
            when !current.info_.oneofs.containsKey(info.tagNumber) &&
                !_explicit.contains('$type.${info.name}') &&
                _isDefault(value, info.readonlyDefault):
          current.clearField(info.tagNumber);
      }
    }
  }

  return message;
}

/// The UTF-8 of every non-empty string [message] holds, at every depth, as
/// sorted hex: compared with the strings in prost's re-encoding, read without
/// package:protobuf.
List<String> _strings(GeneratedMessage message) {
  final found = <String>[];
  final pending = [message];
  for (var m = pending.lastOrNull; m != null; m = pending.lastOrNull) {
    pending.removeLast();
    for (final info in m.info_.sortedByTag) {
      final Object? value = m.getFieldOrNull(info.tagNumber);
      final values = value is List<Object?> ? value : [value];
      for (final item in values) {
        switch (item) {
          case final GeneratedMessage child:
            pending.add(child);
          case final String text when text.isNotEmpty:
            found.add(
              [
                for (final byte in utf8.encode(text))
                  byte.toRadixString(16).padLeft(2, '0'),
              ].join(),
            );
        }
      }
    }
  }

  return found..sort();
}

/// How many unknown fields [message] holds, at every depth.
int _unknownFields(GeneratedMessage message) {
  var count = 0;
  final pending = [message];
  for (var m = pending.lastOrNull; m != null; m = pending.lastOrNull) {
    pending.removeLast();
    count += m.unknownFields.asMap().length;
    for (final info in m.info_.sortedByTag) {
      final Object? value = m.getFieldOrNull(info.tagNumber);
      for (final item in value is List<Object?> ? value : [value]) {
        if (item is GeneratedMessage) pending.add(item);
      }
    }
  }

  return count;
}

bool _isDefault(Object? value, Object? defaultValue) => switch (value) {
  final List<int> bytes => bytes.isEmpty,
  _ => value == defaultValue,
};

/// What package:protobuf alone makes of [fixture]: whether it agrees with
/// upstream's verdict and, for an accepted frame, upstream's values.
bool _protobufAgrees(FrameFixture fixture) {
  final pb.ChildEvent plain;
  try {
    plain = pb.ChildEvent.fromBuffer(_bytes(fixture.hex));
  } on InvalidProtocolBufferException {
    return fixture.error != null;
  }
  final canonical = fixture.canonical;
  if (canonical == null) return false;

  return _known(plain) == _known(_canonical(canonical)) &&
      const ListEquality<String>().equals(_strings(plain), fixture.strings);
}

void main() {
  group('upstream accepts', () {
    for (final fixture in frameFixtures) {
      final FrameFixture(:name, hex: frame, :budget, :canonical) = fixture;
      if (budget == null || canonical == null) continue;
      test(name, () {
        final body = _bytes(frame);
        final decoded = FrameScan.decodeChildEvent(body);
        expect(body, hasLength(frame.length ~/ 2));
        expect(_unknownFields(decoded), 0, reason: 'prost keeps none');
        expect(
          _known(decoded),
          _known(_canonical(canonical)),
          reason: 'the values prost decodes',
        );
        expect(
          _strings(decoded),
          fixture.strings,
          reason: 'the strings prost decodes, read without package:protobuf',
        );
      });

      test('$name: charges $budget bytes, as upstream', () {
        for (final limit in [Frame.maxDecodeBytes, budget]) {
          expect(FrameScan.childEvent(_bytes(frame), budget: limit), budget);
        }
        if (budget == 0) return;
        expect(
          () => FrameScan.childEvent(_bytes(frame), budget: budget - 1),
          throwsA(
            isA<FrameDecodeException>().having(
              (e) => e.reason,
              'reason',
              allOf(
                startsWith('failed to decode Protobuf message: '),
                endsWith('frame exceeds decode memory budget'),
              ),
            ),
          ),
        );
      });
    }
  });

  // The reason is prost's `DecodeError` display, which upstream's pool puts
  // after `invalid payload from worker: ` (checkout.rs:1688-1689): the
  // fixed prefix, the fields being merged innermost first, the description.
  group('upstream rejects, with its text', () {
    for (final fixture in frameFixtures.where((f) => f.error != null)) {
      test(fixture.name, () {
        expect(
          () => FrameScan.decodeChildEvent(_bytes(fixture.hex)),
          throwsA(
            isA<FrameDecodeException>().having(
              (e) => e.reason,
              'reason',
              fixture.error,
            ),
          ),
        );
      });
    }
  });

  // The fixtures marked protobufDiffers are the reason for the scan: without
  // it the parent accepts what upstream's rejects, or reads other values. The
  // others are controls that both decoders already treat alike.
  group('package:protobuf alone', () {
    for (final fixture in frameFixtures) {
      test(fixture.name, () {
        expect(_protobufAgrees(fixture), !fixture.protobufDiffers);
      });
    }
  });

  group('the decode budget at upstream default', () {
    // Complete { values { node_count: 2^32-1, <unknown field> } }: the hint
    // reserves one 72-byte node slot per four bytes left in the frame, so
    // padding moves the charge across Frame.maxDecodeBytes. Upstream accepts
    // 59652323 bytes after the hint (charging 1073741760) and rejects
    // 59652324 (1073741832).
    Uint8List frame(int remaining) {
      // Field 15, delimited: one key byte, a four-byte length, the padding.
      final padding = remaining - 5;
      final arena = remaining + 6;
      final complete = arena + 5;
      List<int> varint4(int value) => [
        for (var k = 0; k < 4; k++)
          (value >> (k * 7)) & 0x7f | (k < 3 ? 0x80 : 0),
      ];
      final header = [
        0x32,
        ...varint4(complete),
        0x12,
        ...varint4(arena),
        // node_count: 2^32 - 1.
        ...[0x08, 0xff, 0xff, 0xff, 0xff, 0x0f],
        0x7a,
        ...varint4(padding),
      ];

      return Uint8List(header.length + padding)..setAll(0, header);
    }

    test('one slot under the budget: accepted', () {
      expect(FrameScan.childEvent(frame(59652323)), 1073741760);
    });

    test('one slot over the budget: rejected before anything is reserved', () {
      expect(
        () => FrameScan.childEvent(frame(59652324)),
        throwsA(isA<FrameDecodeException>()),
      );
    });

    test('is upstream DEFAULT_MAX_DECODE_BYTES', () {
      expect(Frame.maxDecodeBytes, 1 << 30);
    });
  });

  test('MontyNode_Kind is numbered in field order, as the scan assumes', () {
    const kinds = pb.MontyNode_Kind.values;
    for (var field = 1; field <= 31; field++) {
      final (wire, payload) = switch (field) {
        4 || 5 => (0, [0]),
        7 => (1, List.filled(8, 0)),
        _ => (2, [0]),
      };
      final key = field * 8 + wire;
      final arm = [
        if (key < 0x80) key else ...[key & 0x7f | 0x80, key >> 7],
      ];
      expect(
        pb.MontyNode.fromBuffer([...arm, ...payload]).whichKind(),
        kinds.elementAtOrNull(field - 1),
      );
    }
  });

  // node_from_proto also converts what it accepts (a file mode to its
  // canonical form, a big integer's magnitude without leading zeros); in the
  // parent that is the arena reader's stage, after the scan.
  test('a node keeps its wire value; the reader converts it as upstream', () {
    for (final (mode, canonical) in [('rt', 'r'), ('br', 'rb')]) {
      final event = FrameScan.decodeChildEvent(
        pb.ChildEvent(
          complete: pb.Complete(
            values: pb.Arena(
              nodes: [
                pb.MontyNode(
                  fileHandle: pb.FileHandle(path: 'f', mode: mode),
                ),
              ],
            ),
          ),
        ).writeToBuffer(),
      );
      final values = event.complete.values;
      expect(values.nodes.singleOrNull?.fileHandle.mode, mode);
      expect(
        ArenaReader(values)[0],
        isA<MontyFileHandle>().having((h) => h.mode, 'mode', canonical),
      );
    }
  });

  group('unknown fields', () {
    // Field 99 is unknown in every message: added at each depth below.
    final known = pb.ChildEvent(
      complete: pb.Complete(
        values: pb.Arena(
          nodes: [
            pb.MontyNode(date: pb.Date(year: 2000, month: 1, day: 1)),
          ],
        ),
      ),
    );
    Uint8List withUnknowns(GeneratedMessage message) => message.writeToBuffer();
    void addUnknown(GeneratedMessage message) =>
        message.unknownFields.mergeVarintField(99, Int64.ONE);

    test('are dropped at every depth, as prost drops them', () {
      final event = known.deepCopy();
      final complete = event.complete;
      final arena = complete.values;
      final node = arena.nodes.firstOrNull ?? pb.MontyNode();
      [event, complete, arena, node, node.date].forEach(addUnknown);
      event.unknownFields.mergeGroupField(
        16,
        UnknownFieldSet()..mergeLengthDelimitedField(1, [1, 2, 3]),
      );
      final decoded = FrameScan.decodeChildEvent(withUnknowns(event));
      expect(_unknownFields(decoded), 0);
      expect(decoded, known);
    });

    test('thousands of them cost the decoded event nothing', () {
      final event = pb.ChildEvent(ok: pb.Ok());
      for (var i = 0; i < 5000; i++) {
        addUnknown(event);
        event.unknownFields.mergeVarintField(i % 7 + 90, Int64(i));
      }
      final decoded = FrameScan.decodeChildEvent(withUnknowns(event));
      expect(_unknownFields(decoded), 0);
      expect(decoded, pb.ChildEvent(ok: pb.Ok()));
    });

    test('do not hide a node from its check', () {
      final event = known.deepCopy();
      final date = event.complete.values.nodes.firstOrNull?.date ?? pb.Date();
      addUnknown(date..day = 32);
      expect(
        () => FrameScan.decodeChildEvent(withUnknowns(event)),
        throwsA(isA<FrameDecodeException>()),
      );
    });

    test('do not hide a function call object id from its check', () {
      final call = pb.ChildEvent(
        functionCall: pb.FunctionCall(
          functionName: 'f',
          objectId: pb.Uuid(data: List.filled(15, 1)),
          values: pb.Arena(),
        ),
      );
      addUnknown(call.functionCall.objectId);
      expect(
        () => FrameScan.decodeChildEvent(withUnknowns(call)),
        throwsA(isA<FrameDecodeException>()),
      );
      call.functionCall.objectId.data = List.filled(16, 1);
      final decoded = FrameScan.decodeChildEvent(withUnknowns(call));
      expect(decoded.functionCall.objectId.data, List.filled(16, 1));
      expect(_unknownFields(decoded), 0);
    });
  });

  group('normalisation', () {
    test(
      'a leading byte-order mark is kept, as String::from_utf8 keeps it',
      () {
        // Complete { values { nodes: [ { str: "\u{FEFF}a" } ] } }
        final event = FrameScan.decodeChildEvent(
          _bytes('320c120a080112064204efbbbf61'),
        );
        expect(
          event.complete.values.nodes.singleOrNull?.str,
          '\u{FEFF}a',
        );
      },
    );

    test('a full-width boolean is rewritten in place, at its length', () {
      // Complete { values { nodes: [ { boolean: 2^32 } ] } }
      final body = _bytes('320c120a08011206208080808010');
      expect(
        FrameScan.decodeChildEvent(body).complete.values.nodes.singleOrNull,
        pb.MontyNode(boolean: true),
      );
      expect(body, _bytes('320c120a08011206208180808000'));
    });

    test('an unknown PrintStream reads as unspecified, as prost reads it', () {
      // Print { segments: [ { stream: STDERR, stream: 7, text: "x" } ] }
      final event = FrameScan.decodeChildEvent(
        _bytes('0a090a0708020807120178'),
      );
      expect(
        event.print.segments.singleOrNull?.stream,
        pb.PrintStream.PRINT_STREAM_UNSPECIFIED,
      );
    });
  });
}
