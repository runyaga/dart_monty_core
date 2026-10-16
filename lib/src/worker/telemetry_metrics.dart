/// Instruments from pydantic/monty 1.1.0 telemetry/metrics.rs.
library;

import 'package:dart_monty_core/src/worker/telemetry.dart';

/// FOSS instruments, excluding the hosted session-resumed counter.
enum TelemetryMetrics {
  /// `monty.pool.workers.live`.
  live(
    'monty.pool.workers.live',
    'up_down_counter',
    '{worker}',
    'Workers the pool is keeping alive: pooled, checked out, or being spawned.',
  ),

  /// `monty.pool.workers.idle`.
  idle(
    'monty.pool.workers.idle',
    'up_down_counter',
    '{worker}',
    'Workers immediately available for checkout.',
  ),

  /// `monty.pool.workers.suspended`.
  suspended(
    'monty.pool.workers.suspended',
    'up_down_counter',
    '{worker}',
    'Workers blocked waiting for the host to answer a suspension.',
  ),

  /// `monty.pool.checkout.wait`.
  checkout(
    'monty.pool.checkout.wait',
    'histogram',
    's',
    'Time spent acquiring a worker for a checkout.',
  ),

  /// `monty.pool.worker.terminated`.
  terminated(
    'monty.pool.worker.terminated',
    'counter',
    '{worker}',
    'Workers discarded by the pool, by reason.',
  ),

  /// `monty.pool.session.duration`.
  session(
    'monty.pool.session.duration',
    'histogram',
    's',
    'Lifetime of a checked-out session.',
  ),

  /// `monty.run.duration`.
  run(
    'monty.run.duration',
    'histogram',
    's',
    'Wall time of one feed, including time spent waiting on the host.',
  ),

  /// `monty.run.execution_time`.
  execution(
    'monty.run.execution_time',
    'histogram',
    's',
    'Sandbox execution time of one feed, excluding host round-trips.',
  ),

  /// `monty.turn.duration`.
  turn(
    'monty.turn.duration',
    'histogram',
    's',
    'Wall time of one non-execution turn, by kind.',
  ),

  /// `monty.run.suspensions`.
  suspensions(
    'monty.run.suspensions',
    'counter',
    '{suspension}',
    'Suspensions the sandbox raised for the host to answer, by kind.',
  ),

  /// `monty.ext.call.duration`.
  call(
    'monty.ext.call.duration',
    'histogram',
    's',
    'Time the host took to answer a suspension, by kind.',
  ),

  /// `monty.snapshot.bytes`.
  snapshot(
    'monty.snapshot.bytes',
    'histogram',
    'By',
    'Size of a session dump.',
  ),

  /// `monty.print.bytes`.
  print(
    'monty.print.bytes',
    'counter',
    'By',
    'Bytes the sandbox printed, by stream.',
  ),

  /// `monty.wire.frame.bytes`.
  frame(
    'monty.wire.frame.bytes',
    'histogram',
    'By',
    'Size of one protocol frame, by direction.',
  );

  const TelemetryMetrics(this.name, this.kind, this.unit, this.description);

  /// Dotted upstream instrument name.
  final String name;

  /// SDK instrument kind.
  final String kind;

  /// UCUM unit.
  final String unit;

  /// Verbatim upstream instrument description.
  final String description;

  /// Delivers a raw measurement with the bridge's explicit empty context.
  void record(num value, [Map<String, Object> attributes = const {}]) =>
      telemetryBridge?.recordMetric(
        name,
        kind,
        unit,
        description,
        value,
        attributes,
      );

  /// Avoids allocating attributes when no adapter is installed.
  void attribute(num value, String key, String label) {
    if (telemetryBridge == null) return;
    record(value, {key: label});
  }

  /// Pool timings do not allocate attributes without instrumentation.
  void duration(Stopwatch clock, String outcome) {
    if (telemetryBridge == null) return;
    elapsed(clock, {'outcome': outcome});
  }

  /// Stopwatch seconds, preserving a floating-point measurement.
  void elapsed(Stopwatch clock, Map<String, Object> attributes) => record(
    clock.elapsedMicroseconds / Duration.microsecondsPerSecond,
    attributes,
  );
}

final _unrecordedWorkers = _WorkerCounts();

final class _WorkerCounts {
  int live = 0;
  int idle = 0;
}

/// Seeds the isolate's existing workers once, after installing the bridge.
/// Counts span all pools without retaining pools or replaying past lifecycles.
void seedWorkerGauges() =>
    workerDelta(_unrecordedWorkers.live, _unrecordedWorkers.idle);

/// Worker changes shared by every pool path. Zero deltas are not samples.
void workerDelta(int live, int idle) {
  if (telemetryBridge == null) {
    _unrecordedWorkers.live += live;
    _unrecordedWorkers.idle += idle;

    return;
  }
  if (live != 0) TelemetryMetrics.live.record(live);
  if (idle != 0) TelemetryMetrics.idle.record(idle);
}

/// Checkout lifetime, allocated only with an installed adapter.
final class SessionMetrics {
  final _clock = Stopwatch()..start();
  bool _finished = false;

  /// Finishes at most once, even when release races a kill.
  void finish(String outcome) {
    if (_finished) return;
    _finished = true;
    TelemetryMetrics.session.elapsed(_clock, {'outcome': outcome});
  }
}
