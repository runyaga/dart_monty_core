// The native channel factory and WorkerPool against the real worker
// executable (tool/build_worker.sh, or the CI artefact).
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty_core/src/worker/channel_factory.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_worker_harness.dart';

/// Upstream monty-proto 1.1.0's `PROTOCOL_VERSION`.
const _protocolVersion = 5;

/// Every worker's memory is bounded.
final _configure = pb.ParentRequest(
  configure: pb.Configure(
    scriptName: 'main.py',
    protocolVersion: _protocolVersion,
    limits: pb.ResourceLimits(maxMemoryBytes: Int64(64 * 1024 * 1024)),
  ),
);

void main() {
  expectNoWorkersLeftAfterEachTest();

  test('openChannel locates the worker and starts it', () async {
    final channel = await openChannel().ready;
    addTearDown(channel.close);
    expect(channel, isA<ProcessChannel>());
    expect((await channel.turn(_configure)).whichKind(), pb.ChildEvent_Kind.ok);
  });

  test('openChannel uses workerLocation as the executable', () async {
    final launch = await realWorker();
    final path = (launch as WorkerExecutable).path;
    final channel = await openChannel(workerLocation: path).ready;
    addTearDown(channel.close);
    expect((await channel.turn(_configure)).whichKind(), pb.ChildEvent_Kind.ok);
    await expectLater(
      openChannel(workerLocation: '/nonexistent/dart_monty_worker').ready,
      throwsA(isA<ProcessException>()),
    );
  });

  test('a start cancelled at once leaves no worker running', () async {
    final handle = openChannel()..cancel();
    await expectLater(
      handle.ready,
      throwsA(
        isA<MontyCrashedError>().having(
          (e) => e.cause,
          'cause',
          CrashCause.killed,
        ),
      ),
    );
    // The process that was already starting is killed as it arrives; the
    // tearDown fails the test if it is still running.
  });

  test(
    'an idle worker that closed its stdout is killed when discarded',
    () async {
      // Stdout closed, still running: the channel is no longer usable, but
      // the process lives on unless the pool stops it.
      const mute = WorkerExecutable(
        '/bin/sh',
        args: ['-c', 'exec 1>&-; exec /bin/sleep 30'],
      );
      final pool = await WorkerPool.start(
        const PoolOptions(maxProcesses: 1),
        () => PendingSpawn((_) => ProcessChannel.spawn(mute)),
      );
      addTearDown(pool.close);
      final first = onlyItem(ProcessChannel.live);
      while (first.isAlive) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final lease = await pool.acquire();
      addTearDown(lease.kill);
      await first.exitCode.timeout(const Duration(seconds: 5));
    },
  );

  test('defaultMaxProcesses is the processor count', () {
    expect(defaultMaxProcesses(), Platform.numberOfProcessors);
  });

  test('a pool of real workers: reuse after Reset, a kill frees the slot, '
      'close', () async {
    final pool = await WorkerPool.start(
      const PoolOptions(maxProcesses: 1),
    );
    addTearDown(pool.close);
    expect(ProcessChannel.live, hasLength(1));

    // Three checkouts on purpose, one after another: each is its own lease.
    // ignore: prefer-moving-to-variable
    final a = await pool.acquire();
    final first = a.channel as ProcessChannel;
    final pid = first.pid;
    await first.turn(_configure);
    await first.turn(pb.ParentRequest(feed: pb.Feed(code: 'x = 41')));
    await a.release();

    // The second checkout: the same worker, reset.
    // ignore: prefer-moving-to-variable
    final b = await pool.acquire();
    final second = b.channel as ProcessChannel;
    expect(second.pid, pid, reason: 'reused');
    await second.turn(_configure);
    final lookup = await second.turn(
      pb.ParentRequest(feed: pb.Feed(code: 'x')),
    );
    expect(
      lookup.whichKind(),
      pb.ChildEvent_Kind.nameLookup,
      reason: 'Reset cleared x, so the worker asks the host for it',
    );
    b.kill();
    expect(pool.liveWorkers, 0);

    // The third checkout: a new worker, since b's was killed.
    // ignore: prefer-moving-to-variable
    final c = await pool.acquire();
    final third = c.channel as ProcessChannel;
    expect(third.pid, isNot(pid));
    await third.turn(_configure);
    await c.release();
    await pool.close();
    expect(ProcessChannel.live, isEmpty);
  });
}
