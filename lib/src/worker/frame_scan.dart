/// The wire pre-scan every `ChildEvent` frame passes before package:protobuf
/// parses it.
///
/// Upstream decodes a frame with prost under a decode budget (monty-proto
/// 1.1.0, `frame.rs`, `decode_budget.rs`, `budgeted_prost.rs`, `wire.rs`).
/// package:protobuf accepts frames prost rejects and reads some valid values
/// differently, so the parent would see a frame upstream's parent never sees.
/// [FrameScan.childEvent] walks the frame once, with prost's rules, and:
///
/// - rejects what prost rejects: malformed and overflowing varints, keys
///   beyond 32 bits, a known field with the wrong wire type, unmatched group
///   ends, the recursion limit, a length past the frame;
/// - rejects invalid UTF-8 in every string field, as `String::from_utf8`
///   does (package:protobuf decodes it with `allowMalformed`);
/// - charges every allocation upstream's decoder would make against
///   upstream's budget, before it would be made, and rejects a frame that
///   exhausts it ([Frame.maxDecodeBytes]);
/// - runs upstream's per-node check ([checkNode]) on every arena node as its
///   merge completes, including nodes in an event arm a later arm discards,
///   and the `FunctionCall.object_id` check;
/// - rewrites, in place and at the same length, the two kinds of varint
///   package:protobuf would read differently: a boolean whose low 32 bits are
///   zero but which is not zero (prost reads true, package:protobuf false),
///   and a `PrintStream` number no member names (prost keeps the last number,
///   which reads as unspecified; package:protobuf keeps the earlier member).
///
/// A frame that passes is then parsed by package:protobuf into the values
/// prost decodes, through a reader that keeps a string's leading U+FEFF:
/// Dart's UTF-8 decoder drops it, `String::from_utf8` keeps it. Unknown
/// fields, which prost skips without allocating and package:protobuf would
/// keep, are removed from a copy before that parse, so a frame cannot make
/// the parent hold what upstream's budget never counted. The allocation sizes
/// are upstream's on a 64-bit host.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/worker/arena_nodes.dart';
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:protobuf/protobuf.dart';

/// Scans and decodes `ChildEvent` frames with upstream's semantics.
abstract final class FrameScan {
  /// prost's `RECURSION_LIMIT`.
  static const int recursionLimit = 100;

  /// Checks and normalises the `ChildEvent` frame [body] in place; returns
  /// the bytes upstream's decoder charges against its budget.
  ///
  /// Throws [FrameDecodeException] for a frame upstream rejects, including
  /// one whose charges exceed [budget] (at most [Frame.maxDecodeBytes]).
  static int childEvent(Uint8List body, {int budget = Frame.maxDecodeBytes}) =>
      _Scan(body, math.min(budget, Frame.maxDecodeBytes)).run();

  /// [childEvent], then package:protobuf's parse of the normalised [body].
  ///
  /// Takes ownership of [body], which is rewritten in place. A parse error
  /// after a clean scan would be a divergence the scan missed; it is reported
  /// the same way.
  static pb.ChildEvent decodeChildEvent(
    Uint8List body, {
    int budget = Frame.maxDecodeBytes,
  }) {
    final scan = _Scan(body, math.min(budget, Frame.maxDecodeBytes))..run();
    final pb.ChildEvent event;
    try {
      event = _parse(pb.ChildEvent(), _withoutUnknowns(body, scan));
    } on InvalidProtocolBufferException catch (error) {
      throw FrameDecodeException(error.message);
    }
    if (event.hasFunctionCall() && event.functionCall.hasPosition()) {
      final position = event.functionCall.position;
      position.filename = _cutFilename(position.filename);
    }

    return event;
  }
}

/// [body] without its unknown fields, once [scan] has passed it.
Uint8List _withoutUnknowns(Uint8List body, _Scan scan) => scan.unknowns == 0
    ? body
    : _Compactor(body, 0, body.length, _childEvent).run();

/// upstream's `SourceRange::MAX_FILENAME_LEN`, in UTF-8 bytes.
const int _maxFilenameLength = 256;

/// [name] cut to at most [_maxFilenameLength] bytes of UTF-8 on a character
/// boundary, as `SourceRange::new` cuts the call position it decodes.
String _cutFilename(String name) {
  var bytes = 0;
  var units = 0;
  while (units < name.length) {
    final unit = name.codeUnitAt(units);
    final (size, width) = switch (unit) {
      < 0x80 => (1, 1),
      < 0x800 => (2, 1),
      _ when unit & 0xFC00 == 0xD800 => (4, 2),
      _ => (3, 1),
    };
    if (bytes + size > _maxFilenameLength) break;
    bytes += size;
    units += width;
  }

  return units < name.length ? name.substring(0, units) : name;
}

/// [message] merged from [bytes] as `fromBuffer` merges it, but with every
/// string decoded as Rust decodes it.
T _parse<T extends GeneratedMessage>(T message, Uint8List bytes) {
  final reader = _StrictReader(bytes);
  message.mergeFromCodedBufferReader(reader);
  reader.checkLastTagWas(0);

  return message;
}

