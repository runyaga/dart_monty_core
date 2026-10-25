// The generated bindings speak upstream's wire format on every compiler.
//
// The two golden frames below were written by upstream monty-proto 1.1.0's
// own Rust encoder (`encode_framed_into`, prost) from a value graph chosen for
// the cases a JavaScript number cannot hold or a naive encoder loses: integers
// beyond 2^53 in both signs, -0.0, a uint64 beyond 2^53, and one sub-list
// referenced twice. Decoding them, and re-encoding to the same bytes, on the
// VM, dart2js and dart2wasm is what shows the generated code and package:
// protobuf are wire-compatible with the worker, not merely self-consistent.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart' hide Frame;
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart';
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

  test(
    'generated bindings recognize v1.2.0 module and OS messages',
    _checkV120ModuleAndOsMessages,
  );
}

Uint8List _bytes(List<int> l) => Uint8List.fromList(l);

// ---------------------------------------------------------------------------
// Upstream v1.2.0 module and OS messages
// ---------------------------------------------------------------------------
//
// Upstream monty v1.2.0 added a host module value (`MontyNode.module`, tag
// 32) and three OS-call arms (`OsCall.import` 31, `OsCall.import_stubs` 32,
// `OsCall.scan` 33). The bytes below are written by hand, the way upstream's
// own prost encoder writes them, so a pass means the generated bindings read
// upstream's bytes -- not merely that they agree with themselves.
//
// The messages are read through the generated message's reflection
// (`info_.fieldInfo`) rather than by naming their fields. A binding that does
// not know a tag then fails an assertion, naming the tag, instead of failing
// to compile or quietly keeping the bytes as unknown fields: unknown fields
// are written back out unchanged, so a byte-for-byte round trip alone would
// pass on bindings that understand nothing of the message.
//
// Upstream: crates/monty-proto/proto/monty/v1/monty.proto at v1.2.0, and the
// round-trip tests crates/monty-proto/tests/roundtrip.rs and
// crates/monty-proto/tests/differential.rs, whose hand-written encoder is
// what these bytes imitate.

/// The wire type of a varint field.
const int _wireVarint = 0;

/// The wire type of a length-delimited field.
const int _wireBytes = 2;

/// A protobuf varint, written by hand.
List<int> _varint(int value) {
  final bytes = <int>[];
  var rest = value;
  while (rest > 0x7f) {
    bytes.add((rest & 0x7f) | 0x80);
    rest >>= 7;
  }

  bytes.add(rest);

  return bytes;
}

/// A tag header: the field number and the wire type.
List<int> _header(int field, int wireType) => _varint((field << 3) | wireType);

/// A length-delimited field: the header, the length and the payload.
List<int> _lengthDelimited(int field, List<int> payload) => [
  ..._header(field, _wireBytes),
  ..._varint(payload.length),
  ...payload,
];

/// A varint field: the header and the value.
List<int> _varintField(int field, int value) => [
  ..._header(field, _wireVarint),
  ..._varint(value),
];

/// Asserts that the generated bindings know [tag] on [message].
///
/// A tag the bindings do not know is an assertion failure, not a thrown
/// [ArgumentError]: the point is that an incomplete binding fails the test
/// with a message that names the tag it is missing.
void _expectRecognized(GeneratedMessage message, int tag, String what) {
  expect(
    message.info_.fieldInfo.containsKey(tag),
    isTrue,
    reason: '$what (tag $tag) is not a recognized field',
  );
}

/// The value of [tag] on [message], or null when it is not set.
///
/// The tag is checked first, so a binding that does not know it fails an
/// assertion instead of reading a field that is not there.
Object? _value(GeneratedMessage message, int tag, String what) {
  _expectRecognized(message, tag, what);

  return message.getFieldOrNull(tag);
}

/// The string on [tag].
String _string(GeneratedMessage message, int tag, String what) {
  final value = _value(message, tag, what);
  expect(value, isA<String>(), reason: '$what (tag $tag) is not a string');
  if (value case final String text) {
    return text;
  }

  fail('$what (tag $tag) is not a string');
}

/// The integer on [tag].
int _int(GeneratedMessage message, int tag, String what) {
  final value = _value(message, tag, what);
  expect(value, isA<int>(), reason: '$what (tag $tag) is not an integer');
  if (value case final int number) {
    return number;
  }

  fail('$what (tag $tag) is not an integer');
}

/// The boolean on [tag].
bool _bool(GeneratedMessage message, int tag, String what) {
  final value = _value(message, tag, what);
  expect(value, isA<bool>(), reason: '$what (tag $tag) is not a boolean');
  if (value case final bool flag) {
    return flag;
  }

  fail('$what (tag $tag) is not a boolean');
}

