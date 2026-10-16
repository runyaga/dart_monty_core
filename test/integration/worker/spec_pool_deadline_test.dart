// Native deadline termination bypasses fatalExitGrace. The print rendezvous
// proves a real subprocess is in its turn before the test fires the deadline.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_pool_support.dart';
import '_worker_harness.dart';

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'REQ-pool-and-lifetimes-77: deadline kills before any native exit grace',
    () async {
      final channel = await ProcessChannel.spawn(await realWorker());
      final pool = await startMonty(
        const PoolOptions(
          maxProcesses: 1,
          requestTimeout: Duration(seconds: 5),
        ),
        open: () => PendingSpawn((_) async => channel),
      );
      addTearDown(pool.close);
      final session = await pool.checkout();
      addTearDown(session.close);
      final entered = Completer<void>();
      final printGate = Completer<void>();
      addTearDown(() {
        if (!printGate.isCompleted) printGate.complete();
      });
      final timers = PoolTimers();
      await timers.run(() async {
        final failed = expectLater(
          session.feedRun(
            'print("ready", flush=True)\nwhile True: pass',
            printCallback: (_, _) {
              entered.complete();

              return printGate.future;
            },
          ),
          throwsA(
            isA<MontyCrashedError>().having(
              (e) => e.timedOut,
              'timedOut',
              isTrue,
            ),
          ),
        );
        await entered.future;
        expect(timers.active, [const Duration(seconds: 5)]);
        timers.fire();
        expect(channel.isAlive, isFalse);
        expect(pool.liveWorkers, 0);
        expect(timers.active, isEmpty);
        await failed;
        printGate.complete();
      });
      await session.close();
      await channel.exitCode;
    },
  );
}
