// The worker value arena (lib/src/worker/arena_*.dart): the M2 subset both
// ways, identity, integer and float edge cases, malformed input,
// and depth, and the module arenas an import builds. Pure Dart, so the
// unit and unit_web steps run it on the VM, dart2js and dart2wasm.
import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/arena_reader.dart';
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/host_objects.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:protobuf/protobuf.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';

pb.Arena _arena(List<pb.MontyNode> nodes) =>
    pb.Arena(nodeCount: nodes.length, nodes: nodes);

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

/// One wire field of a protobuf buffer: its `tag`, its payload varint for
/// wire type 0 and its payload bytes for wire type 2.
typedef _WireField = ({int tag, int varint, List<int> bytes});

/// The `module` arm of a `MontyNode` (monty.proto `ModuleNode module = 32`),
/// which the generated bindings predate: a module's expectations are
/// expressed as wire bytes the test encodes itself, read through the
/// `pb.MontyNode.fromBuffer` seam and `getFieldOrNull` reflection
/// (frame_scan_test.dart) rather than a generated constructor.
const int _tagModule = 32;

/// Identity of the module imported as `pkg`.
const _pkgId = '3f2a8c10-9b1e-4c7d-a6f5-0e1d2c3b4a5f';

/// Identity of the module nested under `pkg` as `sub`.
const _subId = '7d4e5f60-1234-4abc-9def-aabbccddeeff';

/// Identity of the host class a module exports an instance of.
const _boxClassId = '0123abcd-0000-4000-8000-00000000cafe';

/// Identity of that class's instance.
const _boxId = '00112233-4455-4667-8999-aabbccddeeff';

/// The host object a module exports.
final class _Box {
  const _Box(this.n);

  final int n;
}

/// `Box`: one eager instance field, `n`.
final HostClass<_Box> _boxClass = HostClass(
  'Box',
  instance: (
    fields: {'n': (box) => MontyInt(box.n)},
    properties: const {},
    methods: const {},
  ),
);

/// The 16 bytes of the uuid [id], its hex digits in order.
List<int> _uuidBytes(String id) {
  final hex = id.replaceAll('-', '');

  return [
    for (var i = 0; i < 32; i += 2)
      int.parse(hex.substring(i, i + 2), radix: 16),
  ];
}

/// The bytes of the `Uuid` message carrying [id] (`bytes data = 1`).
List<int> _uuidMessage(String id) => _lenDelim(1, _uuidBytes(id));

/// The wire form of `_pkgId`'s uuid.
final List<int> _pkgUuid = _uuidMessage(_pkgId);

/// The wire form of `_subId`'s uuid.
final List<int> _subUuid = _uuidMessage(_subId);

/// The bytes of `_boxClassId`'s uuid.
final List<int> _boxClassIdBytes = _uuidBytes(_boxClassId);

/// [value] as a protobuf varint, least significant group first.
List<int> _varint(int value) {
  var rest = value;
  final groups = [rest & 0x7f];
  while (rest >= 0x80) {
    rest >>= 7;
    groups.add(rest & 0x7f);
  }
  // Each group but the last keeps its continuation bit.
  final last = itemAt(groups, groups.length - 1);

  return [
    for (var i = 0; i + 1 < groups.length; i++) itemAt(groups, i) | 0x80,
    last,
  ];
}

/// Field [tag], wire type 0, holding [value].
List<int> _varintField(int tag, int value) => [
  ..._varint(tag << 3),
  ..._varint(value),
];

/// Field [tag], wire type 2, holding [payload].
List<int> _lenDelim(int tag, List<int> payload) => [
  ..._varint(tag << 3 | 2),
  ..._varint(payload.length),
  ...payload,
];

/// The bytes of a `NodePairs` message holding [pairs] (`pairs = 1`), a
/// zero index omitted, as the wire never carries an implicit-presence
/// scalar at its default.
List<int> _nodePairsBody(List<(int, int)> pairs) => [
  for (final (key, value) in pairs)
    ..._lenDelim(1, [
      if (key > 0) ..._varintField(1, key),
      if (value > 0) ..._varintField(2, value),
    ]),
];

/// The bytes of a `ModuleNode` (`name = 1`, `id = 2`, `attrs = 3`), encoded
/// as upstream's encoder writes them (monty-proto `wire.rs`): the id and
/// attrs messages always, a zero index never.
List<int> _moduleBody(String name, List<int> id, List<(int, int)> attrs) => [
  ..._lenDelim(1, utf8.encode(name)),
  ..._lenDelim(2, id),
  ..._lenDelim(3, _nodePairsBody(attrs)),
];

