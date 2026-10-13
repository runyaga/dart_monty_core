// EncodedLength (lib/src/worker/encoded_length.dart): the length
// package:protobuf's writer produces, computed without writing. Pure Dart, so
// it runs on the VM, dart2js and dart2wasm.
import 'dart:convert';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/worker/encoded_length.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:fixnum/fixnum.dart';
import 'package:protobuf/protobuf.dart';
import 'package:protobuf/well_known_types/google/protobuf/struct.pb.dart';
import 'package:test/test.dart';

void _same(GeneratedMessage message) =>
    expect(EncodedLength.of(message), message.writeToBuffer().length);

/// Strings that cover every UTF-8 width, and the unpaired surrogates
/// package:protobuf writes as U+FFFD.
const _strings = [
  '',
  'ascii',
  'é߿',
  'ࠀ€￿',
  '\u{1F600}\u{10FFFF}',
  '\ud800',
  '\udc00x',
  '\udc00\ud800',
  'a\ud83d',
];

String _pick(Random random) =>
    _strings.elementAtOrNull(random.nextInt(_strings.length)) ?? '';

pb.MontyNode _node(Random random) => switch (random.nextInt(9)) {
  0 => pb.MontyNode(boolean: random.nextBool()),
  1 => pb.MontyNode(
    int_5: Int64(random.nextInt(1 << 30)) << random.nextInt(34),
  ),
  2 => pb.MontyNode(float: Int64(-random.nextInt(1 << 30))),
  3 => pb.MontyNode(str: _pick(random) * 40),
  4 => pb.MontyNode(bytes: List.generate(random.nextInt(300), (i) => i % 256)),
  5 => pb.MontyNode(
    list: pb.Indexes(
      items: List.generate(random.nextInt(200), (_) => random.nextInt(1 << 31)),
    ),
  ),
  6 => pb.MontyNode(
    datetime: pb.DateTime(
      year: random.nextInt(4000) - 2000,
      offsetSeconds: -random.nextInt(86400),
      timezoneName: _pick(random),
    ),
  ),
  7 => pb.MontyNode(
    type: pb.Type(
      name: 'C',
      origin: random.nextInt(4) - 1,
      isDataclass: random.nextBool(),
      attrs: pb.NodePairs(pairs: [pb.NodePair(key: 1, value: 300)]),
    ),
  ),
  _ => pb.MontyNode(none: pb.Unit()),
};

pb.ParentRequest _request(Random random) {
  final arena = pb.Arena(
    nodeCount: random.nextInt(1 << 20),
    nodes: List.generate(random.nextInt(12), (_) => _node(random)),
  );

  return switch (random.nextInt(4)) {
    0 => pb.ParentRequest(
      feed: pb.Feed(
        code: _pick(random) * random.nextInt(50),
        inputs: [pb.NamedRef(name: 'x', value: random.nextInt(1000))],
        values: arena,
        skipTypeCheck: random.nextBool(),
      ),
    ),
    1 => pb.ParentRequest(
      resumeCall: pb.ResumeCall(
        callId: random.nextInt(1 << 31),
        result: pb.ExtFunctionResult(returnValue: random.nextInt(1 << 20)),
        values: arena,
      ),
      traceParent: _pick(random),
    ),
    2 => pb.ParentRequest(
      resumeFutures: pb.ResumeFutures(
        results: [
          pb.FutureResult(
            callId: 7,
            result: pb.ExtFunctionResult(
              error: pb.RaisedException(
                excType: 'ValueError',
                message: _pick(random),
                traceback: [
                  pb.StackFrame(
                    filename: 'f.py',
                    start: pb.CodeLoc(line: 1, column: 300),
                    hideCaret: true,
                  ),
                ],
              ),
            ),
          ),
        ],
        values: arena,
      ),
    ),
    _ => pb.ParentRequest(
      configure: pb.Configure(
        scriptName: 'main.py',
        limits: pb.ResourceLimits(
          maxMemoryBytes: Int64.MAX_VALUE,
          gcInterval: Int64.MIN_VALUE,
        ),
        typeCheckFormat: pb.TypeCheckFormat.values.elementAtOrNull(
          random.nextInt(10),
        ),
        protocolVersion: 5,
        osPolicy: pb.OsPolicy(
          fixed: pb.FixedDateTime(unixSeconds: Int64(-1), microsecond: 9),
          seed: pb.RandomSeed(float: 0.5),
        ),
      ),
    ),
  };
}

void main() {
  group('equals the written length', () {
    test('the default message: zero', () {
      expect(EncodedLength.of(pb.ParentRequest()), 0);
    });

    test('every string width, and unpaired surrogates', () {
      for (final text in _strings) {
        _same(pb.ParentRequest(feed: pb.Feed(code: text)));
        expect(EncodedLength.utf8(text), utf8.encode(text).length);
      }
    });

    test('negative int32: ten bytes; negative enum numbers: five', () {
      _same(pb.MontyNode(date: pb.Date(year: -1)));
      _same(pb.MontyNode(type: pb.Type(origin: -5)));
      _same(
        pb.Configure(
          typeCheckFormat: pb.TypeCheckFormat.TYPE_CHECK_FORMAT_GITHUB,
        ),
      );
    });

    test('64-bit extremes', () {
      for (final v in [
        Int64.ZERO,
        Int64.ONE,
        Int64.MAX_VALUE,
        Int64.MIN_VALUE,
        -Int64.ONE,
        Int64(1) << 35,
      ]) {
        _same(pb.MontyNode(int_5: v));
        _same(pb.FixedDateTime(unixSeconds: v));
      }
    });

    test('defaults set explicitly are written, and counted', () {
      _same(pb.Configure(scriptName: '', typeCheck: false, protocolVersion: 0));
      _same(pb.MontyNode(int_5: Int64.ZERO));
      _same(pb.Complex(real: Int64.ZERO, imag: Int64.ZERO));
    });

    test('packed repeated fields, empty and not', () {
      _same(pb.Indexes());
      _same(pb.Indexes(items: [0]));
      _same(pb.Indexes(items: [1 << 31, 127, 128, 16383, 16384]));
    });

    test('unknown fields of every wire type', () {
      final message = pb.Feed(code: 'x')
        ..unknownFields.mergeVarintField(100, Int64(-1))
        ..unknownFields.mergeFixed32Field(101, 7)
        ..unknownFields.mergeFixed64Field(102, Int64(7))
        ..unknownFields.mergeLengthDelimitedField(103, [1, 2, 3])
        ..unknownFields.mergeGroupField(
          104,
          UnknownFieldSet()..mergeVarintField(1, Int64(300)),
        );
      _same(message);
    });

    test('one message reached twice is written, and counted, twice', () {
      final node = pb.MontyNode(str: 'x' * 1000);
      _same(pb.Arena(nodes: [node, node, node]));
    });

    test('400 random requests', () {
      final random = Random(20261013);
      for (var i = 0; i < 400; i++) {
        _same(_request(random));
      }
    });
  });

  test('a map field, which the schema has none of, is refused', () {
    final struct = Struct()..fields['k'] = Value(stringValue: 'v');
    expect(() => EncodedLength.of(struct), throwsUnsupportedError);
  });

  test('a message reached many times is measured once', () {
    // 2^33 bytes when written; measured from one MiB.
    final node = pb.MontyNode(str: 'x' * (1 << 20));
    final arena = pb.Arena(nodes: List.filled(8192, node));
    // Per entry: key, 3-byte length, then the node: key, 3-byte length, text.
    expect(EncodedLength.of(arena), ((1 << 20) + 8) * 8192);
  });
}