/// package:protobuf's reader, with strings that keep a leading U+FEFF.
///
/// `Utf8Decoder` drops a byte-order mark at the start of what it converts;
/// prost's `String::from_utf8` keeps it. The scan has already checked every
/// string is UTF-8.
final class _StrictReader extends CodedBufferReader {
  _StrictReader(super.buffer);

  @override
  String readString() {
    final bytes = readBytesAsView();
    final text = utf8.decode(bytes);
    final bom =
        bytes.length >= 3 &&
        bytes.first == 0xEF &&
        bytes.elementAtOrNull(1) == 0xBB &&
        bytes.elementAtOrNull(2) == 0xBF;

    return bom ? '\u{FEFF}$text' : text;
  }
}

// Wire types.
const int _varint = 0;
const int _fixed64 = 1;
const int _delimited = 2;
const int _startGroup = 3;
const int _endGroup = 4;
const int _fixed32 = 5;

const List<String> _wireNames = [
  'Varint',
  'SixtyFourBit',
  'LengthDelimited',
  'StartGroup',
  'EndGroup',
  'ThirtyTwoBit',
];

// Upstream's allocation sizes, in bytes, on a 64-bit host: `size_of` of the
// element each growing buffer holds, measured against monty-proto 1.1.0.

/// `monty_types::unstable::MontyNode`, an arena slot.
const int _nodeSize = 72;

/// `ClassTypeNode`, boxed for each class `type` node.
const int _classBoxSize = 72;

/// `pb::PrintSegment`.
const int _segmentSize = 32;

/// `pb::StackFrame`.
const int _stackFrameSize = 104;

/// `String`, a `field_names` slot.
const int _stringSize = 24;

/// `u32`, a `pending_call_ids` slot.
const int _u32Size = 4;

/// A node reference: a 4-byte `NodeId` plus upstream's host-container
/// allowance, `REFERENCE_COST` (`2 * size_of::<usize>()`), in all.
const int _referenceCost = 16;

/// A key and value reference.
const int _pairCost = _referenceCost * 2;

/// The fewest bytes a node occupies; caps an arena's `node_count` hint.
const int _minNodeWireBytes = 4;

/// The `PrintStream` numbers package:protobuf knows.
const int _printStreamMax = 2;

Never _fail(String reason) => throw FrameDecodeException(reason);

/// A growing buffer's length and capacity, in elements.
final class _Vec {
  int length = 0;
  int capacity = 0;
}

/// What upstream holds for one message while it merges: per field, a
/// string's or bytes' capacity, a sub-message, or a buffer; per oneof, the
/// field set.
final class _State {
  Map<int, Object>? _slots;

  Map<int, Object> get slots => _slots ??= {};

  /// The kind a merged `MontyNode` ends with: its last oneof member.
  ///
  /// package:protobuf numbers `MontyNode_Kind` in field order, so field `n`
  /// is `values[n - 1]`.
  pb.MontyNode_Kind get nodeKind => switch (_slots?[-1]) {
    final int field =>
      pb.MontyNode_Kind.values.elementAtOrNull(field - 1) ??
          pb.MontyNode_Kind.notSet,
    _ => pb.MontyNode_Kind.notSet,
  };

  int capacity(int field) => switch (_slots?[field]) {
    final int capacity => capacity,
    _ => 0,
  };

  _State child(int field) => switch (slots[field]) {
    final _State state => state,
    _ => slots[field] = _State(),
  };

  _Vec vec(int field) => switch (slots[field]) {
    final _Vec vec => vec,
    _ => slots[field] = _Vec(),
  };

  /// Makes [field] its oneof's member; switching members drops the old one.
  void select(int oneof, int field) {
    final current = slots[-oneof];
    if (current == field) return;
    if (current is int) slots.remove(current);
    slots
      ..remove(field)
      ..[-oneof] = field;
  }
}

/// A message being merged: where it ends, and what completes it.
final class _Frame {
  const _Frame(
    this.schema,
    this.state,
    this.start,
    this.end,
    this.depth,
    this.done, {
    this.unknowns = 0,
  });

  final _Message schema;
  final _State state;
  final int start;
  final int end;

  /// prost's remaining recursion for this message's fields.
  final int depth;
  final void Function(_Frame frame)? done;

  /// Unknown fields the scan had met when this message began.
  final int unknowns;
}

/// The frame's bytes, read as prost reads them and rewritten in place.
final class _Wire {
  _Wire(Uint8List bytes)
    : _data = ByteData.sublistView(bytes),
      length = bytes.length;

  final int length;
  int pos = 0;

  /// The last varint read: low and high 32 bits.
  int lo = 0;
  int hi = 0;

  /// The last key read.
  int field = 0;
  int wire = 0;

  final ByteData _data;

  /// Bytes left in the frame.
  int get left => length - pos;

  /// The byte at [index].
  int at(int index) => _data.getUint8(index);

