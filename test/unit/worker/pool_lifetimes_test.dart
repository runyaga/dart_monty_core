// Closing pools and sessions while protocol or host work is in progress.
import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_pool_support.dart';
import '_scripted_channel.dart';

Future<void> _busyClose() async {
  final channel = HeldPoolChannel();
  final pool = await poolWith([channel]);
  final session = await pool.checkout();
  final failed = expectLater(
    session.feedRun('blocked'),
    throwsA(
      isA<MontyCrashedError>()
          .having((e) => e.timedOut, 'timedOut', isFalse)
          .having((e) => e.exitStatus, 'exitStatus', isNull),
    ),
  );
  await channel.entered.future;
  await session.close();
  expect(channel.reply.isCompleted, isFalse);
  expect(channel.kills, 1);
  expect(pool.liveWorkers, 0);
  await failed;
  await session.close();
  expect(channel.kills, 1);
  expect(pool.liveWorkers, 0);
  channel.reply.complete(completeNone());
}

Future<void> _osCallback() async {
  final timers = PoolTimers();
  await timers.run(() async {
    final channel = ScriptedChannel([
      configurePool,
      answer([poolOs()]),
      expecting(pb.ParentRequest_Kind.dump, [
        pb.ChildEvent(
          dumpResult: pb.DumpResult(state: [4, 5, 6]),
        ),
      ]),
      answer([completeNone()]),
      resetPool,
    ]);
    final pool = await poolWith(
      [channel],
      options: const PoolOptions(
        minProcesses: 0,
        maxProcesses: 1,
        requestTimeout: Duration(seconds: 2),
      ),
    );
    final session = await pool.checkout();
    addTearDown(session.close);
    final entered = Completer<void>();
    final release = Completer<MontyValue>();
    final run = session.feedRun(
      'read',
      os: (name, args, kwargs) async {
        expect(name, 'Path.read_text');
        expect(await session.dump(), [4, 5, 6]);
        entered.complete();

        return release.future;
      },
    );
    await entered.future;
    expect(timers.active, isEmpty, reason: 'no deadline runs in host code');
    release.complete(const MontyString('text'));
    expect(await run, const MontyNone());
    expect(channel.kills, 0);
  });
}

Future<void> _activeCallbackAfterClose() async {
  final channel = ScriptedChannel([
    configurePool,
    answer([poolCall()]),
    answer([completeNone()]),
  ]);
  final pool = await poolWith([channel]);
  final session = await pool.checkout();
  final entered = Completer<void>();
  final release = Completer<MontyValue>();
  final run = session.feedRun(
    'f()',
    externalLookup: {
      'f': MontyHostFunction('f', (_, _) {
        entered.complete();

        return release.future;
      }),
    },
  );
  await entered.future;
  await pool.close();
  expect(channel.kills, 0);
  release.complete(const MontyNone());
  expect(await run, const MontyNone());
  await session.close();
  expect(channel.kills, 1);
  expect(pool.liveWorkers, 0);
  expect(channel.requests.map((request) => request.whichKind()), [
    pb.ParentRequest_Kind.configure,
    pb.ParentRequest_Kind.feed,
    pb.ParentRequest_Kind.resumeCall,
  ]);
}

void main() {
  test('busy close releases once before transport finishes', _busyClose);
  test('OS callback awaits dump outside turn deadlines', _osCallback);
  test(
    'active turn and callback survive pool close',
    () async {
      final channel = HeldPoolChannel();
      final pool = await poolWith([channel]);
      final session = await pool.checkout();
      final run = session.feedRun('blocked');
      await channel.entered.future;
      await pool.close();
      expect(channel.kills, 0);
      expect(channel.reply.isCompleted, isFalse);
      channel.reply.complete(completeNone());
      expect(await run, const MontyNone());
      await session.close();
      expect(channel.kills, 1);
      expect(channel.requests, [
        pb.ParentRequest_Kind.configure,
        pb.ParentRequest_Kind.feed,
      ]);
      await _activeCallbackAfterClose();
    },
  );
  test(
    'recorded print failure wins over busy close',
    () async {
      final channel = ScriptedChannel([
        configurePool,
        hangAfter([
          printed([(pb.PrintStream.PRINT_STREAM_STDOUT, 'text')]),
        ]),
      ]);
      final pool = await poolWith([channel]);
      final session = await pool.checkout();
      final entered = Completer<void>();
      final failed = expectLater(
        session.feedRun(
          'print',
          printCallback: (_, _) {
            entered.complete();
            throw const ExternalException('ValueError', 'sink failed');
          },
        ),
        throwsA(runtimePool('ValueError', 'sink failed')),
      );
      await entered.future;
      await session.close();
      await failed;
      expect(channel.kills, 1);
      expect(pool.liveWorkers, 0);
    },
  );
}
