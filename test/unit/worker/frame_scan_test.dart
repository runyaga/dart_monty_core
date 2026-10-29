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
  'Scan.maxDepth', 'Scan.caseSensitive',
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

// ---------------------------------------------------------------------------
// The module arms monty 1.2.0 adds: `OsCall.import`, `OsCall.import_stubs`,
// `OsCall.scan` and `MontyNode.module`.
//
// The frames below are hand-encoded: the scanner's schema is pinned to
// monty-proto 1.1.0 and knows none of these arms, so the bytes are built
// here rather than taken from the generated code.
// ---------------------------------------------------------------------------

/// Upstream's allocation sizes, in bytes, on a 64-bit host.

/// A `String` slot, the size of the field names a buffer holds.
const int _stringSlot = 24;

/// A node reference: a 4-byte id plus upstream's host-container allowance.
const int _reference = 16;

/// A key and value reference.
const int _pairSlot = _reference * 2;

/// An arena node.
const int _nodeSlot = 72;

/// A varint-encoded [value].
Uint8List _varint(int value) {
  var rest = value;
  final bytes = <int>[];
  while (rest >= 0x80) {
    bytes.add(rest & 0x7f | 0x80);
    rest >>= 7;
  }
  bytes.add(rest);

  return Uint8List.fromList(bytes);
}

/// The key of the field [field], with the wire type [wire].
Uint8List _key(int field, int wire) => _varint(field << 3 | wire);

/// The field [field], a varint, holding [value].
Uint8List _varintField(int field, int value) =>
    Uint8List.fromList([..._key(field, 0), ..._varint(value)]);

/// The field [field], length-delimited, holding [value].
Uint8List _bytesField(int field, List<int> value) => Uint8List.fromList([
  ..._key(field, 2),
  ..._varint(value.length),
  ...value,
]);

/// The UTF-8 bytes of [text].
Uint8List _bytesOf(String text) => Uint8List.fromList(utf8.encode(text));

/// A `ChildEvent` frame whose `os_call` arm holds [payload].
Uint8List _osCallFrame(List<int> payload) => _bytesField(3, payload);

/// A `ChildEvent` frame whose `complete` arm holds one arena with the single
/// node [node] and no `node_count` hint.
Uint8List _completeFrame(List<int> node) =>
    _bytesField(6, _bytesField(2, _bytesField(2, node)));

/// A `NodePairs` payload: one `NodePair` per entry, each a scalar key and a
/// scalar value.
Uint8List _nodePairs(List<(int, int)> pairs) => Uint8List.fromList([
  for (final (key, value) in pairs)
    ..._bytesField(
      1,
      Uint8List.fromList([
        ..._varintField(1, key),
        ..._varintField(2, value),
      ]),
    ),
]);

/// A `ModuleNode` payload: the [name] bytes (the field is omitted when they
/// are null), the `Uuid`'s [id] bytes (the whole `Uuid` is omitted when they
/// are null), and one `NodePairs` payload per occurrence of the `attrs`
/// field.
Uint8List _moduleBody({
  List<int>? name,
  List<int>? id,
  List<List<(int, int)>> attrs = const [],
}) => Uint8List.fromList([
  if (name != null) ..._bytesField(1, name),
  if (id != null) ..._bytesField(2, _bytesField(1, id)),
  for (final pairs in attrs) ..._bytesField(3, _nodePairs(pairs)),
]);

/// A `MontyNode` payload: one `ModuleNode` per entry, each merged into the
/// same arm.
Uint8List _moduleNode(List<List<int>> bodies) => Uint8List.fromList([
  for (final body in bodies) ..._bytesField(32, body),
]);

/// The `OsCall` payload of an `import` arm: the module name's [module] bytes.
Uint8List _importArm(List<int> module) =>
    _bytesField(31, _bytesField(1, module));

/// The `OsCall` payload of an `import_stubs` arm: the module names.
Uint8List _importStubsArm(List<List<int>> modules) => _bytesField(
  32,
  Uint8List.fromList([
    for (final module in modules) ..._bytesField(1, module),
  ]),
);

/// The `OsCall` payload of a `scan` arm. A null argument omits its field.
Uint8List _scanArm({
  List<int>? path,
  int? maxDepth,
  bool? followSymlinks,
  List<List<int>>? pattern,
  bool? caseSensitive,
  bool? recurseSymlinks,
}) => _bytesField(
  33,
  Uint8List.fromList([
    if (path != null) ..._bytesField(1, path),
    if (maxDepth != null) ..._varintField(2, maxDepth),
    if (followSymlinks != null) ..._varintField(3, followSymlinks ? 1 : 0),
    if (pattern != null)
      for (final part in pattern) ..._bytesField(4, part),
    if (caseSensitive != null) ..._varintField(5, caseSensitive ? 1 : 0),
    if (recurseSymlinks != null) ..._varintField(6, recurseSymlinks ? 1 : 0),
  ]),
);

// ---------------------------------------------------------------------------
// Reading the decoded frames through the generated code's own metadata.
// ---------------------------------------------------------------------------

/// The field [tag] of [message], as the generated code knows it.
FieldInfo<Object?> _requireField(
  GeneratedMessage message,
  int tag, {
  required String reason,
}) {
  final info = message.info_.fieldInfo[tag];
  if (info == null) {
    fail('$reason: the message has no field $tag');
  }

  return info;
}

/// Whether [message] holds the field [tag].
bool _present(GeneratedMessage message, int tag) => message.hasField(tag);

/// The singular message field [tag] of [message], which must be present.
T _message<T extends GeneratedMessage>(
  GeneratedMessage message,
  int tag, {
  required String reason,
}) {
  _requireField(message, tag, reason: reason);
  expect(
    message.hasField(tag),
    isTrue,
    reason: '$reason: the field must be present',
  );
  final value = message.getField(tag);
  if (value is! T) {
    fail('$reason: the field holds ${value.runtimeType}, not $T');
  }

  return value;
}

/// The repeated message field [tag] of [message], which may be empty.
List<T> _messages<T extends GeneratedMessage>(
  GeneratedMessage message,
  int tag, {
  required String reason,
}) {
  final info = _requireField(message, tag, reason: reason);
  expect(info.isRepeated, isTrue, reason: '$reason: the field is repeated');
  final value = message.getField(tag);
  if (value is! List<Object?>) {
    fail('$reason: the field holds ${value.runtimeType}, not a list');
  }
  final messages = <T>[];
  for (final element in value) {
    if (element is! T) {
      fail('$reason: an element holds ${element.runtimeType}, not $T');
    }
    messages.add(element);
  }

  return messages;
}