  /// prost's `decode_varint`: at most ten bytes, the tenth at most 1.
  void readVarint() {
    var low = 0;
    var high = 0;
    for (var i = 0; i < 10 && pos < length; i++) {
      final byte = _data.getUint8(pos++);
      final bits = byte & 0x7f;
      if (i < 4) {
        low += bits * (1 << (i * 7));
      } else if (i == 4) {
        low += (bits & 0x0f) * 0x10000000;
        high = bits >> 4;
      } else {
        high += bits * (1 << (i * 7 - 32));
      }
      if (byte < 0x80) {
        if (i == 9 && byte > 1) break;
        lo = low;
        hi = high;

        return;
      }
    }
    _fail('invalid varint');
  }

  /// prost's `decode_key`.
  void readKey() {
    readVarint();
    if (hi != 0) _fail('invalid key value: ${hi * 0x100000000 + lo}');
    wire = lo & 7;
    if (wire > _fixed32) _fail('invalid wire type value: $wire');
    field = lo ~/ 8;
    if (field == 0) _fail('invalid tag value: 0');
  }

  /// A length prefix: at most what is left of the frame. Returns the end.
  int readLength() {
    readVarint();
    if (hi != 0 || lo > left) _fail('buffer underflow');

    return pos + lo;
  }

  /// prost's `check_wire_type`.
  void expectWire(int expected) {
    if (wire == expected) return;
    _fail(
      'invalid wire type: ${_wireNames.elementAtOrNull(wire)} '
      '(expected ${_wireNames.elementAtOrNull(expected)})',
    );
  }

  /// A singular varint field.
  void readVarintField() {
    expectWire(_varint);
    readVarint();
  }

  /// A `bool`: prost reads every bit, package:protobuf the low 32.
  void readBool() {
    final start = pos;
    readVarintField();
    if (lo == 0 && hi != 0) _rewrite(start, 1);
  }

  /// A `PrintStream`: prost keeps the low 32 bits as an i32, as
  /// package:protobuf does, and any number but 0 to 2, negative ones
  /// included, names no member and reads as unspecified.
  void readPrintStream() {
    final start = pos;
    readVarintField();
    if (lo > _printStreamMax) _rewrite(start, 0);
  }

  void readFixed64() {
    expectWire(_fixed64);
    if (left < 8) _fail('buffer underflow');
    pos += 8;
  }

  /// prost's `skip_field` for an unknown field, at recursion [depth].
  void skip(int depth) {
    if (depth == 0) _fail('recursion limit reached');
    if (wire != _startGroup) {
      _skipValue();

      return;
    }
    final open = [field];
    for (var inner = open.lastOrNull; inner != null; inner = open.lastOrNull) {
      readKey();
      if (wire == _endGroup) {
        if (field != inner) _fail('unexpected end group tag');
        open.removeLast();
        continue;
      }
      if (depth == open.length) _fail('recursion limit reached');
      if (wire == _startGroup) {
        open.add(field);
      } else {
        _skipValue();
      }
    }
  }

  /// Whether bytes [pos] to [end] are UTF-8, as Rust's `str::from_utf8`
  /// decides: no overlong forms, surrogates, code points beyond U+10FFFF,
  /// or cut sequences.
  bool isUtf8(int end) {
    var i = pos;
    while (i < end) {
      final (size, low, high) = _utf8Lead(_data.getUint8(i));
      if (end - i < size) return false;
      if (size > 1) {
        final second = _data.getUint8(i + 1);
        if (second < low || second > high) return false;
        for (var k = 2; k < size; k++) {
          if (_data.getUint8(i + k) & 0xC0 != 0x80) return false;
        }
      }
      i += size;
    }

    return true;
  }

  /// Rewrites the varint from [start] to [pos] as [value] (0 or 1), at the
  /// same length.
  void _rewrite(int start, int value) {
    _data.setUint8(start, value | (pos - start > 1 ? 0x80 : 0));
    for (var i = start + 1; i < pos; i++) {
      _data.setUint8(i, i < pos - 1 ? 0x80 : 0);
    }
  }

  void _skipValue() {
    switch (wire) {
      case _varint:
        readVarint();
      case _delimited:
        pos = readLength();
      case _fixed64 || _fixed32:
        final size = wire == _fixed64 ? 8 : 4;
        if (size > left) _fail('buffer underflow');
        pos += size;
      default:
        _fail('unexpected end group tag');
    }
  }
}

/// A UTF-8 lead byte: the sequence's length, and the range its second byte
/// must fall in. A length of 0 is a byte no sequence starts with.
(int, int, int) _utf8Lead(int lead) => switch (lead) {
  < 0x80 => (1, 0, 0),
  < 0xC2 => (0x7fffffff, 0, 0),
  < 0xE0 => (2, 0x80, 0xBF),
  0xE0 => (3, 0xA0, 0xBF),
  0xED => (3, 0x80, 0x9F),
  < 0xF0 => (3, 0x80, 0xBF),
  0xF0 => (4, 0x90, 0xBF),
  < 0xF4 => (4, 0x80, 0xBF),
  0xF4 => (4, 0x80, 0x8F),
  _ => (0x7fffffff, 0, 0),
};

