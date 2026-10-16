// Native transport failures through the public session lifecycle. This file
// also serves as a subprocess fixture when passed a scenario argument.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/frame.dart' as wire;
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show CrashCause, MontyCrashedErrorInternal;
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

const _fatalText = 'cannot announce the suspension';
const _memoryText = 'the worker exceeded its memory limit and was terminated';
const _path = 'test/integration/worker/spec_channel_failures_test.dart';

Future<void> main([List<String> args = const []]) async {
  if (args.isNotEmpty) {
    await _serve(args.single);

    return;
  }
  for (final req in [
    'REQ-MontyCrashedError-25',
    'REQ-MontyRuntimeError-30',
    'REQ-ResourceLimits-46',
    'REQ-budgets-and-limits-75',
    'REQ-platforms-47',
  ]) {
    test('$req: FatalError wins over exit 65', () async {
      final (pool, session, channel) = await _session('fatal');
      await expectLater(
        session.feedRun('1'),
        throwsA(
          isA<MontyCrashedError>()
              .having((e) => e.cause, 'cause', CrashCause.fatal)
              .having((e) => e.detail, 'detail', _fatalText)
              .having((e) => e.exitStatus, 'exitStatus', 65),
        ),
      );
      expect(await channel.exitCode, 65);
      await _finished(pool, session, channel);
    });
  }
  for (final req in ['REQ-ResourceLimits-45', 'REQ-budgets-and-limits-74']) {
    test('$req: EOF with exit 65 reports the exact MemoryError', () async {
      final (pool, session, channel) = await _session('oom');
      await expectLater(
        session.feedRun('1'),
        throwsA(
          isA<MontyRuntimeError>()
              .having((e) => e.exception.excType, 'excType', 'MemoryError')
              .having((e) => e.exception.message, 'message', _memoryText)
              .having((e) => e.toString(), 'text', 'MemoryError: $_memoryText'),
        ),
      );
      expect(await channel.exitCode, 65);
      await _finished(pool, session, channel);
    });
  }
  for (final scenario in ['oversize', 'torn']) {
    test(
      'REQ-wire-limits-36: $scenario discards the worker and session',
      () async {
        final (pool, session, channel) = await _session(scenario);
        await expectLater(
          session.feedRun('1'),
          throwsA(
            isA<MontyCrashedError>()
                .having((e) => e.cause, 'cause', CrashCause.vanished)
                .having((e) => e.timedOut, 'timedOut', isFalse),
          ),
        );
        await _finished(pool, session, channel);
      },
    );
  }
}

Future<(Monty, MontySession, ProcessChannel)> _session(String scenario) async {
  final channel = await ProcessChannel.spawn(
    WorkerExecutable(
      Platform.resolvedExecutable,
      args: [File(_path).absolute.path, scenario],
    ),
  );
  addTearDown(channel.close);
  final pool = await startMonty(
    const PoolOptions(minProcesses: 0, maxProcesses: 1),
    open: () => PendingSpawn((_) async => channel),
  );
  addTearDown(pool.close);
  final session = await pool.checkout();
  addTearDown(session.close);

  return (pool, session, channel);
}

Future<void> _finished(
  Monty pool,
  MontySession session,
  ProcessChannel channel,
) async {
  expect(channel.isAlive, isFalse);
  expect(pool.liveWorkers, 0);
  expect(pool.idleWorkers, 0);
  await expectLater(session.feedRun('2'), throwsStateError);
}

Future<void> _serve(String scenario) async {
  final decoder = wire.FrameDecoder();
  await for (final chunk in stdin) {
    for (final body in decoder.add(chunk)) {
      final request = pb.ParentRequest.fromBuffer(body);
      if (request.whichKind() == pb.ParentRequest_Kind.configure) {
        await _write(wire.Frame.encode(pb.ChildEvent(ok: pb.Ok())));
      } else {
        await _fail(scenario);
      }
    }
  }
}

Future<void> _fail(String scenario) async {
  switch (scenario) {
    case 'fatal':
      await _write(
        wire.Frame.encode(
          pb.ChildEvent(fatalError: pb.FatalError(message: _fatalText)),
        ),
      );
      exit(65);
    case 'oom':
      exit(65);
    case 'oversize':
      // 268435457, one byte above the independent 256 MiB contract.
      await _write([1, 0, 0, 16]);
      exit(0);
    case 'torn':
      // Ten promised body bytes, only two delivered.
      await _write([10, 0, 0, 0, 0, 0]);
      exit(0);
    default:
      throw StateError('unknown fixture scenario: $scenario');
  }
}

Future<void> _write(List<int> bytes) async {
  stdout.add(bytes);
  await stdout.flush();
}