/// The string field [tag] of [message], which must be present.
String _string(
  GeneratedMessage message,
  int tag, {
  required String reason,
}) {
  _requireField(message, tag, reason: reason);
  expect(
    message.hasField(tag),
    isTrue,
    reason: '$reason: the field must be present',
  );
  final value = message.getField(tag);
  if (value is! String) {
    fail('$reason: the field holds ${value.runtimeType}, not a String');
  }

  return value;
}

/// The integer field [tag] of [message], which must be present.
int _number(
  GeneratedMessage message,
  int tag, {
  required String reason,
}) {
  _requireField(message, tag, reason: reason);
  expect(
    message.hasField(tag),
    isTrue,
    reason: '$reason: the field must be present',
  );
  final value = message.getField(tag);
  if (value is! int) {
    fail('$reason: the field holds ${value.runtimeType}, not an int');
  }

  return value;
}

/// The boolean field [tag] of [message], which must be present.
bool _flag(
  GeneratedMessage message,
  int tag, {
  required String reason,
}) {
  _requireField(message, tag, reason: reason);
  expect(
    message.hasField(tag),
    isTrue,
    reason: '$reason: the field must be present',
  );
  final value = message.getField(tag);
  if (value is! bool) {
    fail('$reason: the field holds ${value.runtimeType}, not a bool');
  }

  return value;
}

/// The repeated string field [tag] of [message], which may be empty.
List<String> _texts(
  GeneratedMessage message,
  int tag, {
  required String reason,
}) {
  final info = _requireField(message, tag, reason: reason);
  expect(info.isRepeated, isTrue, reason: '$reason: the field is repeated');
  final value = message.getField(tag);
  if (value is! List<Object?>) {
    fail('$reason: the field holds ${value.runtimeType}, not a list');
  }
  final texts = <String>[];
  for (final element in value) {
    if (element is! String) {
      fail('$reason: an element holds ${element.runtimeType}, not a String');
    }
    texts.add(element);
  }

  return texts;
}

/// The bytes field [tag] of [message], which must be present.
List<int> _byteValues(
  GeneratedMessage message,
  int tag, {
  required String reason,
}) {
  _requireField(message, tag, reason: reason);
  expect(
    message.hasField(tag),
    isTrue,
    reason: '$reason: the field must be present',
  );
  final value = message.getField(tag);
  if (value is! List<int>) {
    fail('$reason: the field holds ${value.runtimeType}, not bytes');
  }

  return value;
}

/// The `os_call` arm of [event].
pb.OsCall _osCallOf(pb.ChildEvent event) =>
    _message<pb.OsCall>(event, 3, reason: 'ChildEvent.kind is field 3');

/// The `import` arm of [osCall].
pb.OsCall_Import _importOf(pb.OsCall osCall) => _message<pb.OsCall_Import>(
  osCall,
  31,
  reason: 'OsCall.import is field 31',
);

/// The `import_stubs` arm of [osCall].
pb.OsCall_ImportStubs _stubsOf(pb.OsCall osCall) =>
    _message<pb.OsCall_ImportStubs>(
      osCall,
      32,
      reason: 'OsCall.import_stubs is field 32',
    );

/// The `scan` arm of [osCall].
pb.OsCall_Scan _scanOf(pb.OsCall osCall) => _message<pb.OsCall_Scan>(
  osCall,
  33,
  reason: 'OsCall.scan is field 33',
);

/// The single node of [event]'s arena.
pb.MontyNode _nodeOf(pb.ChildEvent event) {
  final complete = _message<pb.Complete>(
    event,
    6,
    reason: 'ChildEvent.complete is field 6',
  );
  final arena = _message<pb.Arena>(
    complete,
    2,
    reason: 'Complete.values is field 2',
  );
  final nodes = _messages<pb.MontyNode>(
    arena,
    2,
    reason: 'Arena.nodes is field 2',
  );
  expect(nodes, hasLength(1), reason: 'the arena holds exactly one node');
  final node = nodes.singleOrNull;
  if (node == null) {
    fail('the arena holds exactly one node');
  }

  return node;
}

/// The `module` arm of [node].
pb.ModuleNode _moduleOf(pb.MontyNode node) => _message<pb.ModuleNode>(
  node,
  32,
  reason: 'MontyNode.module is field 32',
);

/// The pairs of [attrs].
List<pb.NodePair> _pairsOf(pb.NodePairs attrs) => _messages<pb.NodePair>(
  attrs,
  1,
  reason: 'NodePairs.pairs is field 1',
);

/// The keys of [pairs], in order.
List<int> _keysOf(List<pb.NodePair> pairs) => [
  for (final pair in pairs) _number(pair, 1, reason: 'NodePair.key is field 1'),
];

/// The values of [pairs], in order.
List<int> _valuesOf(List<pb.NodePair> pairs) => [
  for (final pair in pairs)
    _number(pair, 2, reason: 'NodePair.value is field 2'),
];

// ---------------------------------------------------------------------------
// The frames, decoded and charged.
// ---------------------------------------------------------------------------

/// A copy of [bytes]: the scanner rewrites the frame it is given in place.
Uint8List _copy(List<int> bytes) => Uint8List.fromList(bytes);

/// The event [frame] decodes to.
pb.ChildEvent _expectDecoded(
  List<int> frame, {
  String reason = 'the frame',
}) {
  try {
    return FrameScan.decodeChildEvent(_copy(frame));
  } on FrameDecodeException catch (error) {
    fail('$reason: the frame was rejected: ${error.reason}');
  }
}

/// The frame [frame] must be rejected, with a reason naming [fragment].
void _expectRejected(
  List<int> frame, {
  required String fragment,
  String reason = 'the frame',
}) {
  expect(
    () => FrameScan.decodeChildEvent(_copy(frame)),
    throwsA(
      isA<FrameDecodeException>().having(
        (error) => error.reason,
        'reason',
        contains(fragment),
      ),
    ),
    reason: '$reason must be rejected with "$fragment"',
  );
}

/// The frame [frame] decodes to at [budget], and [check] sees what it holds.
///
/// The frame charges exactly [budget] bytes, and is rejected one byte short
/// of it.
void _expectBudget(
  List<int> frame,
  int budget, {
  required void Function(pb.ChildEvent event) check,
  String reason = 'the frame',
}) {
  expect(
    FrameScan.childEvent(_copy(frame), budget: budget),
    budget,
    reason: '$reason charges $budget bytes',
  );
  final event = FrameScan.decodeChildEvent(_copy(frame), budget: budget);
  check(event);
  if (budget == 0) return;
  expect(
    () => FrameScan.decodeChildEvent(_copy(frame), budget: budget - 1),
    throwsA(
      isA<FrameDecodeException>().having(
        (error) => error.reason,
        'reason',
        endsWith('frame exceeds decode memory budget'),
      ),
    ),
    reason: '$reason is rejected one byte short of $budget bytes',
  );
}