/// Upstream's decode budget: every allocation charged before it is made.
final class _Budget {
  _Budget(this._left);

  int charged = 0;
  int _left;

  void charge(int bytes) {
    if (bytes > _left) _fail('frame exceeds decode memory budget');
    _left -= bytes;
    charged += bytes;
  }

  /// `BudgetVec::try_reserve_slot`: doubles a full buffer, at least to 4,
  /// charging the whole new buffer.
  void reserveSlot(_Vec vec, int size) {
    if (vec.length < vec.capacity) return;
    final capacity = math.max(vec.capacity * 2, 4);
    charge(capacity * size);
    vec.capacity = capacity;
  }

  /// `BudgetVec::try_reserve_capacity`: grows to exactly [capacity].
  void reserveExact(_Vec vec, int capacity, int size) {
    if (capacity <= vec.capacity) return;
    charge(capacity * size);
    vec.capacity = capacity;
  }
}

/// One pass over a frame: the messages being merged, innermost last.
final class _Scan {
  _Scan(Uint8List bytes, int budget)
    : wire = _Wire(bytes),
      budget = _Budget(budget),
      _bytes = bytes;

  final _Wire wire;
  final _Budget budget;

  /// Unknown fields met so far.
  int unknowns = 0;

  final Uint8List _bytes;
  final _stack = <_Frame>[];

  int run() {
    _stack.add(
      _Frame(
        _childEvent,
        _State(),
        0,
        wire.length,
        FrameScan.recursionLimit,
        null,
      ),
    );
    for (
      var frame = _stack.lastOrNull;
      frame != null;
      frame = _stack.lastOrNull
    ) {
      if (wire.pos >= frame.end) {
        _complete(frame);
        continue;
      }
      wire.readKey();
      final field = wire.field;
      final spec = frame.schema.fields[field];
      if (spec == null) {
        wire.skip(frame.depth);
        unknowns++;
        continue;
      }
      if (spec.oneof != 0) frame.state.select(spec.oneof, field);
      spec.read(this, frame, field);
    }

    return budget.charged;
  }

  /// prost's `encoding::message::merge`: pushes [schema]'s frame.
  void pushMessage(
    _Frame parent,
    _Message schema,
    _State state, [
    void Function(_Frame frame)? done,
  ]) {
    wire.expectWire(_delimited);
    if (parent.depth == 0) _fail('recursion limit reached');
    final end = wire.readLength();
    _stack.add(
      _Frame(
        schema,
        state,
        wire.pos,
        end,
        parent.depth - 1,
        done,
        unknowns: unknowns,
      ),
    );
  }

  /// A `string` or `bytes` field into the buffer [state] holds for [field]:
  /// a longer value replaces it, charged in full.
  ///
  /// Returns where the value starts.
  int readBytesField(_State state, int field, {required bool utf8}) {
    wire.expectWire(_delimited);
    final end = wire.readLength();
    final start = wire.pos;
    final length = end - start;
    if (length > state.capacity(field)) {
      budget.charge(length);
      state.slots[field] = length;
    }
    if (utf8 && !wire.isUtf8(end)) {
      _fail('invalid string value: data is not UTF-8 encoded');
    }
    wire.pos = end;

    return start;
  }

  /// Completes one `FunctionCall.position`: upstream converts it to a
  /// `SourceRange` after every occurrence, which copies its filename cut to
  /// 256 bytes, so the next occurrence finds a buffer of exactly that length.
  void completePosition(_Frame frame) {
    final slots = frame.state.slots;
    final start = slots.remove(_filenameStart);
    final end = slots.remove(_filenameEnd);
    if (start is! int || end is! int) return;
    var cut = math.min(end - start, _maxFilenameLength);
    // Back to a character boundary: a continuation byte is 10xxxxxx.
    while (start + cut < end && wire.at(start + cut) & 0xC0 == 0x80) {
      cut--;
    }
    slots[_filename] = cut;
  }

  /// A packed or unpacked run of `uint32`s into [vec]: node references
  /// charged up front ([referenceCost] non-null), or `u32`s one by one.
  void readUint32s(_Vec vec, {required int? referenceCost}) {
    if (wire.wire != _delimited) {
      wire.readVarintField();
      _pushOne(vec, referenceCost);

      return;
    }
    final end = wire.readLength();
    if (referenceCost != null) {
      budget.reserveExact(vec, vec.length + end - wire.pos, referenceCost);
    }
    while (wire.pos < end) {
      wire.readVarint();
      _pushOne(vec, referenceCost);
    }
    if (wire.pos != end) _fail('delimited length exceeded');
  }

  /// An arena's `node_count` hint: reserves up to one slot per four bytes
  /// left in the frame, once, before the first node.
  void readNodeCount(_Vec nodes) {
    wire.readVarintField();
    if (nodes.capacity != 0) return;
    final cap = wire.left ~/ _minNodeWireBytes;
    budget.reserveExact(nodes, math.min(wire.lo, cap), _nodeSize);
  }

