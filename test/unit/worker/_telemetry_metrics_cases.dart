// R-P2's six scenarios, compared against the pinned Python recording meter.
import 'dart:async';
import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../telemetry/metrics_oracle.dart';
import '../telemetry/recording_adapter.dart';

/// Shared VM/browser runner; raw counts and attributes are never masked.
void telemetryMetricsTests(Future<Monty> Function() start) {
  final adapter = RecordingAdapter();
  setUpAll(() => instrumentTelemetry(adapter));
  final oracle = Map<String, Object>.from(jsonDecode(metricOracleJson) as Map);
  for (final MapEntry(key: scenario, value: expected) in oracle.entries) {
    test('raw metrics match upstream: $scenario', () async {
      adapter.clear();
      await runZoned(() async {
        final pool = await start();
        try {
          await pool.withSession(
            (session) => _scenario(scenario, pool, session, adapter),
          );
        } finally {
          await pool.close();
        }
      }, zoneValues: {#telemetryContext: 'ambient host span'});
      final actual = adapter.measurements;
      expect(actual, isNotEmpty);
      expect(actual.every((m) => m.context == null), isTrue);
      expect(
        actual.every((m) => m.value >= 0 || m.kind == 'up_down_counter'),
        isTrue,
      );
      final normalized = actual.map(_normalize).toList();
      expect(
        _canonical(normalized),
        _canonical(List<Object>.from(expected as List)),
      );
    });
  }
}

Map<String, Object> _normalize(MetricRecord metric) => {
  'name': metric.name,
  'kind': metric.kind,
  'unit': metric.unit,
  'description': metric.description,
  'attributes': metric.attributes,
  'value': metric.unit == 's'
      ? '<seconds>'
      : switch (metric.name) {
          'monty.snapshot.bytes' || 'monty.wire.frame.bytes' => '<bytes>',
          _ => metric.value,
        },
};

List<String> _canonical(List<Object> records) => records.map((record) {
  final map = Map<String, Object?>.from(record as Map);
  final {'attributes': rawAttributes as Map<Object?, Object?>} = map;
  final attributes = Map<String, Object?>.from(rawAttributes);
  final keys = attributes.keys.toList()..sort();
  map['attributes'] = {for (final key in keys) key: attributes[key]};
  final fields = map.keys.toList()..sort();

  return jsonEncode({for (final key in fields) key: map[key]});
}).toList()..sort();

Future<void> _scenario(
  String name,
  Monty pool,
  MontySession session,
  RecordingAdapter adapter,
) async {
  switch (name) {
    case 'plain':
      expect(await session.feedRun('1 + 1'), const MontyInt(2));
    case 'print':
      final printed = <String>[];
      await session.feedRun(
        "print('é🙂')",
        printCallback: (_, text) => printed.add(text),
      );
      expect(printed.join(), 'é🙂\n');
    case 'external':
      expect(
        await session.feedRun(
          'ext(21)',
          externalLookup: {
            'ext': MontyHostFunction('ext', (_, kwargs) => const MontyInt(42)),
          },
        ),
        const MontyInt(42),
      );
    case 'manual':
      final snapshot = await session.feedStart('ext(21)') as FunctionSnapshot;
      expect(snapshot.traceContext(), isNotNull);
      final complete =
          await snapshot.resume(const ExternalReturnValue(MontyInt(42)))
              as MontyComplete;
      expect(complete.output, const MontyInt(42));
    case 'error':
      await expectLater(
        session.feedRun('1/0'),
        throwsA(isA<MontyRuntimeError>()),
      );
    case 'dump_load':
      await session.feedRun('x = 42');
      final state = await session.dump();
      expect(measurements(adapter, 'snapshot.bytes').map((m) => m.value), [
        state.length,
      ]);
      await pool.withSession((restored) async {
        await restored.loadSession(state);
        expect(await restored.feedRun('x'), const MontyInt(42));
      });
    default:
      fail('unknown metric scenario: $name');
  }
}