/// The bytes a growing buffer of [count] slots of [size] bytes is charged.
///
/// Upstream's geometric growth: the whole new buffer is charged, at four
/// slots and then at twice the capacity.
int _slotCharge(int count, int size) {
  var capacity = 0;
  var total = 0;
  while (capacity < count) {
    capacity = capacity * 2 < 4 ? 4 : capacity * 2;
    total += capacity * size;
  }

  return total;
}

/// The bytes a single string's payload costs.
int _textCharge(String text) => utf8.encode(text).length;

/// The bytes a repeated string field holding [texts] costs: a slot for each
/// string, plus the payload of each.
int _textsCharge(List<String> texts) =>
    _slotCharge(texts.length, _stringSlot) +
    texts.fold(0, (total, text) => total + _textCharge(text));

/// The bytes a module node costs: its arena slot, its name, its id and its
/// attribute pairs.
int _moduleCharge({
  required String name,
  required int idLength,
  required int pairs,
}) =>
    _slotCharge(1, _nodeSlot) +
    _textCharge(name) +
    idLength +
    _slotCharge(pairs, _pairSlot);

/// The frames keep the module arms and their fields, as upstream's decoder
/// keeps them.
void _checkPreservation() {
  final stubA = _bytesOf('a');
  final dataPath = _bytesOf('/data');
  final pythonPattern = _bytesOf('*.py');

  // The `import` arm: the module name.
  final imported = _expectDecoded(
    _osCallFrame(_importArm(_bytesOf('tools'))),
    reason: 'an import arm',
  );
  final osCall = _osCallOf(imported);
  _requireField(osCall, 31, reason: 'OsCall.import is field 31');
  expect(
    _present(osCall, 31),
    isTrue,
    reason: 'OsCall.import is field 31 and must be present',
  );
  final import = _importOf(osCall);
  expect(
    _string(import, 1, reason: 'Import.module is field 1'),
    'tools',
    reason: 'the imported module',
  );

  // The `import_stubs` arm: the module names, in order and with duplicates.
  final stubbed = _expectDecoded(
    _osCallFrame(
      _importStubsArm([
        stubA,
        _bytesOf('b'),
        stubA,
        _bytesOf('c'),
        stubA,
      ]),
    ),
    reason: 'an import stubs arm',
  );
  final stubCall = _osCallOf(stubbed);
  _requireField(stubCall, 32, reason: 'OsCall.import_stubs is field 32');
  expect(
    _present(stubCall, 32),
    isTrue,
    reason: 'OsCall.import_stubs is field 32 and must be present',
  );
  final stubs = _stubsOf(stubCall);
  expect(
    _texts(stubs, 1, reason: 'ImportStubs.modules is field 1'),
    ['a', 'b', 'a', 'c', 'a'],
    reason: 'the stub names, in order and with their duplicates',
  );

  // The `scan` arm: every field, the optional ones present.
  final scanned = _expectDecoded(
    _osCallFrame(
      _scanArm(
        path: dataPath,
        maxDepth: 0,
        followSymlinks: true,
        pattern: [pythonPattern, _bytesOf('*.pyi'), pythonPattern],
        caseSensitive: false,
        recurseSymlinks: true,
      ),
    ),
    reason: 'a scan arm',
  );
  final scanCall = _osCallOf(scanned);
  _requireField(scanCall, 33, reason: 'OsCall.scan is field 33');
  expect(
    _present(scanCall, 33),
    isTrue,
    reason: 'OsCall.scan is field 33 and must be present',
  );
  final scan = _scanOf(scanCall);
  expect(
    _string(scan, 1, reason: 'Scan.path is field 1'),
    '/data',
    reason: 'the scanned path',
  );
  expect(
    _present(scan, 2),
    isTrue,
    reason: 'Scan.max_depth is field 2 and is present',
  );
  expect(
    _number(scan, 2, reason: 'Scan.max_depth is field 2'),
    0,
    reason: 'the scanned depth',
  );
  expect(
    _flag(scan, 3, reason: 'Scan.follow_symlinks is field 3'),
    isTrue,
    reason: 'the scan follows symlinks',
  );
  expect(
    _texts(scan, 4, reason: 'Scan.pattern is field 4'),
    ['*.py', '*.pyi', '*.py'],
    reason: 'the scan patterns, in order and with their duplicate',
  );
  expect(
    _present(scan, 5),
    isTrue,
    reason: 'Scan.case_sensitive is field 5 and is present',
  );
  expect(
    _flag(scan, 5, reason: 'Scan.case_sensitive is field 5'),
    isFalse,
    reason: 'the scan is case insensitive',
  );
  expect(
    _flag(scan, 6, reason: 'Scan.recurse_symlinks is field 6'),
    isTrue,
    reason: 'the scan recurses into symlinks',
  );

  // The optional fields, absent: an explicit zero is not the same as none.
  final plain = _scanOf(
    _osCallOf(
      _expectDecoded(
        _osCallFrame(
          _scanArm(
            path: dataPath,
            followSymlinks: true,
            recurseSymlinks: true,
          ),
        ),
        reason: 'a scan arm without its optional fields',
      ),
    ),
  );
  expect(
    _present(plain, 2),
    isFalse,
    reason: 'Scan.max_depth is field 2 and is absent',
  );
  expect(
    _present(plain, 5),
    isFalse,
    reason: 'Scan.case_sensitive is field 5 and is absent',
  );

  // The `module` arm: the name, the id and the attribute pairs.
  final moduleEvent = _expectDecoded(
    _completeFrame(
      _moduleNode([
        _moduleBody(
          name: _bytesOf('pkg.sub'),
          id: List.filled(16, 7),
          attrs: const [
            [
              (1, 2),
              (3, 4),
            ],
          ],
        ),
      ]),
    ),
    reason: 'a module node',
  );
  final module = _moduleOf(_nodeOf(moduleEvent));
  expect(
    _string(module, 1, reason: 'ModuleNode.name is field 1'),
    'pkg.sub',
    reason: 'the module name',
  );
  expect(
    _byteValues(
      _message<pb.Uuid>(module, 2, reason: 'ModuleNode.id is field 2'),
      1,
      reason: 'Uuid.data is field 1',
    ),
    List.filled(16, 7),
    reason: 'the module id, all sixteen bytes',
  );
  final pairs = _pairsOf(
    _message<pb.NodePairs>(module, 3, reason: 'ModuleNode.attrs is field 3'),
  );
  expect(_keysOf(pairs), [1, 3], reason: 'the attribute keys, in order');
  expect(_valuesOf(pairs), [2, 4], reason: 'the attribute values, in order');
}