/// The bytes on [tag].
List<int> _bytesOf(GeneratedMessage message, int tag, String what) {
  final value = _value(message, tag, what);
  expect(value, isA<List<int>>(), reason: '$what (tag $tag) is not bytes');
  if (value case final List<int> bytes) {
    return bytes;
  }

  fail('$what (tag $tag) is not bytes');
}

/// The message on [tag].
GeneratedMessage _message(GeneratedMessage message, int tag, String what) {
  final value = _value(message, tag, what);
  expect(
    value,
    isA<GeneratedMessage>(),
    reason: '$what (tag $tag) is not a message',
  );
  if (value case final GeneratedMessage nested) {
    return nested;
  }

  fail('$what (tag $tag) is not a message');
}

/// The messages on [tag].
List<GeneratedMessage> _messages(
  GeneratedMessage message,
  int tag,
  String what,
) {
  final value = _value(message, tag, what);
  expect(
    value,
    isA<List<GeneratedMessage>>(),
    reason: '$what (tag $tag) is not a list of messages',
  );
  if (value case final List<GeneratedMessage> nested) {
    return nested;
  }

  fail('$what (tag $tag) is not a list of messages');
}

/// The strings on [tag].
List<String> _strings(GeneratedMessage message, int tag, String what) {
  final value = _value(message, tag, what);
  expect(
    value,
    isA<List<String>>(),
    reason: '$what (tag $tag) is not a list of strings',
  );
  if (value case final List<String> nested) {
    return nested;
  }

  fail('$what (tag $tag) is not a list of strings');
}

/// A new, empty message of the type [tag] carries on [owner].
GeneratedMessage _newMessage(GeneratedMessage owner, int tag, String what) {
  _expectRecognized(owner, tag, what);
  final create = owner.info_.fieldInfo[tag]?.subBuilder;
  if (create == null) {
    fail('$what (tag $tag) is not a message field');
  }

  return create();
}

/// The v1.2.0 module and OS messages, read through the generated bindings.
void _checkV120ModuleAndOsMessages() {
  _checkModuleValue();
  _checkOsImport();
  _checkOsImportStubs();
  _checkOsScan();
}

/// The host module value upstream carries in `MontyNode.module` (tag 32).
void _checkModuleValue() {
  final uuid = List.generate(16, (index) => index + 1);
  final moduleBytes = <int>[
    // ModuleNode.name
    ..._lengthDelimited(1, utf8.encode('pkg.sub')),
    // ModuleNode.id, a Uuid
    ..._lengthDelimited(2, _lengthDelimited(1, uuid)),
    // ModuleNode.attrs, a NodePairs of one (name, value) pair
    ..._lengthDelimited(
      3,
      _lengthDelimited(1, [..._varintField(1, 10), ..._varintField(2, 11)]),
    ),
  ];
  final frame = _lengthDelimited(32, moduleBytes);

  final node = pb.MontyNode.fromBuffer(frame);
  _expectRecognized(node, 32, 'MontyNode.module');
  final module = _message(node, 32, 'MontyNode.module');
  expect(
    module.unknownFields.isEmpty,
    isTrue,
    reason: 'ModuleNode kept unknown bytes',
  );
  expect(_string(module, 1, 'ModuleNode.name'), 'pkg.sub');
  final id = _message(module, 2, 'ModuleNode.id');
  expect(_bytesOf(id, 1, 'Uuid.data'), uuid);
  final attrs = _message(module, 3, 'ModuleNode.attrs');
  final pairs = _messages(attrs, 1, 'NodePairs.pairs');
  expect(pairs, hasLength(1));
  final pair = firstItem(pairs);
  expect(_int(pair, 1, 'NodePair.key'), 10);
  expect(_int(pair, 2, 'NodePair.value'), 11);
  expect(module.writeToBuffer(), moduleBytes);
  expect(node.writeToBuffer(), frame);
}

