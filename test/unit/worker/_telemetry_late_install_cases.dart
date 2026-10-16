import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../telemetry/recording_adapter.dart';

/// One installation per isolate, with idle and checked-out pools.
void telemetryLateInstallTests(Future<Monty> Function() start) {
  test('gauges balance installation after start and during checkout', () async {
    final pools = <Monty>[];
    for (var i = 0; i < 3; i++) {
      final pool = await start();
      addTearDown(pool.close);
      pools.add(pool);
    }
    final [closedPool, idlePool, busyPool] = pools;
    await closedPool.close();
    final busy = await busyPool.checkout();
    addTearDown(busy.close);
    final pending = await busy.feedStart('ext()') as FunctionSnapshot;
    final adapter = RecordingAdapter();
    instrumentTelemetry(adapter);
    // Hand-counted workers: two live, one idle. No recorder observed the
    // existing suspension, so its eventual answer must not decrement a gauge.
    expectGauges(adapter, live: 2, idle: 1, suspended: 0);
    final complete = await pending.resume(
      const ExternalReturnValue(MontyInt(42)),
    );
    expect((complete as MontyComplete).output, const MontyInt(42));
    await busy.close();
    expectGauges(adapter, live: 2, idle: 2, suspended: 0);
    final session = await idlePool.checkout();
    addTearDown(session.close);
    final snapshot = await session.feedStart('ext()') as FunctionSnapshot;
    expectGauges(adapter, live: 2, idle: 1, suspended: 1);
    await snapshot.resume(const ExternalReturnValue(MontyInt(7)));
    await session.close();
    await idlePool.close();
    await busyPool.close();
    expectGauges(adapter, live: 0, idle: 0, suspended: 0);
    expect(
      measurements(adapter, 'pool.workers.suspended').map((m) => m.value),
      [1, -1],
    );
  });
}

void expectGauges(
  RecordingAdapter adapter, {
  required int live,
  required int idle,
  required int suspended,
}) {
  for (final (name, expected) in [
    ('live', live),
    ('idle', idle),
    ('suspended', suspended),
  ]) {
    num total = 0;
    for (final sample in measurements(adapter, 'pool.workers.$name')) {
      total += sample.value;
      expect(total, greaterThanOrEqualTo(0), reason: '$name prefix');
    }
    expect(total, expected, reason: '$name total');
  }
}