  /// Completes an arena node: upstream's `node_from_proto`, then its slot.
  ///
  /// Only a node of a kind [checkNode] has rules for, or whose conversion
  /// allocates, is parsed to be checked; the reader checks the final arena
  /// again.
  void completeNode(_Frame frame, _Vec nodes) {
    final kind = frame.state.nodeKind;
    if (checksKind(kind) || kind == pb.MontyNode_Kind.bigint) {
      final node = _parse(pb.MontyNode(), _body(frame));
      try {
        checkNode(node);
      } on FormatException catch (error) {
        _fail(error.message);
      }
      _chargeConversion(node);
    }
    budget.reserveSlot(nodes, _nodeSize);
    nodes.length++;
  }

  /// `WireFunctionCall`'s `object_id`: exactly 16 bytes.
  void completeObjectId(_Frame frame) {
    final length = _parse(pb.Uuid(), _body(frame)).data.length;
    if (length != 16) {
      _fail(
        'invalid value for FunctionCall.object_id: uuid must be 16 bytes, '
        'got $length',
      );
    }
  }

  /// [frame]'s message bytes, without unknown fields if it had any.
  Uint8List _body(_Frame frame) => unknowns == frame.unknowns
      ? Uint8List.sublistView(_bytes, frame.start, frame.end)
      : _Compactor(_bytes, frame.start, frame.end, frame.schema).run();

  void _complete(_Frame frame) {
    if (wire.pos != frame.end) _fail('delimited length exceeded');
    _stack.removeLast();
    frame.done?.call(frame);
  }

  void _pushOne(_Vec vec, int? referenceCost) {
    budget.reserveSlot(vec, referenceCost ?? _u32Size);
    vec.length++;
  }

  /// What `node_from_proto` allocates: a big integer's limbs, a class box.
  void _chargeConversion(pb.MontyNode node) {
    switch (node.whichKind()) {
      case pb.MontyNode_Kind.bigint:
        final magnitude = node.bigint.magnitude;
        final first = magnitude.indexWhere((byte) => byte != 0);
        if (first < 0) return;
        final length = magnitude.length - first;
        budget.charge(math.max((length + 7) ~/ 8 * 8, 32));
      case pb.MontyNode_Kind.type:
        final origin = node.type.origin;
        if (origin == originSandbox || origin == originHost) {
          budget.charge(_classBoxSize);
        }
      case _:
        break;
    }
  }
}

/// A copy of a scanned message without its unknown fields.
///
/// Each length prefix keeps its width, written as a padded varint of the new,
/// never larger, length, so the copy is built in one pass. The message has
/// passed the scan, so nothing here can fail.
final class _Compactor {
  _Compactor(Uint8List bytes, int start, this._end, this._schema)
    : _src = bytes,
      _wire = _Wire(bytes)..pos = start,
      _out = Uint8List(_end - start);

  final Uint8List _src;
  final _Wire _wire;
  final Uint8List _out;
  final int _end;
  final _Message _schema;
  int _written = 0;

  /// The messages open: schema, end in the source, where the length prefix
  /// is in the copy, and its width.
  final _open = <(_Message, int, int, int)>[];

  Uint8List run() {
    _open.add((_schema, _end, -1, 0));
    for (var top = _open.lastOrNull; top != null; top = _open.lastOrNull) {
      final (schema, end, prefix, width) = top;
      if (_wire.pos < end) {
        _field(schema);
        continue;
      }
      _open.removeLast();
      if (prefix >= 0) _patch(prefix, width);
    }

    return Uint8List.sublistView(_out, 0, _written);
  }

  void _field(_Message schema) {
    final key = _wire.pos;
    _wire.readKey();
    final spec = schema.fields[_wire.field];
    final message = spec?.message;
    if (spec == null) {
      _wire.skip(FrameScan.recursionLimit);
    } else if (message == null) {
      _wire._skipValue();
      _copy(key, _wire.pos);
    } else {
      final prefix = _wire.pos;
      final end = _wire.readLength();
      _copy(key, prefix);
      final width = _wire.pos - prefix;
      _open.add((message, end, _written, width));
      _written += width;
    }
  }

  void _copy(int from, int to) {
    _out.setRange(_written, _written + to - from, _src, from);
    _written += to - from;
  }

  /// Writes the length of the message just closed, padded to [width].
  void _patch(int prefix, int width) {
    final out = ByteData.sublistView(_out);
    var length = _written - prefix - width;
    for (var i = 0; i < width; i++) {
      out.setUint8(prefix + i, length & 0x7f | (i < width - 1 ? 0x80 : 0));
      length >>= 7;
    }
  }
}

/// A message's fields, by number.
final class _Message {
  const _Message(this.fields);

  final Map<int, _Spec> fields;
}

/// How one field reads.
sealed class _Spec {
  const _Spec({this.oneof = 0});

  /// The oneof this field belongs to, or 0.
  final int oneof;

  /// The message this field holds, for a message field.
  _Message? get message => null;

