import 'dart:async';

import 'package:dart_monty_core/src/worker/monty_session.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/telemetry.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../worker/_scripted_channel.dart';
import 'recording_adapter.dart';

void main() {
  final adapter = RecordingAdapter();
  setUpAll(() => instrumentTelemetry(adapter));
  setUp(adapter.clear);
  lifecycleCases(adapter);
  checkoutCases(adapter);
  failureLifecycleCases(adapter);
}

Future<WorkerPool> pool({
  PoolOptions options = const PoolOptions(),
  ScriptedChannel? channel,
}) => WorkerPool.start(
  options,
  () => PendingSpawn(
    (_) async =>
        channel ??
        ScriptedChannel([
          for (var i = 0; i < 10; i++) answer([ok()]),
        ]),
  ),
);

void lifecycleCases(RecordingAdapter adapter) {
  test('closed workers balance live and idle increments', () async {
    final subject = await pool();
    final lease = await subject.acquire();
    await lease.release();
    await subject.close();
    await subject.close();
    expect(measurements(adapter, 'pool.workers.live').map((m) => m.value), [
      1,
      -1,
    ]);
    expect(measurements(adapter, 'pool.workers.idle').map((m) => m.value), [
      1,
      -1,
      1,
      -1,
    ]);
    expectReason(adapter, 'closed');
    expect(
      measurements(adapter, 'pool.session.duration').map((m) => m.attributes),
      [
        {'outcome': 'ok'},
      ],
    );
  });
  test('recycled worker at checkout limit', () async {
    final subject = await pool(
      options: const PoolOptions(maxCheckoutsPerWorker: 1),
    );
    final lease = await subject.acquire();
    await lease.release();
    await subject.close();
    expectReason(adapter, 'recycled');
  });
  test('died_idle worker removed at next checkout', () async {
    final channel = ScriptedChannel([
      answer([ok()]),
    ]);
    final subject = await pool(channel: channel);
    channel.kill();
    final lease = await subject.acquire();
    expectReason(adapter, 'died_idle');
    lease.kill();
    await subject.close();
  });
  test('discarded worker on failed reset', () async {
    final subject = await pool(
      channel: ScriptedChannel([
        answer([pb.ChildEvent(error: pb.Error())]),
      ]),
    );
    final lease = await subject.acquire();
    await expectLater(lease.release(), throwsStateError);
    await subject.close();
    expectReason(adapter, 'discarded');
    expect(
      measurements(adapter, 'pool.session.duration').map((m) => m.attributes),
      [
        {'outcome': 'error'},
      ],
    );
  });
  test('abandoned lease is counted once', () async {
    final subject = await pool();
    final lease = await subject.acquire();
    lease
      ..kill()
      ..kill();
    await lease.release();
    await subject.close();
    expectReason(adapter, 'abandoned');
    expect(
      measurements(adapter, 'pool.session.duration').map((m) => m.attributes),
      [
        {'outcome': 'abandoned'},
      ],
    );
  });
  test(
    'single_use has no core transport: reusable channel remains pooled',
    () async {
      final subject = await pool();
      final acquire = subject.acquire;
      // Each checkout must run to verify that release allows worker reuse.
      final first = await acquire();
      final id = first.workerId;
      await first.release();
      // A fresh checkout is the behavior under test.
      final second = await acquire();
      expect(second.workerId, id);
      await second.release();
      expect(measurements(adapter, 'pool.worker.terminated'), isEmpty);
      await subject.close();
    },
  );
}

void expectReason(RecordingAdapter adapter, String reason) {
  expect(
    measurements(
      adapter,
      'pool.worker.terminated',
    ).map((m) => [m.value, m.attributes]),
    [
      [
        1,
        {'reason': reason},
      ],
    ],
  );
}

void checkoutCases(RecordingAdapter adapter) {
  test('spawn timeout is an error, not checkout exhaustion', () async {
    final subject = await WorkerPool.start(
      const PoolOptions(minProcesses: 0),
      () => PendingSpawn((_) async => throw TimeoutException('spawn failed')),
    );
    await expectLater(subject.acquire(), throwsA(isA<TimeoutException>()));
    await subject.close();
    expect(
      measurements(adapter, 'pool.checkout.wait').map((m) => m.attributes),
      [
        {'outcome': 'error'},
      ],
    );
  });

  test('checkout outcomes idle spawned waited exhausted and error', () async {
    final subject = await pool(
      options: const PoolOptions(
        minProcesses: 0,
        maxProcesses: 1,
        checkoutTimeout: Duration(milliseconds: 30),
      ),
    );
    final first = await subject.acquire();
    final waiting = subject.acquire();
    await first.release();
    final second = await waiting;
    await expectLater(subject.acquire(), throwsA(isA<TimeoutException>()));
    await second.release();
    final third = await subject.acquire();
    await third.release();
    await subject.close();
    await expectLater(subject.acquire(), throwsStateError);
    expect(
      measurements(adapter, 'pool.checkout.wait').map((m) => m.attributes),
      [
        {'outcome': 'spawned'},
        {'outcome': 'waited'},
        {'outcome': 'exhausted'},
        {'outcome': 'idle'},
        {'outcome': 'error'},
      ],
    );
  });
  test(
    'spawn failure returns reserved live count without a termination',
    () async {
      final subject = await WorkerPool.start(
        const PoolOptions(minProcesses: 0),
        () => PendingSpawn((_) async => throw StateError('spawn failed')),
      );
      await expectLater(subject.acquire(), throwsStateError);
      await subject.close();
      expect(measurements(adapter, 'pool.workers.live').map((m) => m.value), [
        1,
        -1,
      ]);
      expect(measurements(adapter, 'pool.worker.terminated'), isEmpty);
      expect(
        measurements(adapter, 'pool.checkout.wait').map((m) => m.attributes),
        [
          {'outcome': 'error'},
        ],
      );
    },
  );
}

void failureLifecycleCases(RecordingAdapter adapter) {
  test('release after pool close', () async {
    final subject = await pool();
    final lease = await subject.acquire();
    await subject.close();
    await lease.release();
    expectReason(adapter, 'closed');
    expect(
      measurements(adapter, 'pool.session.duration').map((m) => m.attributes),
      [
        {'outcome': 'ok'},
      ],
    );
  });
  test('protocol failure discards a checked-out worker', () async {
    final reply = ok();
    final subject = await pool(
      channel: ScriptedChannel([
        answer([reply]),
        answer([reply]),
      ]),
    );
    final lease = await subject.acquire();
    final session = await openPoolSession(
      lease,
      subject.options,
      const SessionConfig(),
    );
    await expectLater(session.feedRun('42'), throwsA(isA<Exception>()));
    await session.close();
    await subject.close();
    expectReason(adapter, 'discarded');
    expect(
      measurements(adapter, 'pool.session.duration').map((m) => m.attributes),
      [
        {'outcome': 'error'},
      ],
    );
  });
}
