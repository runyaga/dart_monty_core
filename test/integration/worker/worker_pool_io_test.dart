// The native channel factory and WorkerPool against the real worker
// executable (tool/build_worker.sh, or the CI artefact).
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_monty_core/src/worker/channel_factory.dart';
import 'package:dart_monty_core/src/worker/monty.dart' show Monty;
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show MontyCrashedError, MontyCrashedErrorInternal;
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '../../unit/worker/_pool_oracle.g.dart';
import '_worker_harness.dart';

/// Upstream monty-proto 1.1.0's `PROTOCOL_VERSION`.
const _protocolVersion = 5;

/// The generator's missing executable (tool/generate_pool_oracle.py).
const _missingWorker = '/nonexistent/dart_monty_worker';

/// Upstream's text for a pool whose worker executable does not exist
/// (pydantic-monty 1.1.0 raises it as RuntimeError; core as
/// MontyCrashedError, D-042).
final String _spawnFailure = poolOracle['spawn_missing_worker']!.substring(
  'RuntimeError: '.length,
);

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
    // Upstream's `PoolError::Spawn` (lib.rs:255; worker.rs:205 puts the
    // path before the OS error), as MontyCrashedError (D-042).
    await expectLater(
      openChannel(workerLocation: _missingWorker).ready,
      throwsA(
        isA<MontyCrashedError>()
            .having(
              (e) => e.toString(),
              'message',
              _spawnFailure,
            )
            .having((e) => (e.timedOut, e.exitStatus), 'status', (
              false,
              null,
            )),
      ),
    );
  });

  test('Monty.start: a worker that cannot spawn is a MontyCrashedError', () {
    expect(
      Monty.start(workerLocation: _missingWorker),
      throwsA(
        isA<MontyCrashedError>().having(
          (e) => e.toString(),
          'message',
          _spawnFailure,
        ),
      ),
    );
  });

  test('a start cancelled at once kills its process when it arrives', () async {
    // The native factory's start, with the spawned process observable: the
    // test waits for that process to exit, not just for the cancel.
    final launch = await realWorker();
    final spawned = Completer<ProcessChannel>();
    final handle = PendingSpawn((_) async {
      final channel = await ProcessChannel.spawn(launch);
      spawned.complete(channel);

      return channel;
    })..cancel();
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
    final channel = await spawned.future;
    await channel.exitCode.timeout(const Duration(seconds: 5));
    expect(channel.isAlive, isFalse);
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
    testOn: '!windows',
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
