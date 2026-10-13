// A program that closes a session during a turn stuck in a print callback,
// under a one-hour requestTimeout, then closes the pool and returns from
// main. The test that runs it checks that it exits promptly: nothing the
// abandoned turn left behind (a deadline timer, say) may keep it alive.
//
// usage: dart close_exit_probe.dart <worker executable>
//
// DCM: this is a spawned entry point, not a test.
// ignore_for_file: prefer-correct-test-file-name

import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/dart_monty_core.dart' show MontyNone;
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';

Future<void> main(List<String> args) async {
  final pool = await MontyPool.start(
    options: PoolOptions(
      maxProcesses: 1,
      requestTimeout: const Duration(hours: 1),
      workerLocation: args.firstOrNull,
    ),
  );
  final session = await pool.checkout(
    options: const SessionConfig(maxMemoryBytes: 64 * 1024 * 1024),
  );
  final entered = Completer<void>();
  // Through catchError, not a catch clause: MontyCrashedError is an Error.
  final settled = session
      .feedRun(
        "print('x')",
        printCallback: (stream, text) {
          entered.complete();

          // Never completes.
          return Completer<void>().future;
        },
      )
      .catchError((Object _) => const MontyNone());
  await entered.future;
  await session.close();
  await settled;
  await pool.close();
  stdout.writeln('closed');
}