/// The module node's required fields, as upstream's decoder requires them.
void _checkModuleValidation() {
  final id = List.filled(16, 7);
  final moduleName = _bytesOf('pkg.sub');

  // A module with an id and present, empty attrs is accepted.
  final accepted = _expectDecoded(
    _completeFrame(
      _moduleNode([
        _moduleBody(
          name: moduleName,
          id: id,
          attrs: const [[]],
        ),
      ]),
    ),
    reason: 'a module node with an id and empty attrs',
  );
  final module = _moduleOf(_nodeOf(accepted));
  expect(
    _byteValues(
      _message<pb.Uuid>(module, 2, reason: 'ModuleNode.id is field 2'),
      1,
      reason: 'Uuid.data is field 1',
    ),
    id,
    reason: 'the module id, all sixteen bytes',
  );
  expect(
    _pairsOf(
      _message<pb.NodePairs>(module, 3, reason: 'ModuleNode.attrs is field 3'),
    ),
    isEmpty,
    reason: 'the module has no attributes',
  );

  // The id is required.
  _expectRejected(
    _completeFrame(
      _moduleNode([
        _moduleBody(
          name: moduleName,
          attrs: const [
            [
              (1, 2),
            ],
          ],
        ),
      ]),
    ),
    fragment: 'missing required field ModuleNode.id',
    reason: 'a module node without an id',
  );

  // The attrs are required, even when they are empty.
  _expectRejected(
    _completeFrame(
      _moduleNode([
        _moduleBody(name: moduleName, id: id),
      ]),
    ),
    fragment: 'missing required field ModuleNode.attrs',
    reason: 'a module node without attrs',
  );

  // The id must be sixteen bytes long.
  for (final length in [0, 3, 17]) {
    _expectRejected(
      _completeFrame(
        _moduleNode([
          _moduleBody(
            name: moduleName,
            id: List.filled(length, 7),
            attrs: const [[]],
          ),
        ]),
      ),
      fragment:
          'invalid value for ModuleNode.id: uuid must be 16 bytes, got $length',
      reason: 'a module node whose id is $length bytes long',
    );
  }
}

/// The strings the module arms hold, as upstream's decoder reads them.
void _checkStrings() {
  final id = List.filled(16, 7);
  final malformed = _bytes('c328');
  final plainName = _bytesOf('plain');
  final bomName = _bytesOf('\u{FEFF}bom');
  final dataPath = _bytesOf('/data');

  // The module name.
  final module = _moduleOf(
    _nodeOf(
      _expectDecoded(
        _completeFrame(
          _moduleNode([
            _moduleBody(
              name: _bytesOf('\u{FEFF}pkg.sub'),
              id: id,
              attrs: const [[]],
            ),
          ]),
        ),
        reason: 'a module node whose name starts with a byte-order mark',
      ),
    ),
  );
  expect(
    _string(module, 1, reason: 'ModuleNode.name is field 1'),
    '\u{FEFF}pkg.sub',
    reason: 'the module name keeps its byte-order mark',
  );
  _expectRejected(
    _completeFrame(
      _moduleNode([
        _moduleBody(
          name: malformed,
          id: id,
          attrs: const [[]],
        ),
      ]),
    ),
    fragment: 'invalid string value: data is not UTF-8 encoded',
    reason: 'a module node whose name is not UTF-8',
  );

  // The imported module name.
  final imported = _importOf(
    _osCallOf(
      _expectDecoded(
        _osCallFrame(_importArm(_bytesOf('\u{FEFF}tools'))),
        reason: 'an import arm whose module name starts with a byte-order mark',
      ),
    ),
  );
  expect(
    _string(imported, 1, reason: 'Import.module is field 1'),
    '\u{FEFF}tools',
    reason: 'the imported module keeps its byte-order mark',
  );
  _expectRejected(
    _osCallFrame(_importArm(malformed)),
    fragment: 'invalid string value: data is not UTF-8 encoded',
    reason: 'an import arm whose module name is not UTF-8',
  );

  // The stub names.
  final stubs = _stubsOf(
    _osCallOf(
      _expectDecoded(
        _osCallFrame(
          _importStubsArm([plainName, bomName]),
        ),
        reason: 'an import stubs arm with a byte-order mark',
      ),
    ),
  );
  expect(
    _texts(stubs, 1, reason: 'ImportStubs.modules is field 1'),
    ['plain', '\u{FEFF}bom'],
    reason: 'the stub names, the byte-order mark kept',
  );
  _expectRejected(
    _osCallFrame(_importStubsArm([plainName, malformed])),
    fragment: 'invalid string value: data is not UTF-8 encoded',
    reason: 'an import stubs arm with a name that is not UTF-8',
  );

  // The scanned path.
  final scan = _scanOf(
    _osCallOf(
      _expectDecoded(
        _osCallFrame(
          _scanArm(path: _bytesOf('\u{FEFF}/data'), recurseSymlinks: true),
        ),
        reason: 'a scan arm whose path starts with a byte-order mark',
      ),
    ),
  );
  expect(
    _string(scan, 1, reason: 'Scan.path is field 1'),
    '\u{FEFF}/data',
    reason: 'the scanned path keeps its byte-order mark',
  );
  _expectRejected(
    _osCallFrame(_scanArm(path: malformed, recurseSymlinks: true)),
    fragment: 'invalid string value: data is not UTF-8 encoded',
    reason: 'a scan arm whose path is not UTF-8',
  );

  // The scan patterns.
  final patterned = _scanOf(
    _osCallOf(
      _expectDecoded(
        _osCallFrame(
          _scanArm(
            path: dataPath,
            pattern: [plainName, bomName],
            recurseSymlinks: true,
          ),
        ),
        reason: 'a scan arm whose pattern starts with a byte-order mark',
      ),
    ),
  );
  expect(
    _texts(patterned, 4, reason: 'Scan.pattern is field 4'),
    ['plain', '\u{FEFF}bom'],
    reason: 'the scan patterns, the byte-order mark kept',
  );
  _expectRejected(
    _osCallFrame(
      _scanArm(
        path: dataPath,
        pattern: [plainName, malformed],
        recurseSymlinks: true,
      ),
    ),
    fragment: 'invalid string value: data is not UTF-8 encoded',
    reason: 'a scan arm with a pattern that is not UTF-8',
  );
}