  void read(_Scan scan, _Frame frame, int field);
}

/// An integer, an enum number prost keeps as is, or a 32-bit truncation
/// both libraries make alike.
final class _VarintSpec extends _Spec {
  const _VarintSpec({super.oneof});

  @override
  void read(_Scan scan, _Frame frame, int field) => scan.wire.readVarintField();
}

final class _BoolSpec extends _Spec {
  const _BoolSpec({super.oneof});

  @override
  void read(_Scan scan, _Frame frame, int field) => scan.wire.readBool();
}

final class _PrintStreamSpec extends _Spec {
  const _PrintStreamSpec();

  @override
  void read(_Scan scan, _Frame frame, int field) => scan.wire.readPrintStream();
}

final class _Fixed64Spec extends _Spec {
  const _Fixed64Spec({super.oneof});

  @override
  void read(_Scan scan, _Frame frame, int field) => scan.wire.readFixed64();
}

final class _BytesSpec extends _Spec {
  const _BytesSpec({required this.utf8, super.oneof});

  final bool utf8;

  @override
  void read(_Scan scan, _Frame frame, int field) =>
      scan.readBytesField(frame.state, field, utf8: utf8);
}

/// A singular message, merged into the one already held.
final class _MessageSpec extends _Spec {
  const _MessageSpec(this.message, {super.oneof});

  @override
  final _Message message;

  @override
  void read(_Scan scan, _Frame frame, int field) =>
      scan.pushMessage(frame, message, frame.state.child(field));
}

/// A repeated message: a slot of [size] bytes reserved before it decodes.
final class _MessagesSpec extends _Spec {
  const _MessagesSpec(this.message, this.size);

  @override
  final _Message message;
  final int size;

  @override
  void read(_Scan scan, _Frame frame, int field) {
    final vec = frame.state.vec(field);
    scan.wire.expectWire(_delimited);
    scan.budget.reserveSlot(vec, size);
    scan.pushMessage(frame, message, _State(), (_) => vec.length++);
  }
}

/// A repeated string: a `String` slot, then the string.
final class _StringsSpec extends _Spec {
  const _StringsSpec();

  @override
  void read(_Scan scan, _Frame frame, int field) {
    final vec = frame.state.vec(field);
    scan.wire.expectWire(_delimited);
    scan.budget.reserveSlot(vec, _stringSize);
    scan.readBytesField(_State(), 0, utf8: true);
    vec.length++;
  }
}

/// A repeated `uint32`: node references ([references]) or plain numbers.
final class _Uint32sSpec extends _Spec {
  const _Uint32sSpec({required this.references});

  final bool references;

  @override
  void read(_Scan scan, _Frame frame, int field) => scan.readUint32s(
    frame.state.vec(field),
    referenceCost: references ? _referenceCost : null,
  );
}

/// A repeated `NodePair`, each charged as two references once decoded.
final class _PairsSpec extends _Spec {
  const _PairsSpec();

  @override
  _Message get message => _nodePair;

  @override
  void read(_Scan scan, _Frame frame, int field) {
    final vec = frame.state.vec(field);
    scan.pushMessage(frame, _nodePair, _State(), (_) {
      scan.budget.reserveSlot(vec, _pairCost);
      vec.length++;
    });
  }
}

/// `Arena.nodes`: each node checked as its merge completes.
final class _NodesSpec extends _Spec {
  const _NodesSpec();

  @override
  _Message get message => _montyNode;

  @override
  void read(_Scan scan, _Frame frame, int field) {
    final vec = frame.state.vec(field);
    scan.pushMessage(
      frame,
      _montyNode,
      _State(),
      (node) => scan.completeNode(node, vec),
    );
  }
}

/// `Arena.node_count`.
final class _NodeCountSpec extends _Spec {
  const _NodeCountSpec();

  @override
  void read(_Scan scan, _Frame frame, int field) =>
      scan.readNodeCount(frame.state.vec(_arenaNodes));
}

/// `FunctionCall.position`: merged, then converted (see
/// [_Scan.completePosition]).
final class _PositionSpec extends _Spec {
  const _PositionSpec();

  @override
  _Message get message => _callPosition;

  @override
  void read(_Scan scan, _Frame frame, int field) => scan.pushMessage(
    frame,
    _callPosition,
    frame.state.child(field),
    scan.completePosition,
  );
}

/// A call position's filename: a string, whose last value this occurrence
/// is remembered for [_Scan.completePosition].
final class _FilenameSpec extends _Spec {
  const _FilenameSpec();

  @override
  void read(_Scan scan, _Frame frame, int field) {
    final start = scan.readBytesField(frame.state, field, utf8: true);
    frame.state.slots
      ..[_filenameStart] = start
      ..[_filenameEnd] = scan.wire.pos;
  }
}

/// `FunctionCall.object_id`: a fresh `Uuid` each time, checked.
final class _ObjectIdSpec extends _Spec {
  const _ObjectIdSpec();

  @override
  _Message get message => _uuid;

  @override
  void read(_Scan scan, _Frame frame, int field) =>
      scan.pushMessage(frame, _uuid, _State(), scan.completeObjectId);
}