/// The `OsCall.import` arm (tag 31): the module the sandbox could not find.
void _checkOsImport() {
  final importBytes = _lengthDelimited(1, utf8.encode('pkg.sub'));
  final frame = _lengthDelimited(31, importBytes);

  final call = pb.OsCall.fromBuffer(frame);
  _expectRecognized(call, 31, 'OsCall.import');
  final import = _message(call, 31, 'OsCall.import');
  expect(
    import.unknownFields.isEmpty,
    isTrue,
    reason: 'Import kept unknown bytes',
  );
  expect(_string(import, 1, 'Import.module'), 'pkg.sub');
  expect(import.writeToBuffer(), importBytes);
  expect(call.writeToBuffer(), frame);

  // The same message on its own, decoded from the bytes upstream writes for
  // it rather than from the frame that carries it.
  final standalone = _newMessage(call, 31, 'OsCall.import')
    ..mergeFromBuffer(importBytes);
  expect(
    standalone.unknownFields.isEmpty,
    isTrue,
    reason: 'Import kept unknown bytes',
  );
  expect(_string(standalone, 1, 'Import.module'), 'pkg.sub');
  expect(standalone.writeToBuffer(), importBytes);
}

/// The `OsCall.import_stubs` arm (tag 32): the modules to type check.
void _checkOsImportStubs() {
  final stubsBytes = <int>[
    ..._lengthDelimited(1, utf8.encode('pkg')),
    ..._lengthDelimited(1, utf8.encode('pkg.sub')),
  ];
  final frame = _lengthDelimited(32, stubsBytes);

  final call = pb.OsCall.fromBuffer(frame);
  _expectRecognized(call, 32, 'OsCall.import_stubs');
  final stubs = _message(call, 32, 'OsCall.import_stubs');
  expect(
    stubs.unknownFields.isEmpty,
    isTrue,
    reason: 'ImportStubs kept unknown bytes',
  );
  expect(_strings(stubs, 1, 'ImportStubs.modules'), ['pkg', 'pkg.sub']);
  expect(stubs.writeToBuffer(), stubsBytes);
  expect(call.writeToBuffer(), frame);
}

/// The `OsCall.scan` arm (tag 33): a subtree listing.
void _checkOsScan() {
  final path = utf8.encode('/mnt/data');
  // The whole tree, with CPython's default case sensitivity: both optional
  // fields absent.
  final absent = _lengthDelimited(1, path);
  // The same listing with max_depth explicitly zero and case_sensitive
  // explicitly false. Upstream's optional fields carry presence, so both
  // are on the wire even though they hold the default value.
  final explicit = <int>[
    ...absent,
    ..._varintField(2, 0),
    ..._varintField(5, 0),
  ];
  // A glob listing: a pattern to prune by and both symlink switches.
  final glob = <int>[
    ...absent,
    ..._varintField(3, 1),
    ..._lengthDelimited(4, utf8.encode('**')),
    ..._lengthDelimited(4, utf8.encode('*.py')),
    ..._varintField(6, 1),
  ];

  _checkScanAbsent(absent);
  _checkScanExplicit(explicit);
  _checkScanGlob(glob);
}

/// A listing of the whole tree: neither optional field is set.
void _checkScanAbsent(List<int> bytes) {
  final scan = _scan(bytes);
  expect(
    _value(scan, 2, 'Scan.max_depth'),
    isNull,
    reason: 'max_depth is absent',
  );
  expect(
    _value(scan, 5, 'Scan.case_sensitive'),
    isNull,
    reason: 'case_sensitive is absent',
  );
  expect(scan.writeToBuffer(), bytes);
}

/// A listing with both optional fields set to their default value.
///
/// Upstream's optional fields carry presence, so an explicit zero and an
/// explicit false are on the wire where an absent field is not.
void _checkScanExplicit(List<int> bytes) {
  final scan = _scan(bytes);
  expect(
    _value(scan, 2, 'Scan.max_depth'),
    0,
    reason: 'max_depth is explicitly zero',
  );
  expect(
    _value(scan, 5, 'Scan.case_sensitive'),
    false,
    reason: 'case_sensitive is explicitly false',
  );
  expect(scan.writeToBuffer(), bytes);
}

/// A glob listing: a pattern to prune by and both symlink switches.
void _checkScanGlob(List<int> bytes) {
  final scan = _scan(bytes);
  expect(_bool(scan, 3, 'Scan.follow_symlinks'), isTrue);
  expect(_strings(scan, 4, 'Scan.pattern'), ['**', '*.py']);
  expect(_bool(scan, 6, 'Scan.recurse_symlinks'), isTrue);
  expect(scan.writeToBuffer(), bytes);
}

/// The `Scan` message carried by an `OsCall.scan` (tag 33) holding [bytes].
GeneratedMessage _scan(List<int> bytes) {
  final call = pb.OsCall.fromBuffer(_lengthDelimited(33, bytes));
  _expectRecognized(call, 33, 'OsCall.scan');
  final scan = _message(call, 33, 'OsCall.scan');
  expect(scan.unknownFields.isEmpty, isTrue, reason: 'Scan kept unknown bytes');

  return scan;
}