/// The wire types of the module arms' fields, as upstream's decoder reads
/// them.
void _checkWireTypes() {
  final id = List.filled(16, 7);
  // The wrong wire type: a varint where a length-delimited field belongs,
  // and a length-delimited field where a varint belongs.
  final varintOne = _varintField(1, 0);
  final varintThirtyTwo = _varintField(32, 0);
  final bytesTwo = _bytesField(2, [0]);

  // A module body: the field [tag] holds [corrupt], the others are valid.
  Uint8List moduleBody(int tag, Uint8List corrupt) {
    final fields = {
      1: _bytesField(1, _bytesOf('pkg.sub')),
      2: _bytesField(2, _bytesField(1, id)),
      3: _bytesField(
        3,
        _nodePairs([
          (1, 2),
        ]),
      ),
    };

    return Uint8List.fromList([
      for (final field in fields.entries)
        if (field.key == tag) ...corrupt else ...field.value,
    ]);
  }

  // A scan body: the field [tag] holds [corrupt], the others are valid.
  Uint8List scanBody(int tag, Uint8List corrupt) {
    final fields = {
      1: _bytesField(1, _bytesOf('/data')),
      2: _varintField(2, 0),
      3: _varintField(3, 1),
      4: _bytesField(4, _bytesOf('*.py')),
      5: _varintField(5, 0),
      6: _varintField(6, 1),
    };

    return Uint8List.fromList([
      for (final field in fields.entries)
        if (field.key == tag) ...corrupt else ...field.value,
    ]);
  }

  final cases = [
    ('MontyNode.module', _completeFrame(varintThirtyTwo)),
    (
      'ModuleNode.name',
      _completeFrame(_moduleNode([moduleBody(1, varintOne)])),
    ),
    (
      'ModuleNode.id',
      _completeFrame(_moduleNode([moduleBody(2, _varintField(2, 0))])),
    ),
    (
      'ModuleNode.attrs',
      _completeFrame(_moduleNode([moduleBody(3, _varintField(3, 0))])),
    ),
    (
      'Uuid.data',
      _completeFrame(
        _moduleNode([moduleBody(2, _bytesField(2, varintOne))]),
      ),
    ),
    (
      'NodePairs.pairs',
      _completeFrame(
        _moduleNode([moduleBody(3, _bytesField(3, varintOne))]),
      ),
    ),
    (
      'NodePair.key',
      _completeFrame(
        _moduleNode([
          moduleBody(3, _bytesField(3, _bytesField(1, _bytesField(1, [0])))),
        ]),
      ),
    ),
    (
      'NodePair.value',
      _completeFrame(
        _moduleNode([
          moduleBody(
            3,
            _bytesField(3, _bytesField(1, _bytesField(2, bytesTwo))),
          ),
        ]),
      ),
    ),
    ('OsCall.import', _osCallFrame(_varintField(31, 0))),
    ('OsCall.import_stubs', _osCallFrame(varintThirtyTwo)),
    ('OsCall.scan', _osCallFrame(_varintField(33, 0))),
    ('Import.module', _osCallFrame(_bytesField(31, varintOne))),
    (
      'ImportStubs.modules',
      _osCallFrame(_bytesField(32, varintOne)),
    ),
    (
      'Scan.path',
      _osCallFrame(_bytesField(33, scanBody(1, varintOne))),
    ),
    (
      'Scan.max_depth',
      _osCallFrame(_bytesField(33, scanBody(2, bytesTwo))),
    ),
    (
      'Scan.follow_symlinks',
      _osCallFrame(_bytesField(33, scanBody(3, _bytesField(3, [0])))),
    ),
    (
      'Scan.pattern',
      _osCallFrame(_bytesField(33, scanBody(4, _varintField(4, 0)))),
    ),
    (
      'Scan.case_sensitive',
      _osCallFrame(_bytesField(33, scanBody(5, _bytesField(5, [0])))),
    ),
    (
      'Scan.recurse_symlinks',
      _osCallFrame(_bytesField(33, scanBody(6, _bytesField(6, [0])))),
    ),
  ];

  for (final (label, frame) in cases) {
    _expectRejected(
      frame,
      fragment: 'invalid wire type',
      reason: 'the $label field',
    );
  }
}