// The schema: monty.proto at the pinned commit, as upstream's generated and
// hand-written decoders read the messages a `ChildEvent` can hold.

const _Spec _int = _VarintSpec();
const _Spec _bool = _BoolSpec();
const _Spec _double = _Fixed64Spec();
const _Spec _str = _BytesSpec(utf8: true);
const _Spec _bytes = _BytesSpec(utf8: false);

const int _arenaNodes = 2;

const _Message _unit = _Message({});
const _Message _uuid = _Message({1: _bytes});
const _Message _nodePair = _Message({1: _int, 2: _int});
const _Message _indexes = _Message({1: _Uint32sSpec(references: true)});
const _Message _nodePairs = _Message({1: _PairsSpec()});
const _Message _bigInt = _Message({1: _bool, 2: _bytes});
const _Message _complex = _Message({1: _double, 2: _double});
const _Message _namedTuple = _Message({
  1: _str,
  2: _StringsSpec(),
  3: _Uint32sSpec(references: true),
});
const _Message _date = _Message({1: _int, 2: _int, 3: _int});
const _Message _dateTime = _Message({
  1: _int,
  2: _int,
  3: _int,
  4: _int,
  5: _int,
  6: _int,
  7: _int,
  8: _int,
  9: _str,
});
const _Message _time = _Message({
  1: _int,
  2: _int,
  3: _int,
  4: _int,
  5: _int,
  6: _str,
  7: _int,
});
const _Message _timeDelta = _Message({1: _int, 2: _int, 3: _int});
const _Message _timeZone = _Message({1: _int, 2: _str});
const _Message _exception = _Message({1: _str, 2: _str});
const _Message _fileHandle = _Message({1: _str, 2: _str, 3: _int});
const _Message _type = _Message({
  1: _str,
  2: _MessageSpec(_uuid),
  3: _int,
  4: _bool,
  5: _MessageSpec(_nodePairs),
});
const _Message _classInstance = _Message({
  1: _int,
  2: _MessageSpec(_uuid),
  3: _MessageSpec(_nodePairs),
});
const _Message _function = _Message({1: _str, 2: _str});

const _Message _montyNode = _Message({
  1: _MessageSpec(_unit, oneof: 1),
  2: _MessageSpec(_unit, oneof: 1),
  3: _MessageSpec(_unit, oneof: 1),
  4: _BoolSpec(oneof: 1),
  5: _VarintSpec(oneof: 1),
  6: _MessageSpec(_bigInt, oneof: 1),
  7: _Fixed64Spec(oneof: 1),
  8: _BytesSpec(utf8: true, oneof: 1),
  9: _BytesSpec(utf8: false, oneof: 1),
  10: _MessageSpec(_uuid, oneof: 1),
  11: _MessageSpec(_indexes, oneof: 1),
  12: _MessageSpec(_indexes, oneof: 1),
  13: _MessageSpec(_namedTuple, oneof: 1),
  14: _MessageSpec(_nodePairs, oneof: 1),
  15: _MessageSpec(_indexes, oneof: 1),
  16: _MessageSpec(_indexes, oneof: 1),
  17: _MessageSpec(_date, oneof: 1),
  18: _MessageSpec(_time, oneof: 1),
  19: _MessageSpec(_dateTime, oneof: 1),
  20: _MessageSpec(_timeDelta, oneof: 1),
  21: _MessageSpec(_timeZone, oneof: 1),
  22: _MessageSpec(_exception, oneof: 1),
  23: _MessageSpec(_type, oneof: 1),
  24: _MessageSpec(_classInstance, oneof: 1),
  25: _MessageSpec(_function, oneof: 1),
  26: _BytesSpec(utf8: true, oneof: 1),
  27: _BytesSpec(utf8: true, oneof: 1),
  28: _MessageSpec(_fileHandle, oneof: 1),
  29: _BytesSpec(utf8: true, oneof: 1),
  30: _BytesSpec(utf8: true, oneof: 1),
  31: _MessageSpec(_complex, oneof: 1),
});

const _Message _arena = _Message({
  1: _NodeCountSpec(),
  _arenaNodes: _NodesSpec(),
});

const _Message _sourceRange = _Message({1: _str, 2: _int, 3: _int});

/// `SourceRange.filename`, and where its last value this occurrence lies.
const int _filename = 1;
const int _filenameStart = -2;
const int _filenameEnd = -3;
const _Message _callPosition = _Message({
  _filename: _FilenameSpec(),
  2: _int,
  3: _int,
});
const _Message _codeLoc = _Message({1: _int, 2: _int});
const _Message _stackFrame = _Message({
  1: _str,
  2: _MessageSpec(_codeLoc),
  3: _MessageSpec(_codeLoc),
  4: _str,
  5: _str,
  6: _bool,
  7: _bool,
});
const _Message _unicodeErrorData = _Message({
  1: _str,
  2: _BytesSpec(utf8: false, oneof: 1),
  3: _BytesSpec(utf8: true, oneof: 1),
  4: _int,
  5: _int,
  6: _str,
});
const _Message _jsonErrorData = _Message({
  1: _str,
  2: _str,
  3: _int,
  4: _int,
  5: _int,
});
const _Message _excData = _Message({
  1: _MessageSpec(_unicodeErrorData, oneof: 1),
  2: _MessageSpec(_jsonErrorData, oneof: 1),
});
const _Message _raisedException = _Message({
  1: _str,
  2: _str,
  3: _MessagesSpec(_stackFrame, _stackFrameSize),
  4: _MessageSpec(_excData),
});

