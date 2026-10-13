// Integers and floats on the worker wire, byte for byte: the zigzag vectors
// across the whole i64 range, NaN sign and payload bits in both directions,
// the generated field types that make both possible, and big integers of
// increasing size. Pure Dart, so the unit and unit_web steps run it on the
// VM, dart2js and dart2wasm.
//
// Every expected byte string is what upstream's prost encoder writes for the
// value, so a pass means the arena agrees with the worker, not only with
// itself.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:protobuf/protobuf.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';

/// Each value, and `MontyNode{int: value}` as the protobuf spec's zigzag
/// (prost's encoder) writes it.
const _intVectors = [
  ('0', '2800'),
  ('1', '2802'),
  ('-1', '2801'),
  ('9007199254740992', '288080808080808020'),
  ('-9007199254740992', '28ffffffffffffff1f'),
  ('4611686018427387903', '28feffffffffffffff7f'),
  ('4611686018427387904', '2880808080808080808001'),
  ('-4611686018427387904', '28ffffffffffffffff7f'),
  ('-4611686018427387905', '2881808080808080808001'),
  ('9223372036854775807', '28feffffffffffffffff01'),
  ('-9223372036854775808', '28ffffffffffffffffff01'),
];

/// IEEE 754 bit patterns, most significant byte first: Python's NaN and
/// the non-NaN edges, which a Dart double holds exactly on every compiler.
const _floatBits = [
  '7ff8000000000000', // NaN, Python's float('nan')
  '8000000000000000', // -0.0
  '0000000000000000',
  '7ff0000000000000', // infinity
  'fff0000000000000', // -infinity
  '0000000000000001', // smallest subnormal
  '3ff8000000000000', // 1.5
];

/// NaNs with the sign bit, a payload, or the signalling bit set.
///
/// They are exact from the wire to the wire on every compiler. A Dart double
/// holds them exactly on the VM and dart2wasm; on dart2js it is a JavaScript
/// number, which ECMAScript lets the engine re-encode as any NaN (V8 quiets
/// signalling NaNs and has dropped the sign of fff8...), so there the double
/// is only checked to be a NaN.
const _nanBits = [
  'fff8000000000000', // -float('nan')
  '7ff8000000000001', // quiet NaN with a payload
  'fff800000000beef', // negative quiet NaN with a payload
  '7ff4000000000000', // signalling NaN
  'fff0000000000001', // negative signalling NaN
];

/// True on dart2js, where a Dart `int` is a JavaScript number.
const bool _isJs = identical(1, 1.0);

final BigInt _two53 = BigInt.two.pow(53);

Uint8List _hex(String h) => Uint8List.fromList([
  for (var i = 0; i < h.length; i += 2)
    int.parse(h.substring(i, i + 2), radix: 16),
]);

String _toHex(List<int> bytes) => [
  for (final b in bytes) b.toRadixString(16).padLeft(2, '0'),
].join();

/// [n] as a protobuf varint.
List<int> _varint(int n) {
  final out = <int>[];
  var rest = n;
  while (rest >= 0x80) {
    out.add((rest & 0x7f) | 0x80);
    rest >>= 7;
  }

  return out..add(rest);
}

/// The value of an arena whose only node is [node]'s bytes, read from the
/// wire.
MontyValue _read(List<int> node) {
  final arena = pb.Arena.fromBuffer([0x12, ..._varint(node.length), ...node]);

  return ArenaReader(arena)[0];
}

/// The bytes of the one node [value] writes.
String _written(MontyValue value) {
  final writer = ArenaWriter()..add(value);

  return _toHex(onlyItem(writer.arena.nodes).writeToBuffer());
}

/// [bits] (most significant byte first) as a double.
double _double(String bits) => ByteData.sublistView(_hex(bits)).getFloat64(0);

/// The bit pattern of [v], most significant byte first.
String _bitsOf(double v) {
  final data = ByteData(8)..setFloat64(0, v);

  return _toHex(data.buffer.asUint8List());
}

/// `MontyNode{float: bits}`: tag 7, wire type 1, eight bytes little-endian.
String _floatNode(String bits) => '39${_toHex(_hex(bits).reversed.toList())}';