/// The module arms merge, as upstream's decoder merges them.
void _checkMerging() {
  final id = List.filled(16, 7);
  final moduleName = _bytesOf('pkg.sub');
  final toolsName = _bytesOf('tools');
  final shortName = _bytesOf('x');
  final stubA = _bytesOf('a');
  final stubB = _bytesOf('b');
  final dataPath = _bytesOf('/data');
  final toolsArm = _importArm(toolsName);
  final shortArm = _importArm(shortName);
  final stringArm = _bytesField(8, shortName);

  // Two `ModuleNode` occurrences in one node: the second carries the attrs
  // the first lacks, and the merge happens before the required fields are
  // checked.
  _expectBudget(
    _completeFrame(
      _moduleNode([
        _moduleBody(name: moduleName, id: id),
        _moduleBody(
          attrs: const [
            [
              (1, 2),
            ],
          ],
        ),
      ]),
    ),
    439,
    reason: 'a module node whose two occurrences carry different fields',
    check: (event) {
      final module = _moduleOf(_nodeOf(event));
      expect(
        _string(module, 1, reason: 'ModuleNode.name is field 1'),
        'pkg.sub',
        reason: 'the module name of the first occurrence',
      );
      expect(
        _byteValues(
          _message<pb.Uuid>(module, 2, reason: 'ModuleNode.id is field 2'),
          1,
          reason: 'Uuid.data is field 1',
        ),
        id,
        reason: 'the module id of the first occurrence',
      );
      final pairs = _pairsOf(
        _message<pb.NodePairs>(
          module,
          3,
          reason: 'ModuleNode.attrs is field 3',
        ),
      );
      expect(_keysOf(pairs), [1], reason: 'the attribute keys, in order');
      expect(_valuesOf(pairs), [2], reason: 'the attribute values, in order');
    },
  );

  // A second occurrence of the module replaces its name and adds a pair.
  _expectBudget(
    _completeFrame(
      _moduleNode([
        _moduleBody(
          name: moduleName,
          id: id,
          attrs: const [
            [
              (1, 2),
              (3, 4),
              (5, 6),
              (7, 8),
            ],
          ],
        ),
        _moduleBody(
          name: shortName,
          attrs: const [
            [
              (9, 10),
            ],
          ],
        ),
      ]),
    ),
    695,
    reason: 'a module node whose second occurrence replaces its name',
    check: (event) {
      final module = _moduleOf(_nodeOf(event));
      expect(
        _string(module, 1, reason: 'ModuleNode.name is field 1'),
        'x',
        reason: 'the module name of the second occurrence',
      );
      expect(
        _byteValues(
          _message<pb.Uuid>(module, 2, reason: 'ModuleNode.id is field 2'),
          1,
          reason: 'Uuid.data is field 1',
        ),
        id,
        reason: 'the module id of the first occurrence',
      );
      final pairs = _pairsOf(
        _message<pb.NodePairs>(
          module,
          3,
          reason: 'ModuleNode.attrs is field 3',
        ),
      );
      expect(
        _keysOf(pairs),
        [1, 3, 5, 7, 9],
        reason: 'the attribute keys, in order',
      );
      expect(
        _valuesOf(pairs),
        [2, 4, 6, 8, 10],
        reason: 'the attribute values, in order',
      );
    },
  );

  // Two `attrs` occurrences in one module: their pairs concatenate.
  _expectBudget(
    _completeFrame(
      _moduleNode([
        _moduleBody(
          name: moduleName,
          id: id,
          attrs: const [
            [
              (1, 2),
              (3, 4),
              (5, 6),
              (7, 8),
            ],
            [
              (9, 10),
            ],
          ],
        ),
      ]),
    ),
    695,
    reason: 'a module node whose two attrs occurrences carry pairs',
    check: (event) {
      final module = _moduleOf(_nodeOf(event));
      expect(
        _string(module, 1, reason: 'ModuleNode.name is field 1'),
        'pkg.sub',
        reason: 'the module name',
      );
      expect(
        _byteValues(
          _message<pb.Uuid>(module, 2, reason: 'ModuleNode.id is field 2'),
          1,
          reason: 'Uuid.data is field 1',
        ),
        id,
        reason: 'the module id',
      );
      final pairs = _pairsOf(
        _message<pb.NodePairs>(
          module,
          3,
          reason: 'ModuleNode.attrs is field 3',
        ),
      );
      expect(
        _keysOf(pairs),
        [1, 3, 5, 7, 9],
        reason: 'the attribute keys, in order',
      );
      expect(
        _valuesOf(pairs),
        [2, 4, 6, 8, 10],
        reason: 'the attribute values, in order',
      );
    },
  );

  // Two `import` arms: the last one wins, and its shorter name is free.
  _expectBudget(
    _osCallFrame(
      Uint8List.fromList([
        ...toolsArm,
        ...shortArm,
      ]),
    ),
    5,
    reason: 'two import arms',
    check: (event) {
      final import = _importOf(_osCallOf(event));
      expect(
        _string(import, 1, reason: 'Import.module is field 1'),
        'x',
        reason: 'the module name of the last arm',
      );
    },
  );

  // Two `import_stubs` arms: their names concatenate, duplicates included.
  _expectBudget(
    _osCallFrame(
      Uint8List.fromList([
        ..._importStubsArm([stubA, stubB, stubA, _bytesOf('c')]),
        ..._importStubsArm([stubA]),
      ]),
    ),
    293,
    reason: 'two import stubs arms',
    check: (event) {
      final stubs = _stubsOf(_osCallOf(event));
      expect(
        _texts(stubs, 1, reason: 'ImportStubs.modules is field 1'),
        ['a', 'b', 'a', 'c', 'a'],
        reason: 'the stub names of both arms, in order',
      );
    },
  );

  // Two `scan` arms: the second overwrites the optional fields it carries.
  _expectBudget(
    _osCallFrame(
      Uint8List.fromList([
        ..._scanArm(
          path: dataPath,
          maxDepth: 3,
          followSymlinks: true,
          pattern: [stubA],
          caseSensitive: true,
          recurseSymlinks: true,
        ),
        ..._scanArm(
          maxDepth: 0,
          pattern: [stubB],
          caseSensitive: false,
        ),
      ]),
    ),
    103,
    reason: 'two scan arms',
    check: (event) {
      final scan = _scanOf(_osCallOf(event));
      expect(
        _string(scan, 1, reason: 'Scan.path is field 1'),
        '/data',
        reason: 'the scanned path of the first arm',
      );
      expect(
        _present(scan, 2),
        isTrue,
        reason: 'Scan.max_depth is field 2 and is present',
      );
      expect(
        _number(scan, 2, reason: 'Scan.max_depth is field 2'),
        0,
        reason: 'the scanned depth of the second arm',
      );
      expect(
        _flag(scan, 3, reason: 'Scan.follow_symlinks is field 3'),
        isTrue,
        reason: 'the scan follows symlinks, as the first arm had it',
      );
      expect(
        _texts(scan, 4, reason: 'Scan.pattern is field 4'),
        ['a', 'b'],
        reason: 'the scan patterns of both arms, in order',
      );
      expect(
        _present(scan, 5),
        isTrue,
        reason: 'Scan.case_sensitive is field 5 and is present',
      );
      expect(
        _flag(scan, 5, reason: 'Scan.case_sensitive is field 5'),
        isFalse,
        reason: 'the scan is case insensitive, as the second arm had it',
      );
      expect(
        _flag(scan, 6, reason: 'Scan.recurse_symlinks is field 6'),
        isTrue,
        reason: 'the scan recurses into symlinks, as the first arm had it',
      );
    },
  );

  // Switching arms drops the old one, without refunding what it charged.
  _expectBudget(
    _osCallFrame(
      Uint8List.fromList([
        ...toolsArm,
        ..._scanArm(path: dataPath),
      ]),
    ),
    10,
    reason: 'an import arm followed by a scan arm',
    check: (event) {
      final osCall = _osCallOf(event);
      expect(
        _present(osCall, 31),
        isFalse,
        reason: 'the import arm is gone',
      );
      expect(
        _present(osCall, 33),
        isTrue,
        reason: 'OsCall.scan is field 33 and is present',
      );
      final scan = _scanOf(osCall);
      expect(
        _string(scan, 1, reason: 'Scan.path is field 1'),
        '/data',
        reason: 'the scanned path',
      );
      expect(
        _texts(scan, 4, reason: 'Scan.pattern is field 4'),
        isEmpty,
        reason: 'the scan has no pattern',
      );
    },
  );

  // A module node followed by a string: the string wins.
  _expectBudget(
    _completeFrame(
      Uint8List.fromList([
        ..._moduleNode([
          _moduleBody(
            name: moduleName,
            id: id,
            attrs: const [[]],
          ),
        ]),
        ...stringArm,
      ]),
    ),
    312,
    reason: 'a module node followed by a string',
    check: (event) {
      final node = _nodeOf(event);
      expect(
        _present(node, 32),
        isFalse,
        reason: 'the module arm is gone',
      );
      expect(
        _string(node, 8, reason: 'MontyNode.str is field 8'),
        'x',
        reason: 'the string that replaced the module',
      );
    },
  );

  // A string followed by a module node: the module wins.
  _expectBudget(
    _completeFrame(
      Uint8List.fromList([
        ...stringArm,
        ..._moduleNode([
          _moduleBody(
            name: moduleName,
            id: id,
            attrs: const [[]],
          ),
        ]),
      ]),
    ),
    312,
    reason: 'a string followed by a module node',
    check: (event) {
      final node = _nodeOf(event);
      expect(
        _present(node, 8),
        isFalse,
        reason: 'the string arm is gone',
      );
      final module = _moduleOf(node);
      expect(
        _string(module, 1, reason: 'ModuleNode.name is field 1'),
        'pkg.sub',
        reason: 'the module name',
      );
      expect(
        _byteValues(
          _message<pb.Uuid>(module, 2, reason: 'ModuleNode.id is field 2'),
          1,
          reason: 'Uuid.data is field 1',
        ),
        id,
        reason: 'the module id, all sixteen bytes',
      );
      final pairs = _pairsOf(
        _message<pb.NodePairs>(
          module,
          3,
          reason: 'ModuleNode.attrs is field 3',
        ),
      );
      expect(pairs, isEmpty, reason: 'the module has no attributes');
    },
  );
}

