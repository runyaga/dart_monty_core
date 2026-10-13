/// The length package:protobuf's `writeToBuffer` would produce for a message,
/// computed without encoding it.
///
/// Upstream sizes an outbound frame with `Message::encoded_len` and rejects
/// it before allocating (monty-proto 1.1.0, `frame.rs:116-143`). Dart's
/// protobuf has no such method: its writer builds the whole body in chunks
/// before the length is known. [EncodedLength.of] walks the message the way
/// `CodedBufferWriter.writeField` does, field by field, and counts instead of
/// writing.
///
/// A message reached more than once is counted once and reused, so a request
/// that refers to one large value many times costs its size once to measure,
/// however long its encoding would be.
///
/// Internal to the package; nothing here is exported.
library;

import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart';

/// Encoded lengths, as package:protobuf's writer produces them.
abstract final class EncodedLength {
  /// The number of bytes `message.writeToBuffer()` would return.
  ///
  /// Throws [UnsupportedError] for a map, a `sint32` or `sint64`, or a
  /// message group: the schema has none, as generated here. Extensions are not
  /// counted; the schema declares none.
  static int of(GeneratedMessage message) => _Sizer().message(message);

  /// Bytes of [value] as an unsigned varint: 1 to 5 for a 32-bit value.
  static int varint(int value) {
    var length = 1;
    for (var v = value; v >= 0x80; v = v ~/ 0x80) {
      length++;
    }

    return length;
  }

  /// Bytes of the 64-bit two's-complement pattern of [value] as a varint.
  static int varint64(Int64 value) {
    final hi = (value >> 32).toUnsigned(32).toInt();
    if (hi == 0) return varint(value.toUnsigned(32).toInt());
    var bits = 32;
    for (var v = hi; v > 0; v = v ~/ 2) {
      bits++;
    }

    return (bits + 6) ~/ 7;
  }

  /// Bytes of [value] in UTF-8 as `Utf8Encoder` writes it: an unpaired
  /// surrogate becomes U+FFFD, three bytes.
  static int utf8(String value) {
    var length = 0;
    for (var i = 0; i < value.length; i++) {
      final unit = value.codeUnitAt(i);
      final paired =
          unit & 0xFC00 == 0xD800 &&
          i + 1 < value.length &&
          value.codeUnitAt(i + 1) & 0xFC00 == 0xDC00;
      length += switch (unit) {
        < 0x80 => 1,
        < 0x800 => 2,
        _ when paired => 4,
        _ => 3,
      };
      if (paired) i++;
    }

    return length;
  }
}

/// Fixed-width value types: their size on the wire.
const Map<int, int> _fixedSizes = {
  PbFieldType.BOOL_BIT: 1,
  PbFieldType.DOUBLE_BIT: 8,
  PbFieldType.FIXED64_BIT: 8,
  PbFieldType.SFIXED64_BIT: 8,
  PbFieldType.FLOAT_BIT: 4,
  PbFieldType.FIXED32_BIT: 4,
  PbFieldType.SFIXED32_BIT: 4,
};

/// One measurement: memoises each message reached, by identity.
final class _Sizer {
  final _sizes = Map<GeneratedMessage, int>.identity();

  int message(GeneratedMessage message) {
    final known = _sizes[message];
    if (known != null) return known;
    var size = 0;
    for (final info in message.info_.sortedByTag) {
      final Object? value = message.getFieldOrNull(info.tagNumber);
      if (value != null) size += _field(info.tagNumber, info.type, value);
    }
    size += _unknown(message.unknownFields);

    return _sizes[message] = size;
  }

  /// `CodedBufferWriter.writeField`, counted.
  int _field(int number, int fieldType, Object value) {
    final valueType = PbFieldType.baseType(fieldType);
    if (fieldType & PbFieldType.MAP_BIT != 0) {
      throw UnsupportedError('EncodedLength: map field $number');
    }
    if (fieldType & PbFieldType.REPEATED_BIT == 0) {
      return _single(number, valueType, value);
    }
    final items = value is List<Object> ? value : const <Object>[];
    if (fieldType & PbFieldType.PACKED_BIT == 0) {
      return items.fold(
        0,
        (sum, item) => sum + _single(number, valueType, item),
      );
    }
    if (items.isEmpty) return 0;
    final body = items.fold<int>(
      0,
      (sum, item) => sum + _value(valueType, item),
    );

    return _tag(number) + EncodedLength.varint(body) + body;
  }

  /// `CodedBufferWriter._writeValue`: the tag, the value, and a group's end
  /// tag.
  int _single(int number, int valueType, Object value) =>
      _tag(number) +
      _value(valueType, value) +
      (valueType == PbFieldType.GROUP_BIT ? _tag(number) : 0);

  /// `CodedBufferWriter._writeValueAs`, counted.
  int _value(int valueType, Object value) =>
      _fixedSizes[valueType] ??
      switch (value) {
        final List<int> bytes => _delimited(bytes.length),
        final String text => _delimited(EncodedLength.utf8(text)),
        final UnknownFieldSet group => _unknown(group),
        final GeneratedMessage message
            when valueType == PbFieldType.MESSAGE_BIT =>
          _delimited(this.message(message)),
        _ => _varintValue(valueType, value),
      };

  /// The varint types, counted as the writer encodes each.
  int _varintValue(int valueType, Object value) => switch ((valueType, value)) {
    (PbFieldType.ENUM_BIT, final ProtobufEnum e) => EncodedLength.varint(
      e.value & 0xffffffff,
    ),
    (PbFieldType.INT32_BIT, final int v) => EncodedLength.varint64(Int64(v)),
    (PbFieldType.UINT32_BIT, final int v) => EncodedLength.varint(v),
    (PbFieldType.INT64_BIT || PbFieldType.UINT64_BIT, final Int64 v) =>
      EncodedLength.varint64(v),
    _ => throw UnsupportedError('EncodedLength: field type $valueType'),
  };

  /// `UnknownFieldSet.writeToCodedBufferWriter`, counted.
  int _unknown(UnknownFieldSet fields) {
    if (fields.isEmpty) return 0;
    var size = 0;
    for (final MapEntry(key: number, value: field) in fields.asMap().entries) {
      final tag = _tag(number);
      size +=
          field.varints.fold<int>(
            0,
            (s, v) => s + tag + EncodedLength.varint64(v),
          ) +
          field.fixed32s.length * (tag + 4) +
          field.fixed64s.length * (tag + 8) +
          field.lengthDelimited.fold<int>(
            0,
            (s, b) => s + tag + _delimited(b.length),
          ) +
          field.groups.fold<int>(0, (s, g) => s + tag * 2 + _unknown(g));
    }

    return size;
  }

  static int _tag(int number) => EncodedLength.varint(number * 8);

  static int _delimited(int length) => EncodedLength.varint(length) + length;
}
