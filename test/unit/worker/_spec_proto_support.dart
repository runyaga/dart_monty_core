// Shared fixtures for the protocol spec tests. Expected errors come from
// the spec contracts, not from invoking the encoder under test.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_real_worker_location_stub.dart'
    if (dart.library.io) '_real_worker_location_io.dart'
    as local_worker;
import '_scripted_channel.dart';

/// A configured session whose subsequent replies are supplied by the test.
Future<(MontySession, ScriptedChannel)> protoSession(
  List<Reply> replies, {
  ResourceLimits limits = const ResourceLimits(),
}) async {
  final channel = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    ...replies,
  ]);
  final pool = await startMonty(
    const PoolOptions(minProcesses: 0, maxProcesses: 1),
    open: () => PendingSpawn((_) async => channel),
  );
  addTearDown(pool.close);
  final session = await pool.checkoutWith(SessionConfig(limits: limits));
  addTearDown(session.close);

  return (session, channel);
}

/// A successful integer result.
pb.ChildEvent protoInt(int value) => complete([intNode(value)]);

/// A pending host function invocation.
pb.ChildEvent protoCall() => pb.ChildEvent(
  functionCall: pb.FunctionCall(
    functionName: 'f',
    callId: 1,
    values: pb.Arena(),
  ),
);

/// A dictionary whose value points back to the dictionary.
MontyDict protoCycle() {
  final entries = <(MontyValue, MontyValue)>[];
  final value = MontyDict(entries);
  entries.add((const MontyString('self'), value));

  return value;
}

/// An exact Python exception exposed through the runtime error family.
Matcher protoRuntime(String type, String message) => isA<MontyRuntimeError>()
    .having((e) => e.exception.excType, 'exception type', type)
    .having((e) => e.exception.message, 'exception message', message)
    .having((e) => e.toString(), 'rendered error', '$type: $message');

/// A malformed worker result must be blamed on the protocol.
Matcher protoCrash(String detail) => isA<MontyCrashedError>()
    .having(
      (e) => e.toString(),
      'message',
      'monty worker protocol error: $detail',
    )
    .having((e) => e.timedOut, 'timedOut', false)
    .having((e) => e.exitStatus, 'exitStatus', isNull);

/// A real worker session with bounded test resources and teardown.
Future<MontySession> protoRealSession({
  ResourceLimits limits = const ResourceLimits(maxMemory: 64 * 1024 * 1024),
  OsPolicy osPolicy = const OsPolicy(),
}) async {
  final pool = await Monty.start(
    maxProcesses: 1,
    requestTimeout: const Duration(seconds: 9),
    workerLocation: await local_worker.realWorkerLocation(),
  );
  addTearDown(pool.close);
  final session = await pool.checkout(limits: limits, osPolicy: osPolicy);
  addTearDown(session.close);

  return session;
}

/// Scripted session with configurable checkout and frame limit.
Future<(MontySession, ScriptedChannel)> protoConfiguredSession(
  List<Reply> replies, {
  SessionConfig config = const SessionConfig(scriptName: 'spec.py'),
  int frameLimit = 4096,
}) async {
  final channel = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    ...replies,
  ], frameLimit: frameLimit);
  final pool = await startMonty(
    const PoolOptions(minProcesses: 0, maxProcesses: 1),
    open: () => PendingSpawn((_) async => channel),
  );
  addTearDown(pool.close);
  final session = await pool.checkoutWith(config);
  addTearDown(session.close);

  return (session, channel);
}

/// Real session with explicit settings and bounded memory.
Future<MontySession> protoBoundedSession({
  Duration printFlushInterval = const Duration(days: 1),
  bool typeCheck = false,
  String? typeCheckStubs,
  ResourceLimits limits = const ResourceLimits(maxMemory: 64 * 1024 * 1024),
}) async {
  final pool = await Monty.start(maxProcesses: 1);
  addTearDown(pool.close);
  final session = await pool.checkoutWith(
    SessionConfig(
      scriptName: 'spec.py',
      printFlushInterval: printFlushInterval,
      typeCheck: typeCheck,
      typeCheckStubs: typeCheckStubs,
      limits: limits,
    ),
  );
  addTearDown(session.close);

  return session;
}