/// The unknown fields the module arms hold, as upstream's decoder drops them.
void _checkUnknowns() {
  final id = List.filled(16, 7);

  // An unknown field inside the import arm.
  _expectBudget(
    _osCallFrame(
      _bytesField(
        31,
        Uint8List.fromList([
          ..._bytesField(1, _bytesOf('tools')),
          ..._varintField(99, 1),
        ]),
      ),
    ),
    5,
    reason: 'an import arm with an unknown field',
    check: (event) {
      expect(
        _unknownFields(event),
        0,
        reason: 'prost keeps no unknown fields',
      );
      final import = _importOf(_osCallOf(event));
      expect(
        _string(import, 1, reason: 'Import.module is field 1'),
        'tools',
        reason: 'the imported module',
      );
    },
  );

  // An unknown field inside the import stubs arm.
  _expectBudget(
    _osCallFrame(
      _bytesField(
        32,
        Uint8List.fromList([
          ..._bytesField(1, _bytesOf('a')),
          ..._varintField(99, 2),
        ]),
      ),
    ),
    97,
    reason: 'an import stubs arm with an unknown field',
    check: (event) {
      expect(
        _unknownFields(event),
        0,
        reason: 'prost keeps no unknown fields',
      );
      final stubs = _stubsOf(_osCallOf(event));
      expect(
        _texts(stubs, 1, reason: 'ImportStubs.modules is field 1'),
        ['a'],
        reason: 'the stub names, in order',
      );
    },
  );

  // An unknown field inside the scan arm.
  _expectBudget(
    _osCallFrame(
      _bytesField(
        33,
        Uint8List.fromList([
          ..._bytesField(1, _bytesOf('/data')),
          ..._varintField(2, 0),
          ..._varintField(3, 1),
          ..._bytesField(4, _bytesOf('*.py')),
          ..._varintField(5, 0),
          ..._varintField(6, 1),
          ..._varintField(99, 3),
        ]),
      ),
    ),
    105,
    reason: 'a scan arm with an unknown field',
    check: (event) {
      expect(
        _unknownFields(event),
        0,
        reason: 'prost keeps no unknown fields',
      );
      final scan = _scanOf(_osCallOf(event));
      expect(
        _string(scan, 1, reason: 'Scan.path is field 1'),
        '/data',
        reason: 'the scanned path',
      );
      expect(
        _present(scan, 2),
        isTrue,
        reason: 'Scan.max_depth is field 2 and is present',
      );
      expect(
        _number(scan, 2, reason: 'Scan.max_depth is field 2'),
        0,
        reason: 'the scanned depth',
      );
      expect(
        _flag(scan, 3, reason: 'Scan.follow_symlinks is field 3'),
        isTrue,
        reason: 'the scan follows symlinks',
      );
      expect(
        _texts(scan, 4, reason: 'Scan.pattern is field 4'),
        ['*.py'],
        reason: 'the scan patterns, in order',
      );
      expect(
        _present(scan, 5),
        isTrue,
        reason: 'Scan.case_sensitive is field 5 and is present',
      );
      expect(
        _flag(scan, 5, reason: 'Scan.case_sensitive is field 5'),
        isFalse,
        reason: 'the scan is case insensitive',
      );
      expect(
        _flag(scan, 6, reason: 'Scan.recurse_symlinks is field 6'),
        isTrue,
        reason: 'the scan recurses into symlinks',
      );
    },
  );

  // An unknown field at every depth of the module arm.
  final uuid = Uint8List.fromList([
    ..._bytesField(1, id),
    ..._varintField(99, 4),
  ]);
  final pair = Uint8List.fromList([
    ..._varintField(1, 1),
    ..._varintField(2, 2),
    ..._varintField(99, 5),
  ]);
  final attrs = Uint8List.fromList([
    ..._bytesField(1, pair),
    ..._varintField(99, 6),
  ]);
  final module = Uint8List.fromList([
    ..._bytesField(1, _bytesOf('pkg.sub')),
    ..._bytesField(2, uuid),
    ..._bytesField(3, attrs),
    ..._varintField(99, 7),
  ]);
  _expectBudget(
    _completeFrame(_moduleNode([module])),
    439,
    reason: 'a module node with unknown fields at every depth',
    check: (event) {
      expect(
        _unknownFields(event),
        0,
        reason: 'prost keeps no unknown fields',
      );
      final decoded = _moduleOf(_nodeOf(event));
      expect(
        _string(decoded, 1, reason: 'ModuleNode.name is field 1'),
        'pkg.sub',
        reason: 'the module name',
      );
      expect(
        _byteValues(
          _message<pb.Uuid>(decoded, 2, reason: 'ModuleNode.id is field 2'),
          1,
          reason: 'Uuid.data is field 1',
        ),
        id,
        reason: 'the module id, all sixteen bytes',
      );
      final pairs = _pairsOf(
        _message<pb.NodePairs>(
          decoded,
          3,
          reason: 'ModuleNode.attrs is field 3',
        ),
      );
      expect(_keysOf(pairs), [1], reason: 'the attribute keys, in order');
      expect(_valuesOf(pairs), [2], reason: 'the attribute values, in order');
    },
  );
}

