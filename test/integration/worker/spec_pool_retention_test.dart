// A child VM forces collections while only a snapshot or a pending operation
// owns a session. WeakReference observes reachability without private state.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:test/test.dart';
import 'package:vm_service/vm_service_io.dart';

import '../../_accessors.dart';
import '_worker_harness.dart';

typedef _Retained = (WeakReference<MontySession>, Future<void> Function());

Future<_Retained> _snapshot(Monty pool) async {
  final session = await pool.checkout();
  final snapshot = await session.feedStart('f()') as FunctionSnapshot;

  return (
    WeakReference(session),
    () async {
      final done =
          await snapshot.resume(const ExternalReturnValue(MontyInt(8)))
              as MontyComplete;
      if (done.output != const MontyInt(8)) {
        throw StateError('wrong snapshot output');
      }
    },
  );
}

Future<_Retained> _running(Monty pool, bool callback) async {
  final session = await pool.checkout();
  final entered = Completer<void>();
  final release = Completer<void>();
  final run = callback
      ? session.feedRun(
          'f()',
          externalLookup: {
            'f': MontyHostFunction('f', (_, _) async {
              entered.complete();
              await release.future;

              return const MontyInt(8);
            }),
          },
        )
      : session.feedRun(
          'print("ready", flush=True)\n8',
          printCallback: (_, _) {
            entered.complete();

            return release.future;
          },
        );
  await entered.future;

  return (
    WeakReference(session),
    () async {
      release.complete();
      if (await run != const MontyInt(8)) {
        throw StateError('wrong drive output');
      }
    },
  );
}

Future<void> _probe(String location, String mode) async {
  final uri = (await Service.getInfo()).serverWebSocketUri;
  if (uri == null) throw StateError('VM service must be enabled');
  final isolate = Service.getIsolateId(Isolate.current);
  if (isolate == null) throw StateError('no isolate id');
  final service = await vmServiceConnectUri(uri.toString());
  final pool = await Monty.start(maxProcesses: 1, workerLocation: location);
  try {
    if (mode == 'finalizer') {
      await _drop(pool);
      final channel = onlyItem(ProcessChannel.live);
      for (var i = 0; i < 50 && pool.liveWorkers != 0; i++) {
        await service.getAllocationProfile(isolate, gc: true);
        await pumpEventQueue();
      }
      if (pool.liveWorkers != 0) {
        throw StateError('finalizer did not free slot');
      }
      final code = await channel.exitCode.timeout(const Duration(seconds: 5));
      if (code == 0 || channel.isAlive) {
        throw StateError('worker was not killed');
      }
      stdout.writeln('finalized and killed');

      return;
    }
    for (final kind in ['snapshot', 'turn', 'callback']) {
      final (reference, finish) = kind == 'snapshot'
          ? await _snapshot(pool)
          : await _running(pool, kind == 'callback');
      for (var collection = 0; collection < 3; collection++) {
        await service.getAllocationProfile(isolate, gc: true);
        await pumpEventQueue();
      }
      final session = reference.target;
      if (session == null) throw StateError('$kind lost its session');
      try {
        await finish();
      } finally {
        await session.close();
      }
      stdout.writeln('retained $kind');
    }
  } finally {
    await pool.close();
    await service.dispose();
  }
}

Future<void> main([List<String> args = const []]) async {
  if (args case ['probe', final location, final mode]) {
    await _probe(location, mode);

    return;
  }
  test(
    'REQ-pool-and-lifetimes-21: finalization kills the worker '
    'and frees capacity',
    () => _child('finalizer', ['finalized and killed']),
  );
  test(
    'REQ-pool-and-lifetimes-23: snapshots and drives retain sessions across GC',
    () => _child('retention', [
      'retained snapshot',
      'retained turn',
      'retained callback',
    ]),
  );
}

Future<void> _drop(Monty pool) async {
  final session = await pool.checkout();
  if (await session.feedRun('8') != const MontyInt(8)) {
    throw StateError('wrong output before dropping session');
  }
}

Future<void> _child(String mode, List<String> expected) async {
  final location = await realWorker() as WorkerExecutable;
  final child = await Process.run(Platform.resolvedExecutable, [
    '--enable-vm-service=0',
    'test/integration/worker/spec_pool_retention_test.dart',
    'probe',
    location.path,
    mode,
  ]);
  expect(child.exitCode, 0, reason: '${child.stderr}');
  expect(
    '${child.stdout}'
        .split('\n')
        .where(
          (line) =>
              line.startsWith('retained ') || line.startsWith('finalized '),
        ),
    expected,
  );
}
