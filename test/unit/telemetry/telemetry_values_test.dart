// Constants taken from upstream tracing_json.rs tests and its documented cap.
import 'dart:convert';

import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry_values.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:test/test.dart';

pb.Arena _arena(List<pb.MontyNode> nodes) =>
    pb.Arena(nodeCount: nodes.length, nodes: nodes);

void main() {
  test('typed scalar attributes and compound JSON follow upstream', () {
    final arena = _arena([
      pb.MontyNode(none: pb.Unit()),
      intNode(42),
      floatNode(1.5),
      pb.MontyNode(boolean: true),
      pb.MontyNode(str: 'x'),
      pb.MontyNode(list: pb.Indexes(items: [0, 1, 2, 3, 4])),
    ]);
    expect(telemetryValue(arena, 0), (value: 'null', cut: false));
    expect(telemetryValue(arena, 1), (value: 42, cut: false));
    expect(telemetryValue(arena, 2), (value: 1.5, cut: false));
    expect(telemetryValue(arena, 3), (value: true, cut: false));
    expect(telemetryValue(arena, 4), (value: 'x', cut: false));
    expect(telemetryValue(arena, 5), (
      value: '[null,42,1.5,true,"x"]',
      cut: false,
    ));
    expect(telemetryValue(arena, 99), (value: '<missing>', cut: false));
  });

  test('invalid forward child and cycles never recurse', () {
    final arena = _arena([
      pb.MontyNode(list: pb.Indexes(items: [0, 99])),
    ]);
    expect(telemetryValue(arena, 0).value, '["<invalid>","<invalid>"]');
    final nodes = [intNode(1)];
    for (var i = 0; i < 66; i++) {
      nodes.add(pb.MontyNode(list: pb.Indexes(items: [i])));
    }
    final deep = telemetryValue(_arena(nodes), 66).value as String;
    expect(deep, contains('"<too deep>"'));
    expect(deep, isNot(contains('<invalid>')));
  });

  test('raw UTF-8 cap preserves whole characters and marks cuts', () {
    final text = '${'x' * 65535}é';
    final rendered = telemetryText(text);
    expect(rendered.value, 'x' * 65535);
    expect(rendered.cut, isTrue);
    expect(telemetryText('é' * 32768).cut, isFalse);
  });

  test(
    'JSON cap rejects a whole serializer write instead of truncating it',
    () {
      final arena = _arena([
        pb.MontyNode(str: 'x' * 65536),
        pb.MontyNode(list: pb.Indexes(items: [0])),
      ]);
      expect(telemetryValue(arena, 1), (value: '["', cut: true));
      expect(telemetryList(List.filled(70000, 1)).cut, isTrue);
      final attributes = TelemetryAttributes()
        ..add('output', telemetryValue(arena, 1));
      expect(attributes.values, {
        'output': '["',
        'length_limit_exceeded': true,
      });
    },
  );

  test('bytes keep repr content and flag omitted input', () {
    expect(
      telemetryBytes([0, 9, 10, 39, 34, 92, 255]).value,
      r'''\x00\t\n\'"\\\xff''',
    );
    expect(telemetryBytes(List.filled(65537, 65)), (
      value: 'A' * 65536,
      cut: true,
    ));
  });

  test('nonfinite floats and integers beyond i128 keep upstream encodings', () {
    final huge = BigInt.one << 128;
    final arena = _arena([
      floatNode(double.nan),
      floatNode(double.infinity),
      bigIntNode(BigInt.one << 80),
      bigIntNode(huge),
      pb.MontyNode(tuple: pb.Indexes(items: [0, 1, 2, 3])),
    ]);
    expect(telemetryValue(arena, 0).value, 'nan');
    expect(
      telemetryValue(arena, 4).value,
      '["nan","inf",1208925819614629174706176,'
      '"340282366920938463463374607431768211456"]',
    );
  });

  test('nonstring dict keys use their JSON encoding', () {
    final arena = _arena([
      intNode(42),
      pb.MontyNode(str: 'value'),
      pb.MontyNode(dict: pb.NodePairs(pairs: [pb.NodePair(key: 0, value: 1)])),
    ]);
    expect(telemetryValue(arena, 2).value, '{"42":"value"}');
  });

  test('date time timezone complex and file encodings match upstream', () {
    final nodes = [
      pb.MontyNode(date: pb.Date(year: 2024, month: 1, day: 2)),
      pb.MontyNode(
        time: pb.Time(
          hour: 3,
          minute: 4,
          second: 5,
          microsecond: 6,
          offsetSeconds: -3661,
        ),
      ),
      pb.MontyNode(timezone: pb.TimeZone(offsetSeconds: 0)),
      pb.MontyNode(
        complex: pb.Complex(real: doubleToBits(1), imag: doubleToBits(-2)),
      ),
      pb.MontyNode(
        fileHandle: pb.FileHandle(path: '/x', mode: 'rb'),
      ),
    ];
    final result = telemetrySequence(_arena(nodes), [0, 1, 2, 3, 4]);
    expect(jsonDecode(result.value as String), [
      '2024-01-02',
      '03:04:05.000006-01:01:01',
      'datetime.timezone.utc',
      '(1-2j)',
      "<_io.BufferedReader name='/x' mode='rb'>",
    ]);
  });
  test('JSON float notation matches upstream pinned serde_json and zmij', () {
    // Independent probe: .gate-logs/r2-json-oracle.txt, serde_json 1.0.151
    // and zmij 1.0.23 from upstream's Cargo.lock.
    final nodes = [
      for (final n in [1e-7, 1e-6, 1e-5, 1e15, 1e16, 1e20, -0.0]) floatNode(n),
    ];
    expect(
      telemetrySequence(
        _arena(nodes),
        List.generate(nodes.length, (i) => i),
      ).value,
      '[1e-7,1e-6,0.00001,1000000000000000.0,1e+16,1e+20,-0.0]',
    );
  });
}
