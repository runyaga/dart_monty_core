// Literal expectations follow upstream tracing_json.rs and Python repr rules.
import 'dart:convert';

import 'package:dart_monty_core/src/worker/arena_nodes.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry_attributes.dart';
import 'package:dart_monty_core/src/worker/telemetry_values.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:test/test.dart';

void main() {
  test('UTF-8 boundaries distinguish three and four byte characters', () {
    expect(telemetryText('${'x' * 65533}中'), (
      value: '${'x' * 65533}中',
      cut: false,
    ));
    expect(telemetryText('${'x' * 65533}😀'), (value: 'x' * 65533, cut: true));
    expect(telemetryText('${'x' * 65532}😀'), (
      value: '${'x' * 65532}😀',
      cut: false,
    ));
    expect(telemetryJoined(['x' * 65535, 'é']), (
      value: 'x' * 65535,
      cut: true,
    ));
  });
  test('JSON escapes controls and checks UTF-8 byte count before a write', () {
    expect(telemetryList(['a\n"\\\u0000b']).value, r'["a\n\"\\\u0000b"]');
    expect(telemetryList(['é' * 32768]), (value: '["', cut: true));
    expect(
      telemetryPairs(
        pb.Arena(
          nodes: [
            pb.MontyNode(list: pb.Indexes(items: [1])),
            pb.MontyNode(str: 'x' * 65536),
          ],
        ),
        [pb.NodePair(key: 1, value: 0)],
      ),
      (value: '{"', cut: true),
    );
    final arena = pb.Arena(
      nodes: [
        pb.MontyNode(str: 'x' * 65536),
        pb.MontyNode(list: pb.Indexes(items: [0])),
      ],
    );
    expect(telemetryPairs(arena, [pb.NodePair(key: 1, value: 0)]), (
      value: '{',
      cut: true,
    ));
  });
  test('feed inputs use names and bounded JSON values', () {
    final attributes = feedAttributes(
      pb.Feed(
        code: 'x',
        inputs: [pb.NamedRef(name: 'x', value: 0)],
        values: pb.Arena(nodes: [intNode(42)]),
      ),
    );
    expect(attributes.values['inputs'], '{"x":42}');
    expect(attributes.values['code'], 'x');
  });
  test(
    'host results distinguish failures, futures, missing and absent names',
    () {
      final arena = pb.Arena();
      final cases = [
        (pb.ExtFunctionResult(), '<missing>'),
        (
          pb.ExtFunctionResult(
            error: pb.RaisedException(excType: 'ValueError', message: 'bad'),
          ),
          'raise ValueError: bad',
        ),
        (pb.ExtFunctionResult(future: 7), 'future 7'),
        (pb.ExtFunctionResult(notFound: 'x'), 'not found: x'),
        (pb.ExtFunctionResult(notHandled: pb.Unit()), 'not handled'),
      ];
      for (final (result, expected) in cases) {
        expect(telemetryResult(result, arena), (value: expected, cut: false));
      }
    },
  );
  test('structured classes encode type metadata, identity and attributes', () {
    final id = pb.Uuid(data: List.filled(16, 0));
    final arena = pb.Arena(
      nodes: [
        pb.MontyNode(str: 'x'),
        intNode(42),
        pb.MontyNode(
          type: pb.Type(
            name: 'Box',
            id: id,
            origin: originHost,
            isDataclass: true,
            attrs: pb.NodePairs(pairs: [pb.NodePair(key: 0, value: 1)]),
          ),
        ),
        pb.MontyNode(
          classInstance: pb.ClassInstanceNode(
            classType: 2,
            instanceId: id,
            attrs: pb.NodePairs(pairs: [pb.NodePair(key: 0, value: 1)]),
          ),
        ),
        pb.MontyNode(
          classInstance: pb.ClassInstanceNode(classType: 99, instanceId: id),
        ),
        pb.MontyNode(
          type: pb.Type(name: 'int', origin: originBuiltin),
        ),
        pb.MontyNode(
          classInstance: pb.ClassInstanceNode(classType: 5, instanceId: id),
        ),
      ],
    );
    const type = {
      'name': 'Box',
      'id': '00000000-0000-0000-0000-000000000000',
      'host_defined': true,
      'is_dataclass': true,
      'attrs': {'x': 42},
    };
    expect(jsonDecode(telemetryValue(arena, 2).value as String), type);
    expect(jsonDecode(telemetryValue(arena, 3).value as String), {
      'type': type,
      'id': '00000000-0000-0000-0000-000000000000',
      'attrs': {'x': 42},
    });
    for (final index in [4, 6]) {
      expect(jsonDecode(telemetryValue(arena, index).value as String), {
        'type': '<invalid>',
        'id': '00000000-0000-0000-0000-000000000000',
        'attrs': <String, Object>{},
      });
    }
  });
  test('all remaining scalar display forms retain Python semantics', () {
    final cases = <(pb.MontyNode, Object?)>[
      (pb.MontyNode(bytes: [65, 0]), r'A\x00'),
      (
        pb.MontyNode(
          datetime: pb.DateTime(year: 2024, month: 1, day: 2, hour: 3),
        ),
        '2024-01-02T03:00:00',
      ),
      (
        pb.MontyNode(
          timedelta: pb.TimeDelta(days: 1, seconds: 2, microseconds: 500000),
        ),
        86402.5,
      ),
      (pb.MontyNode(exception: pb.Exception(arg: 'bad')), 'bad'),
      (pb.MontyNode(path: '/x'), '/x'),
      (pb.MontyNode(cycle: 'loop'), '<circular reference>'),
      (pb.MontyNode(repr: 'opaque'), 'opaque'),
      (pb.MontyNode(ellipsis: pb.Unit()), 'Ellipsis'),
      (pb.MontyNode(notImplemented: pb.Unit()), 'NotImplemented'),
      (pb.MontyNode(builtinFunction: 'len'), '<built-in function len>'),
      (
        pb.MontyNode(function: pb.Function_(name: 'ext')),
        "<function 'ext' external>",
      ),
      (
        pb.MontyNode(
          type: pb.Type(name: 'int', origin: originBuiltin),
        ),
        "<class 'int'>",
      ),
      (pb.MontyNode(), '<invalid>'),
      (floatNode(double.negativeInfinity), '-inf'),
    ];
    for (final (node, expected) in cases) {
      expect(
        jsonDecode(
          telemetrySequence(pb.Arena(nodes: [node]), [0]).value as String,
        ),
        [expected],
      );
    }
  });
  test('timezone and file representations preserve names and mode classes', () {
    final cases = [
      (
        pb.MontyNode(timezone: pb.TimeZone(offsetSeconds: -3661, name: 'west')),
        "datetime.timezone(datetime.timedelta(days=-1, seconds=82739), 'west')",
      ),
      (
        pb.MontyNode(timezone: pb.TimeZone(offsetSeconds: 0, name: 'zero')),
        "datetime.timezone(datetime.timedelta(0), 'zero')",
      ),
      (
        pb.MontyNode(
          fileHandle: pb.FileHandle(path: '/x', mode: 'w'),
        ),
        "<_io.TextIOWrapper name='/x' mode='w'>",
      ),
      (
        pb.MontyNode(
          fileHandle: pb.FileHandle(path: '/x', mode: 'wb+'),
        ),
        "<_io.BufferedRandom name='/x' mode='wb+'>",
      ),
      (
        pb.MontyNode(
          fileHandle: pb.FileHandle(path: '/x', mode: 'wb'),
        ),
        "<_io.BufferedWriter name='/x' mode='wb'>",
      ),
      (
        pb.MontyNode(
          complex: pb.Complex(
            real: doubleToBits(1e20),
            imag: doubleToBits(1e-6),
          ),
        ),
        '(1e+20+1e-06j)',
      ),
      (
        pb.MontyNode(
          complex: pb.Complex(real: doubleToBits(0), imag: doubleToBits(2)),
        ),
        '2j',
      ),
    ];
    for (final (node, expected) in cases) {
      expect(
        jsonDecode(telemetryValue(pb.Arena(nodes: [node]), 0).value as String),
        expected,
      );
    }
  });
}
