/// Integers and floats between Dart values and monty-proto's raw fields.
///
/// `tool/generate_proto.sh` declares `MontyNode.int` as `uint64` and
/// `MontyNode.float`, `Complex.real` and `Complex.imag` as `fixed64`, so the
/// generated bindings hold the wire's raw 64 bits for each. The conversions
/// package:protobuf would otherwise apply are done here instead, exactly, on
/// the VM, dart2js and dart2wasm:
///
/// - zigzag, with a logical shift, for the full i64 range;
/// - IEEE 754 bits to and from a double, through two 32-bit halves, so a
///   NaN from the worker keeps its sign and payload there and back (see
///   [montyFloatOf] for dart2js), and a NaN made in Dart is sent as Python's
///   `float('nan')` (see [montyFloatNode]);
/// - a big integer's magnitude to and from bytes in one step, linear in its
///   length.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';

final BigInt _int64Min = -(BigInt.one << 63);
final BigInt _int64Max = (BigInt.one << 63) - BigInt.one;

/// The largest magnitude every compiler holds exactly in a Dart `int`.
const int _exactInt = 1 << 53;

/// A node carrying the integer [value].
///
/// The `int` arm when [value] fits in i64, the `bigint` arm otherwise, as
/// upstream's encoder chooses. On dart2js an `int` can lie outside i64.
pb.MontyNode intNode(int value) => value.abs() <= _exactInt
    ? pb.MontyNode(int_5: zigzagEncode(Int64(value)))
    : bigIntNode(BigInt.from(value));

/// A node carrying the integer [value], on either arm as [intNode] chooses.
pb.MontyNode bigIntNode(BigInt value) {
  if (value >= _int64Min && value <= _int64Max) {
    return pb.MontyNode(int_5: zigzagEncode(Int64.parseInt('$value')));
  }
  // `negative` is set only when true, so the bytes match prost's, which
  // omits a proto3 default.
  final big = pb.BigInt(magnitude: magnitudeBytes(value.abs()));
  if (value.isNegative) big.negative = true;

  return pb.MontyNode(bigint: big);
}

/// The integer an `int` node carries.
BigInt intOfNode(pb.MontyNode node) =>
    BigInt.parse('${zigzagDecode(node.int_5)}');

/// The integer a `bigint` node carries.
BigInt bigIntOfNode(pb.BigInt big) {
  final magnitude = magnitudeValue(big.magnitude);

  return big.negative ? -magnitude : magnitude;
}

/// The wire bits of each NaN [montyFloatOf] decoded, for [montyFloatNode].
final Expando<Int64> _nanBits = Expando('NaN wire bits');

/// The [MontyFloat] a `float` node carries.
///
/// On the VM and dart2wasm its double holds the node's bits exactly. On
/// dart2js the double is a JavaScript number, and ECMAScript lets an engine
/// re-encode a NaN as any NaN: measured in Chrome, V8 quiets signalling NaNs,
/// drops payloads, and has turned Python's `-nan` (fff8000000000000) into
/// 7ff8000000000000. So a decoded NaN also keeps its wire bits beside it, and
/// [montyFloatNode] writes those back: a NaN that goes from Python to Dart
/// and back is exact on every compiler, though on dart2js its Dart double
/// may not show the sign or payload.
MontyFloat montyFloatOf(pb.MontyNode node) {
  final bits = node.float;
  final value = MontyFloat(bitsToDouble(bits));
  if (value.value.isNaN) _nanBits[value] = bits;

  return value;
}

/// Python's `float('nan')`, 7ff8000000000000.
final Int64 _pythonNan = Int64.fromInts(0x7ff80000, 0);

/// A node carrying [value].
///
/// A non-NaN double is sent bit for bit, `-0.0` included. A NaN that
/// [montyFloatOf] decoded is sent with the bits it arrived with. Any other
/// NaN was made in Dart, and is sent as Python's `float('nan')`, as
/// upstream's host sends a NaN: `double.nan` is `0.0 / 0.0`, whose bits are
/// the host's (fff8000000000000 on x86_64), and Python would read that as a
/// negative NaN.
pb.MontyNode montyFloatNode(MontyFloat value) => pb.MontyNode(
  float: value.value.isNaN
      ? _nanBits[value] ?? _pythonNan
      : doubleToBits(value.value),
);

/// A node carrying the double [value], bit for bit.
pb.MontyNode floatNode(double value) =>
    pb.MontyNode(float: doubleToBits(value));

/// The double a `float` node carries, bit for bit.
double floatOfNode(pb.MontyNode node) => bitsToDouble(node.float);

/// The protobuf zigzag encoding of [value], as a raw 64-bit pattern.
Int64 zigzagEncode(Int64 value) => (value << 1) ^ (value >> 63);

/// The value whose zigzag encoding is [raw].
///
/// The shift is logical: an arithmetic one, as package:protobuf 6.1.0 uses,
/// sign-extends a raw value at or above 2^63 and corrupts every |v| >= 2^62.
Int64 zigzagDecode(Int64 raw) => raw.shiftRightUnsigned(1) ^ -(raw & 1);

/// [value]'s IEEE 754 bits.
Int64 doubleToBits(double value) {
  final data = ByteData(8)..setFloat64(0, value);

  return Int64.fromInts(data.getUint32(0), data.getUint32(4));
}

/// The double whose IEEE 754 bits are [bits].
double bitsToDouble(Int64 bits) {
  final data = ByteData(8)
    ..setUint32(0, bits.shiftRightUnsigned(32).toInt())
    ..setUint32(4, (bits & 0xffffffff).toInt());

  return data.getFloat64(0);
}

/// [magnitude], a big-endian unsigned integer, as a [BigInt].
///
/// Converted through one hexadecimal string, which every compiler's
/// [BigInt.parse] reads in linear time. Leading zero bytes are accepted, and
/// no bytes is zero.
BigInt magnitudeValue(List<int> magnitude) {
  if (magnitude.isEmpty) return BigInt.zero;
  final hex = Uint8List(magnitude.length * 2);
  for (final (i, b) in magnitude.indexed) {
    hex[i * 2] = _hexDigits.codeUnitAt(b >> 4);
    hex[i * 2 + 1] = _hexDigits.codeUnitAt(b & 0xf);
  }

  return BigInt.parse(String.fromCharCodes(hex), radix: 16);
}

/// [magnitude], which must not be negative, as minimal big-endian bytes.
///
/// The inverse of [magnitudeValue], through one hexadecimal string; zero is
/// no bytes.
Uint8List magnitudeBytes(BigInt magnitude) {
  if (magnitude == BigInt.zero) return Uint8List(0);
  final hex = magnitude.toRadixString(16);
  final odd = hex.length.isOdd ? 1 : 0;
  final bytes = Uint8List((hex.length + odd) >> 1);
  for (var i = 0; i < bytes.length; i++) {
    final at = i * 2 - odd;
    final high = at < 0 ? 0 : _nibble(hex.codeUnitAt(at));
    bytes[i] = (high << 4) | _nibble(hex.codeUnitAt(at + 1));
  }

  return bytes;
}

const String _hexDigits = '0123456789abcdef';

/// The value of the lowercase hexadecimal digit [codeUnit].
int _nibble(int codeUnit) => codeUnit < 97 ? codeUnit - 48 : codeUnit - 87;