/// What the module arms cost upstream's decoder.
void _checkBudgets() {
  final id = List.filled(16, 7);
  final dataPath = _bytesOf('/data');

  // The charges the helpers compute, from upstream's own growth.
  expect(_slotCharge(4, _stringSlot), 96, reason: 'four string slots');
  expect(_slotCharge(5, _stringSlot), 288, reason: 'five string slots');
  expect(_slotCharge(4, _pairSlot), 128, reason: 'four pair slots');
  expect(_slotCharge(5, _pairSlot), 384, reason: 'five pair slots');
  expect(_slotCharge(1, _nodeSlot), 288, reason: 'one arena node');
  expect(
    _textsCharge(['a', 'b', 'a', 'c']),
    100,
    reason: 'four stub names and their payloads',
  );
  expect(
    _textsCharge(['a', 'b', 'a', 'c', 'a']),
    293,
    reason: 'five stub names and their payloads',
  );
  expect(
    _moduleCharge(name: 'pkg.sub', idLength: 16, pairs: 0),
    311,
    reason: 'a module node without attributes',
  );
  expect(
    _moduleCharge(name: 'pkg.sub', idLength: 16, pairs: 5),
    695,
    reason: 'a module node with five attributes',
  );

  // An import arm: the module name's bytes.
  _expectBudget(
    _osCallFrame(_importArm(_bytesOf('tools'))),
    5,
    reason: 'an import arm',
    check: (event) {
      final import = _importOf(_osCallOf(event));
      expect(
        _string(import, 1, reason: 'Import.module is field 1'),
        'tools',
        reason: 'the imported module',
      );
    },
  );

  // A scan arm: four patterns, then five.
  const four = ['*.py', '*.pyi', '*.pyx', '*.pyw'];
  const five = ['*.py', '*.pyi', '*.pyx', '*.pyw', '*.pyd'];
  _expectBudget(
    _osCallFrame(
      _scanArm(
        path: dataPath,
        pattern: [for (final part in four) _bytesOf(part)],
      ),
    ),
    120,
    reason: 'a scan arm with four patterns',
    check: (event) {
      final scan = _scanOf(_osCallOf(event));
      expect(
        _texts(scan, 4, reason: 'Scan.pattern is field 4'),
        four,
        reason: 'the scan patterns, in order',
      );
    },
  );
  _expectBudget(
    _osCallFrame(
      _scanArm(
        path: dataPath,
        pattern: [for (final part in five) _bytesOf(part)],
      ),
    ),
    317,
    reason: 'a scan arm with five patterns',
    check: (event) {
      final scan = _scanOf(_osCallOf(event));
      expect(
        _texts(scan, 4, reason: 'Scan.pattern is field 4'),
        five,
        reason: 'the scan patterns, in order',
      );
    },
  );
  expect(
    _textsCharge(five) - _textsCharge(four),
    197,
    reason: 'the fifth pattern costs a new buffer and its payload',
  );

  // A module node: no attributes, then one, two, four and five.
  for (final (count, budget) in [
    (0, 311),
    (1, 439),
    (2, 439),
    (4, 439),
    (5, 695),
  ]) {
    final pairs = [
      for (var index = 0; index < count; index++)
        (index * 2 + 1, index * 2 + 2),
    ];
    _expectBudget(
      _completeFrame(
        _moduleNode([
          _moduleBody(
            name: _bytesOf('pkg.sub'),
            id: id,
            attrs: [pairs],
          ),
        ]),
      ),
      budget,
      reason: 'a module node with $count attribute pairs',
      check: (event) {
        final module = _moduleOf(_nodeOf(event));
        expect(
          _string(module, 1, reason: 'ModuleNode.name is field 1'),
          'pkg.sub',
          reason: 'the module name',
        );
        final decoded = _pairsOf(
          _message<pb.NodePairs>(
            module,
            3,
            reason: 'ModuleNode.attrs is field 3',
          ),
        );
        expect(
          _keysOf(decoded),
          [for (final (key, _) in pairs) key],
          reason: 'the attribute keys, in order',
        );
        expect(
          _valuesOf(decoded),
          [for (final (_, value) in pairs) value],
          reason: 'the attribute values, in order',
        );
      },
    );
  }

  // An import stubs arm: four names, then five, with and without duplicates.
  for (final (names, budget) in [
    (['a', 'b', 'c', 'd'], 100),
    (['a', 'b', 'a', 'c'], 100),
    (['a', 'b', 'c', 'd', 'e'], 293),
    (['a', 'b', 'a', 'c', 'a'], 293),
  ]) {
    _expectBudget(
      _osCallFrame(
        _importStubsArm([for (final name in names) _bytesOf(name)]),
      ),
      budget,
      reason: 'an import stubs arm with ${names.length} names',
      check: (event) {
        final stubs = _stubsOf(_osCallOf(event));
        expect(
          _texts(stubs, 1, reason: 'ImportStubs.modules is field 1'),
          names,
          reason: 'the stub names, in order',
        );
      },
    );
  }

  // An import stubs arm of empty names: the slots are charged, the payloads
  // are not.
  for (final (count, budget) in [(0, 0), (1, 96), (4, 96), (5, 288)]) {
    _expectBudget(
      _osCallFrame(
        _importStubsArm([
          for (var index = 0; index < count; index++) _bytesOf(''),
        ]),
      ),
      budget,
      reason: 'an import stubs arm with $count empty names',
      check: (event) {
        final osCall = _osCallOf(event);
        expect(
          _present(osCall, 32),
          isTrue,
          reason: 'OsCall.import_stubs is field 32 and must be present',
        );
        final stubs = _stubsOf(osCall);
        expect(
          _texts(stubs, 1, reason: 'ImportStubs.modules is field 1'),
          List.filled(count, ''),
          reason: 'the stub names, all of them empty',
        );
      },
    );
  }
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
    // A key above 2^63, read whole, as upstream prints it (monty-proto
    // 1.1.0's `decode_frame` of these bytes).
    test('a 64-bit key value prints unsigned on every backend', () {
      expect(
        () => FrameScan.decodeChildEvent(_bytes('ffffffffffffffffff01')),
        throwsA(
          isA<FrameDecodeException>().having(
            (e) => e.reason,
            'reason',
            'failed to decode Protobuf message: '
                'invalid key value: 18446744073709551615',
          ),
        ),
      );
    });

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
    for (var field = 1; field <= 32; field++) {
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

  test(
    'frame scanning preserves and validates module import stubs and scan '
    'fields',
    () {
      _checkPreservation();
      _checkModuleValidation();
      _checkStrings();
      _checkWireTypes();
      _checkMerging();
      _checkUnknowns();
      _checkBudgets();
    },
  );
}