BigInt _intOf(MontyValue v) => switch (v) {
  MontyInt(:final value) => BigInt.from(value),
  MontyBigInt(:final value) => value,
  _ => fail('$v is not an integer'),
};

/// The value class the reader picks: [MontyInt] within ±2^53.
MontyValue _canonical(BigInt v) =>
    v.abs() <= _two53 ? MontyInt(v.toInt()) : MontyBigInt(v);

/// A magnitude of [n] bytes, leading byte non-zero, with no repeating short
/// period.
Uint8List _magnitude(int n) {
  final bytes = Uint8List(n);
  var x = 0x2545f491;
  for (var i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    bytes[i] = x >> 16;
  }
  bytes[0] |= 0x80;

  return bytes;
}

void main() {
  group('int: the 11 zigzag vectors', () {
    for (final (value, bytes) in _intVectors) {
      final want = BigInt.parse(value);

      test('$value decodes exactly', () {
        final v = _read(_hex(bytes));
        expect(_intOf(v), want);
        expect(v.runtimeType, _canonical(want).runtimeType);
      });

      test('$value encodes as prost does', () {
        expect(_written(_canonical(want)), bytes);
        expect(_written(MontyBigInt(want)), bytes);
        // Off dart2js a MontyInt holds all of i64, past the ±2^53 that
        // _canonical uses.
        if (!_isJs) expect(_written(MontyInt(want.toInt())), bytes);
      });
    }
  });

  group('int: a Dart int beyond 64 bits (dart2js)', () {
    // On dart2js a Dart int is a double, so 2^63 and 2^64 are exact ints.
    // They take the bigint arm, as upstream's encoder does for any value
    // outside i64; -2^63 is still i64 and takes the int arm.
    const skip = _isJs ? null : 'a Dart int is 64-bit off dart2js';
    int pow2(int e) => math.pow(2, e).toInt();

    test('2^63 and 2^64 use the bigint arm', () {
      expect(
        _written(MontyInt(pow2(63))),
        _written(MontyBigInt(BigInt.two.pow(63))),
      );
      expect(_written(MontyInt(pow2(64))), '320b120901${'00' * 8}');
      expect(
        _written(MontyInt(-pow2(63) - 2048)),
        '320c0801120880${'00' * 5}0800',
      );
    }, skip: skip);

    test('-2^63 uses the int arm', () {
      expect(_written(MontyInt(-pow2(63))), '28ffffffffffffffffff01');
    }, skip: skip);
  });

  group('float: bits survive', () {
    for (final bits in _floatBits) {
      test('$bits decodes', () {
        final v = _read(_hex(_floatNode(bits)));
        expect(v, isA<MontyFloat>());
        expect(_bitsOf((v as MontyFloat).value), bits);
      });

      test('$bits encodes', () {
        expect(_written(MontyFloat(_double(bits))), _floatNode(bits));
      });

      test('$bits round-trips through the reader and writer', () {
        final v = _read(_hex(_floatNode(bits)));
        expect(_written(v), _floatNode(bits));
      });
    }
  });

  group('float: NaN sign and payload', () {
    for (final bits in _nanBits) {
      test(
        '$bits decodes to ${_isJs ? 'a NaN (dart2js)' : 'the same bits'}',
        () {
          final v = _read(_hex(_floatNode(bits))) as MontyFloat;
          expect(v.value.isNaN, isTrue);
          if (!_isJs) expect(_bitsOf(v.value), bits);
        },
      );

      test(
        '$bits encodes ${_isJs ? 'as a NaN (dart2js)' : 'as the same bits'}',
        () {
          final written = _written(MontyFloat(_double(bits)));
          expect(
            _double(_toHex(_hex(written).sublist(1).reversed.toList())).isNaN,
            isTrue,
          );
          if (!_isJs) expect(written, _floatNode(bits));
        },
      );

      test('$bits round-trips through the reader and writer', () {
        final v = _read(_hex(_floatNode(bits)));
        expect(_written(v), _floatNode(bits));
      });
    }

    test("a NaN keeps its own bits, not another NaN's", () {
      final a = _read(_hex(_floatNode('fff8000000000000')));
      final b = _read(_hex(_floatNode('7ff8000000000001')));
      final writer = ArenaWriter();
      final [x, y, z] = [
        writer.add(MontyList([a, b])),
        writer.add(b),
        writer.add(const MontyFloat(double.nan)),
      ];
      final nodes = writer.arena.nodes;
      String hexAt(int i) => _toHex(itemAt(nodes, i).writeToBuffer());
      final pair = itemAt(nodes, x).list.items;
      expect(hexAt(itemAt(pair, 0)), _floatNode('fff8000000000000'));
      final payload = _floatNode('7ff8000000000001');
      expect(hexAt(itemAt(pair, 1)), payload);
      expect(hexAt(y), payload);
      // A NaN built in Dart sends its own bits. Those of double.nan are the
      // host's (0.0 / 0.0): fff8... on x86_64, 7ff8... on arm64.
      expect(hexAt(z), _floatNode(_bitsOf(double.nan)));
    });
  });

  group('generated field types', () {
    // The generator declares these fields with a raw 64-bit type, so
    // package:protobuf hands over the wire value untouched. A regenerated
    // binding that reverted to sint64 or double would still compile, since
    // both are Int64-free at the call sites the reader uses; this reads the
    // metadata instead.
    int typeOf(GeneratedMessage m, int tag) =>
        m.info_.fieldInfo[tag]?.type ?? fail('no field $tag');

    test('MontyNode.int is uint64, MontyNode.float is fixed64', () {
      expect(typeOf(pb.MontyNode(), 5), PbFieldType.OU6);
      expect(typeOf(pb.MontyNode(), 7), PbFieldType.OF6);
    });

    test('Complex.real and Complex.imag are fixed64', () {
      expect(typeOf(pb.Complex(), 1), PbFieldType.OF6);
      expect(typeOf(pb.Complex(), 2), PbFieldType.OF6);
    });

    test('Complex parts keep proto3 presence, -0.0 and 0.0 included', () {
      final c = pb.Complex.fromBuffer(
        _hex('09${'00' * 8}11${'00' * 7}80'),
      );
      expect(c.hasReal(), isTrue);
      expect(c.hasImag(), isTrue);
      expect(_toHex(c.writeToBuffer()), '09${'00' * 8}11${'00' * 7}80');
      expect(pb.Complex().writeToBuffer(), isEmpty);
    });
  });

  group('bigint: bulk magnitude conversion', () {
    // Shifting a growing BigInt once per byte is quadratic: about 10^11
    // byte moves at 1 MiB. Converting the magnitude in one step is linear,
    // and these sizes finish in well under a second on every compiler.
    for (final size in [1 << 10, 1 << 16, 1 << 20]) {
      test('$size bytes of magnitude, both ways', () {
        final magnitude = _magnitude(size);
        final node = pb.MontyNode(
          bigint: pb.BigInt(negative: true, magnitude: magnitude),
        ).writeToBuffer();
        final clock = Stopwatch()..start();
        final v = _read(node);
        final writer = ArenaWriter()..add(v);
        clock.stop();
        final back = onlyItem(writer.arena.nodes).bigint;
        expect(back.negative, isTrue);
        expect(back.magnitude, magnitude);
        expect(_intOf(v).bitLength, size * 8);
        expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
      }, timeout: const Timeout(Duration(minutes: 1)));
    }

    test('known values: 2^(8n), 2^(8n)-1, and zero', () {
      for (final n in [9, 1000]) {
        final power = pb.MontyNode(
          bigint: pb.BigInt(magnitude: [1, ...List.filled(n, 0)]),
        ).writeToBuffer();
        expect(_intOf(_read(power)), BigInt.one << (n * 8));
        final ones = pb.MontyNode(
          bigint: pb.BigInt(magnitude: List.filled(n, 0xff)),
        ).writeToBuffer();
        expect(_intOf(_read(ones)), (BigInt.one << (n * 8)) - BigInt.one);
      }
      expect(_intOf(_read(_hex('3200'))), BigInt.zero);
    });

    test('a leading zero byte is accepted and not written back', () {
      final node = pb.MontyNode(
        bigint: pb.BigInt(magnitude: [0, 1, ...List.filled(8, 0)]),
      ).writeToBuffer();
      final v = _read(node);
      expect(_intOf(v), BigInt.one << 64);
      expect(_written(v), '320b120901${'00' * 8}');
    });
  });
}