/// A `MontyNode` whose `module` arm holds [body], built from bytes: the
/// bindings have no field for the arm, so the arm travels as bytes.
pb.MontyNode _moduleNode(List<int> body) =>
    pb.MontyNode.fromBuffer(_lenDelim(_tagModule, body));

/// The fields of [buffer], a protobuf message, in wire order.
List<_WireField> _wireFields(List<int> buffer) {
  final fields = <_WireField>[];
  var at = 0;
  while (at < buffer.length) {
    var key = 0;
    var group = 0;
    int byte;
    do {
      byte = itemAt(buffer, at);
      at += 1;
      key |= (byte & 0x7f) << (group * 7);
      group += 1;
    } while (byte & 0x80 != 0);
    final tag = key >> 3;
    switch (key & 7) {
      case 0:
        var payload = 0;
        var shift = 0;
        int part;
        do {
          part = itemAt(buffer, at);
          at += 1;
          payload |= (part & 0x7f) << shift;
          shift += 7;
        } while (part & 0x80 != 0);
        fields.add((tag: tag, varint: payload, bytes: const []));
      case 2:
        var length = 0;
        var shift = 0;
        int part;
        do {
          part = itemAt(buffer, at);
          at += 1;
          length |= (part & 0x7f) << shift;
          shift += 7;
        } while (part & 0x80 != 0);
        fields.add((
          tag: tag,
          varint: 0,
          bytes: buffer.sublist(at, at + length),
        ));
        at += length;
      default:
        fail('wire type ${key & 7} of field $tag, in $buffer');
    }
  }

  return fields;
}

/// The `module` arm of an emitted [node]: the bytes of its field
/// [_tagModule], straight off the node's own wire form.
List<int> _moduleArmOf(pb.MontyNode node) => [
  for (final field in _wireFields(node.writeToBuffer()))
    if (field.tag == _tagModule) ...field.bytes,
];

/// The single length-delimited field [tag] of [body].
List<int> _fieldBytes(List<int> body, int tag) => onlyItem([
  for (final field in _wireFields(body))
    if (field.tag == tag) field.bytes,
]);

/// The attr pairs of a module arm [body], decoded by the generated
/// `NodePairs` and read by reflection.
List<Object?> _pairsOf(List<int> body) =>
    switch (pb.NodePairs.fromBuffer(_fieldBytes(body, 3)).getFieldOrNull(1)) {
      final List<Object?> pairs => pairs,
      _ => const [],
    };

/// Field [tag] of [message] as an int, by reflection: the field must be one
/// the message's schema knows, and an omitted scalar is that field's own
/// default, because the wire never carries a zero the schema defaults to.
int _intOf(GeneratedMessage message, int tag, String what) {
  expect(message.info_.fieldInfo.containsKey(tag), isTrue, reason: what);

  return switch (message.getFieldOrNull(tag)) {
    final int value => value,
    null => message.getDefaultForField(tag) as int,
    _ => fail('$what: not an int'),
  };
}

/// The attr pair at [i] of a module arm's decoded [pairs].
pb.NodePair _pairAt(List<Object?> pairs, int i) => switch (itemAt(pairs, i)) {
  final pb.NodePair pair => pair,
  _ => fail('expected a NodePair at $i, got ${pairs.elementAtOrNull(i)}'),
};

/// Upstream's stage-2 message for node [node] referencing [ref], which is
/// not below it (the reader's own, `invalid value for Arena: ...`).
String _notBelow(int node, int ref) {
  const head = 'invalid value for Arena: value node ';

  return '$head$node references node $ref, which is not below it';
}

/// Upstream's refusal of a module sent as an ordinary value (monty-proto
/// encode.rs), which the writer answers with Python's `TypeError` text.
String get _notAValue {
  const head = 'an ExternalModule enters the sandbox only through ';

  return '${head}external_modules, not as a value';
}

/// A [FormatException] whose message is exactly [message], as the reader
/// reports an arena it refuses.
Matcher _refusedAs(String message) => throwsA(
  isA<FormatException>().having((e) => e.message, 'message', message),
);

/// An [ArgumentError] whose message contains [message], as the writer
/// refuses before the wire what the sandbox would refuse after it.
Matcher _refusing(String message) => throwsA(
  isA<ArgumentError>().having(
    (e) => '${e.message}',
    'message',
    contains(message),
  ),
);