const _Message _printSegment = _Message({1: _PrintStreamSpec(), 2: _str});
const _Message _print = _Message({
  1: _MessagesSpec(_printSegment, _segmentSize),
});

const _Message _functionCall = _Message({
  1: _str,
  2: _Uint32sSpec(references: true),
  3: _PairsSpec(),
  4: _int,
  5: _ObjectIdSpec(),
  6: _bool,
  7: _MessageSpec(_arena),
  8: _PositionSpec(),
});

const _Message _textWrite = _Message({1: _str, 2: _str});
const _Message _bytesWrite = _Message({1: _str, 2: _bytes});
const _Message _mkdir = _Message({1: _str, 2: _bool, 3: _bool});
const _Message _getenv = _Message({1: _str, 2: _int});
const _Message _oneString = _Message({1: _str});
const _Message _dateTimeNow = _Message({1: _MessageSpec(_timeZone)});
const _Message _oneInt = _Message({1: _int});
const _Message _oneDouble = _Message({1: _double});

const _Message _osCall = _Message({
  1: _int,
  2: _BytesSpec(utf8: true, oneof: 1),
  3: _BytesSpec(utf8: true, oneof: 1),
  4: _BytesSpec(utf8: true, oneof: 1),
  5: _BytesSpec(utf8: true, oneof: 1),
  6: _BytesSpec(utf8: true, oneof: 1),
  7: _BytesSpec(utf8: true, oneof: 1),
  8: _BytesSpec(utf8: true, oneof: 1),
  9: _BytesSpec(utf8: true, oneof: 1),
  10: _BytesSpec(utf8: true, oneof: 1),
  11: _BytesSpec(utf8: true, oneof: 1),
  12: _BytesSpec(utf8: true, oneof: 1),
  13: _BytesSpec(utf8: true, oneof: 1),
  14: _MessageSpec(_textWrite, oneof: 1),
  15: _MessageSpec(_textWrite, oneof: 1),
  16: _MessageSpec(_bytesWrite, oneof: 1),
  17: _MessageSpec(_bytesWrite, oneof: 1),
  18: _MessageSpec(_textWrite, oneof: 1),
  19: _MessageSpec(_mkdir, oneof: 1),
  20: _MessageSpec(_textWrite, oneof: 1),
  21: _MessageSpec(_getenv, oneof: 1),
  22: _MessageSpec(_unit, oneof: 1),
  23: _MessageSpec(_unit, oneof: 1),
  24: _MessageSpec(_dateTimeNow, oneof: 1),
  25: _MessageSpec(_oneInt, oneof: 1),
  26: _MessageSpec(_oneString, oneof: 1),
  27: _MessageSpec(_oneDouble, oneof: 1),
  28: _MessageSpec(_oneDouble, oneof: 1),
  29: _MessageSpec(_oneDouble, oneof: 1),
  30: _MessageSpec(_oneDouble, oneof: 1),
  50: _MessageSpec(_arena),
  51: _bool,
  52: _MessageSpec(_sourceRange),
});

const _Message _nameLookup = _Message({
  1: _str,
  2: _MessageSpec(_uuid),
  3: _MessageSpec(_sourceRange),
});
const _Message _resolveFutures = _Message({
  1: _Uint32sSpec(references: false),
  2: _MessageSpec(_sourceRange),
});
const _Message _complete = _Message({1: _int, 2: _MessageSpec(_arena)});
const _Message _error = _Message({1: _MessageSpec(_raisedException)});
const _Message _oneBytes = _Message({1: _bytes});

const _Message _childEvent = _Message({
  1: _MessageSpec(_print, oneof: 1),
  2: _MessageSpec(_functionCall, oneof: 1),
  3: _MessageSpec(_osCall, oneof: 1),
  4: _MessageSpec(_nameLookup, oneof: 1),
  5: _MessageSpec(_resolveFutures, oneof: 1),
  6: _MessageSpec(_complete, oneof: 1),
  7: _MessageSpec(_error, oneof: 1),
  8: _MessageSpec(_oneString, oneof: 1),
  9: _MessageSpec(_oneBytes, oneof: 1),
  10: _MessageSpec(_unit, oneof: 1),
  11: _MessageSpec(_oneString, oneof: 1),
  12: _MessageSpec(_oneBytes, oneof: 1),
  20: _int,
  22: _int,
  23: _str,
  24: _int,
  25: _int,
  26: _int,
  27: _int,
  28: _bytes,
});
