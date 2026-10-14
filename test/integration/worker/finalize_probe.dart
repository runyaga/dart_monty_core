// A program that drops a session without closing it, forces full
// collections through its own VM service, and prints `finalized` once the
// session's finalizer has freed the worker's slot (q2), or `live` if it
// never does. It exits explicitly either way: a worker still checked out
// would otherwise hold the process open.
//
// usage: dart --enable-vm-service=0 finalize_probe.dart <worker executable>
//
// DCM: this is a spawned entry point, not a test.
// ignore_for_file: prefer-correct-test-file-name

import 'dart:developer';
import 'dart:io';
import 'dart:isolate';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/dart_monty_core.dart' show MontyInt;
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:vm_service/vm_service_io.dart';

Future<void> main(List<String> args) async {
  final pool = await MontyPool.start(
    options: PoolOptions(maxProcesses: 1, workerLocation: args.firstOrNull),
  );
  await _useAndDrop(pool);
  final uri = (await Service.getInfo()).serverWebSocketUri;
  if (uri == null) {
    stderr.writeln('no VM service: run with --enable-vm-service');
    exit(2);
  }
  final service = await vmServiceConnectUri(uri.toString());
  final isolate = Service.getIsolateId(Isolate.current) ?? '';
  for (var i = 0; i < 100 && pool.liveWorkers > 0; i++) {
    // A full collection; the finalizer then runs as a later event.
    await service.getAllocationProfile(isolate, gc: true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
  final freed = pool.liveWorkers == 0;
  stdout.writeln(freed ? 'finalized' : 'live');
  await service.dispose();
  await pool.close();
  exit(freed ? 0 : 1);
}

/// Checks a session out, feeds it, and returns without closing it: nothing
/// refers to it afterwards.
Future<void> _useAndDrop(MontyPool pool) async {
  final session = await pool.checkout(
    options: const SessionConfig(
      limits: ResourceLimits(maxMemory: 64 * 1024 * 1024),
    ),
  );
  final printed = StringBuffer();
  final value = await session.feedRun(
    '1 + 1',
    printCallback: (_, text) => printed.write(text),
  );
  if (value != const MontyInt(2)) throw StateError('unexpected $value');
}