void main() {
  group('decode', () {
    test('scalars', () {
      expect(_decode([pb.MontyNode(none: pb.Unit())]), const MontyNone());
      expect(_decode([pb.MontyNode(boolean: true)]), const MontyBool(true));
      expect(_decode([intNode(-41)]), const MontyInt(-41));
      expect(_decode([floatNode(1.5)]), const MontyFloat(1.5));
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
      expect(_decode([pb.MontyNode(path: '/x')]), MontyPath('/x'));
    });

    test('an integral float stays a float on every compiler', () {
      final v = _decode([floatNode(4)]);
      expect(v, isA<MontyFloat>());
    });

    test('-0.0 keeps its sign', () {
      // ignore: prefer_int_literals -- the sign of zero is the point.
      final zero = _decode([floatNode(-0.0)]);
      expect(_bits((zero as MontyFloat).value), '8000000000000000');
    });

    test('ints: MontyInt within 2^53, MontyBigInt beyond, either arm', () {
      final cases = <String, Object>{
        '9007199254740992': const MontyInt(9007199254740992),
        '-9007199254740992': const MontyInt(-9007199254740992),
        '9007199254740993': MontyBigInt(_two53 + BigInt.one),
        '-9007199254740993': MontyBigInt(-_two53 - BigInt.one),
        '9223372036854775807': MontyBigInt(BigInt.parse('9223372036854775807')),
        '-9223372036854775808': MontyBigInt(
          BigInt.parse('-9223372036854775808'),
        ),
      };
      for (final MapEntry(:key, :value) in cases.entries) {
        final v = _decode([bigIntNode(BigInt.parse(key))]);
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
      final one = intNode(1);
      final v = _decode([
        one,
        pb.MontyNode(str: 'one'),
        intNode(-3),
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
      final three = intNode(3);
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
        intNode(1),
        intNode(2),
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
        intNode(1),
        pb.MontyNode(list: _ix([0])),
      ]);
      expect(
        () => (v as MontyList).items.add(const MontyNone()),
        throwsUnsupportedError,
      );
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
          intNode(1),
          pb.MontyNode(list: _ix([5])),
        ]),
        throwsFormatException,
      );
      expect(() => _decode([intNode(1)], 1), throwsFormatException);
      expect(() => _decode([intNode(1)], -1), throwsFormatException);
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
        MontyPath('/x'),
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

    test('100,000 levels of nesting encode without recursion', () {
      MontyValue v = const MontyNone();
      for (var i = 0; i < 100000; i++) {
        v = MontyList([v]);
      }
      final writer = ArenaWriter();
      expect(writer.add(v), 100000);
    });
  });

  test(
    'module arenas preserve import graphs and validate output references',
    () {
      // Upstream: monty-python src/external.rs `module_value` (a module's
      // public attrs, callables named by their dotted path, submodules
      // nested), monty-proto tests/roundtrip.rs `module_values_round_trip`,
      // monty-python tests/test_external_modules.py (a module crossing back
      // with its id, a module refused as a value) and monty-proto
      // tests/differential.rs (a malformed ModuleNode).
      final objects = HostObjects();
      final writer = ArenaWriter(objects: objects);
      final boxType = ClassType(_boxClass, id: _boxClassId);
      final box = ClassInstance(
        const _Box(1),
        classType: boxType,
        id: _boxId,
        policies: const (
          eagerAttrs: 'all',
          lazyAttrs: null,
          allowedMethods: null,
        ),
      );
      final sub = ExternalModule({'VERSION': 2}, id: _subId);
      // A callable the sandbox never reaches from here: the wire carries its
      // dotted name and its docstring, and a call dispatches by that name.
      final add = MontyHostFunction(
        'add',
        (args, kwargs) => const MontyInt(0),
        docstring: 'adds two integers',
      );
      final pkg = ExternalModule({
        'add': add,
        '_secret': 13,
        'VERSION': 3,
        'sub': sub,
        'twin': sub,
        'box': box,
      }, id: _pkgId);

      // The import graph, post-order: a name leaf and a value for each
      // public attr, the nested module a node of its own that 'twin' shares,
      // the instance's class before its eager attrs, the module itself last.
      final root = addImport(writer, 'pkg', pkg);
      expect(root, 14);
      final nodes = writer.arena.nodes;
      expect(nodes, hasLength(15));
      expect(writer.arena.nodeCount, 15);

      // Private attrs are filtered before the wire, so '_secret' never
      // appears among the name leaves.
      expect(
        [
          for (final node in nodes)
            if (node.whichKind() == pb.MontyNode_Kind.str) node.str,
        ],
        ['add', 'VERSION', 'sub', 'VERSION', 'twin', 'box', 'n'],
      );
      final addNode = itemAt(nodes, 1);
      expect(addNode.whichKind(), pb.MontyNode_Kind.function);
      expect(addNode.function.name, 'pkg.add');
      expect(addNode.function.docstring, 'adds two integers');

      // A nested module imports under its dotted name, keeps its own id and
      // carries its attrs as node indexes.
      final pkgArm = _moduleArmOf(itemAt(nodes, root));
      expect(
        _moduleArmOf(itemAt(nodes, 7)),
        _moduleBody('pkg.sub', _subUuid, const [(5, 6)]),
      );
      expect(
        pkgArm,
        _moduleBody('pkg', _pkgUuid, const [
          (0, 1),
          (2, 3),
          (4, 7),
          (8, 7),
          (9, 13),
        ]),
      );

      // 'sub' and 'twin' name one module, so one node: the attrs read by
      // reflection, the first key's zero index supplied by the field's own
      // default, and pair 3 ('twin') carrying the reference pair 2 ('sub')
      // does.
      final pairs = _pairsOf(pkgArm);
      final addPair = _pairAt(pairs, 0);
      expect(_intOf(addPair, 1, 'NodePair.key'), 0);
      expect(_intOf(addPair, 2, 'NodePair.value'), 1);
      final subNode = _intOf(_pairAt(pairs, 2), 2, 'NodePair.value');
      expect(subNode, 7);
      expect(_intOf(_pairAt(pairs, 3), 2, 'NodePair.value'), subNode);

      // The host object registers in the session's registry as it crosses:
      // the instance as a class instance node, its class beside it.
      final boxNode = itemAt(nodes, 13);
      expect(boxNode.whichKind(), pb.MontyNode_Kind.classInstance);
      expect(boxNode.classInstance.instanceId.data, _uuidBytes(_boxId));
      expect(boxNode.classInstance.classType, 10);
      final typeNode = itemAt(nodes, 10);
      expect(typeNode.whichKind(), pb.MontyNode_Kind.type);
      expect(typeNode.type.name, 'Box');
      expect(typeNode.type.id.data, _boxClassIdBytes);
      final theClass = same(boxType);
      expect(objects[_boxId], same(box));
      expect(objects[_boxClassId], theClass);

      // A module the sandbox sends back (test_external_modules.py:432): the
      // id it imported with, no stubs, and its attrs as the sandbox's values
      // -- a function comes back as its name, a submodule as a module.
      final out = [
        pb.MontyNode(str: 'add'),
        functionNode('pkg.add'),
        pb.MontyNode(str: 'VERSION'),
        intNode(3),
        pb.MontyNode(str: 'sub'),
        _moduleNode(_moduleBody('pkg.sub', _subUuid, const [])),
        _moduleNode(
          _moduleBody('pkg', _pkgUuid, const [
            (0, 1),
            (2, 3),
            (4, 5),
          ]),
        ),
      ];
      final aModule = isA<ExternalModule>();
      expect(
        _decode(out),
        aModule
            .having((m) => m.id, 'id', _pkgId)
            .having((m) => m.stubs, 'stubs', isNull)
            .having(
              (m) => m.attrs,
              'attrs',
              {
                'add': const MontyString('pkg.add'),
                'VERSION': const MontyInt(3),
                'sub': aModule,
              },
            ),
      );
      expect(
        _decode(out, 5),
        aModule
            .having((m) => m.id, 'id', _subId)
            .having((m) => m.stubs, 'stubs', isNull)
            .having((m) => m.attrs, 'attrs', isEmpty),
      );

      // A module is named by its external_modules path, which a value has
      // none of: as an ordinary input it never crosses (monty-proto
      // encode.rs).
      expect(
        () => ArenaWriter().add(pkg),
        _refusing(_notAValue),
      );

      // A malformed ModuleNode (differential.rs:803-814): its id and attrs
      // are required and its id a 16-byte uuid; and a module's references
      // obey the arena's post-order like any other node's.
      final name = _lenDelim(1, utf8.encode('tools'));
      final attrs = _lenDelim(3, _nodePairsBody(const []));
      expect(
        () => _decode([
          _moduleNode([...name, ...attrs]),
        ]),
        _refusedAs('missing required field ModuleNode.id'),
      );
      expect(
        () => _decode([
          _moduleNode([...name, ..._lenDelim(2, _subUuid)]),
        ]),
        _refusedAs('missing required field ModuleNode.attrs'),
      );
      expect(
        () => _decode([
          _moduleNode([
            ...name,
            ..._lenDelim(2, _lenDelim(1, [7, 7, 7])),
            ...attrs,
          ]),
        ]),
        _refusedAs(
          'invalid value for ModuleNode.id: uuid must be 16 bytes, got 3',
        ),
      );
      expect(
        () => _decode([
          pb.MontyNode(str: 'k'),
          _moduleNode(_moduleBody('tools', _subUuid, const [(2, 0)])),
        ]),
        _refusedAs(_notBelow(1, 2)),
      );
      expect(
        () => _decode([
          pb.MontyNode(str: 'k'),
          _moduleNode(_moduleBody('tools', _subUuid, const [(0, 3)])),
        ]),
        _refusedAs(_notBelow(1, 3)),
      );
    },
  );
}
