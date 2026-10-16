// Session closure and deadlines observed with explicit callback gates/timers.
import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_pool_b2_support.dart';
import '_spec_pool_support.dart';

Future<void> _closeCallback(bool closePool) async {
  final channel = ScriptedChannel([
    configurePool,
    answer([poolCall()]),
    if (!closePool) resetPool,
  ]);
  final pool = await poolWith([channel]);
  final session = await pool.checkout();
  final entered = Completer<void>();
  final release = Completer<MontyValue>();
  final failed = expectLater(
    session.feedRun(
      'f()',
      externalLookup: {
        'f': MontyHostFunction('f', (_, _) {
          entered.complete();

          return release.future;
        }),
      },
    ),
    finishedPool,
  );
  await entered.future;
  if (closePool) await pool.close();
  await session.close();
  await failed;
  expect(release.isCompleted, isFalse);
  expect(channel.kills, closePool ? 1 : 0);
  expect(channel.requests.map((r) => r.whichKind()), [
    pb.ParentRequest_Kind.configure,
    pb.ParentRequest_Kind.feed,
    if (!closePool) pb.ParentRequest_Kind.reset,
  ]);
  release.complete(const MontyNone());
}

Future<void> _printDeadline(Duration? request, bool turnFirst) async {
  final timers = PoolTimers();
  await timers.run(() async {
    final (session, channel) = await poolB2Session(
      [
        answer([
          printed([(pb.PrintStream.PRINT_STREAM_STDOUT, 'blocked')]),
          completeNone(),
        ]),
      ],
      config: SessionConfig(
        limits: ResourceLimits(
          maxFeedDuration: Duration(seconds: turnFirst ? 8 : 2),
          maxTurnDuration: Duration(seconds: turnFirst ? 2 : 8),
        ),
      ),
      options: PoolOptions(
        minProcesses: 0,
        maxProcesses: 1,
        requestTimeout: request,
      ),
    );
    final entered = Completer<void>();
    final release = Completer<void>();
    final failed = expectLater(
      session.feedRun(
        'print',
        printCallback: (_, text) {
          expect(text, 'blocked');
          entered.complete();

          return release.future;
        },
      ),
      throwsA(
        isA<MontyCrashedError>().having((e) => e.timedOut, 'timedOut', isTrue),
      ),
    );
    await entered.future;
    expect(timers.active, [
      if (request == const Duration(seconds: 1))
        const Duration(seconds: 1)
      else
        const Duration(seconds: 3),
    ]);
    timers.fire();
    await failed;
    expect(release.isCompleted, isFalse);
    expect(channel.kills, 1);
    await expectLater(session.feedRun('None'), finishedPool);
    release.complete();
  });
}

void main() {
  for (final closePool in [false, true]) {
    test(
      'REQ-MontySession-33: close during callback with pool closed=$closePool',
      () => _closeCallback(closePool),
    );
  }
  for (final snapshot in [false, true]) {
    test(
      'REQ-MontySession-41: oversized load consumes freshness ($snapshot)',
      () async {
        final (session, channel) = await poolB2Session([
          answer([completeNone()]),
        ], frameLimit: 64);
        final bytes = Uint8List(100);
        await expectLater(
          snapshot ? session.loadSnapshot(bytes) : session.loadSession(bytes),
          poolB2Oversized,
        );
        await expectLater(session.loadSession(Uint8List(1)), throwsStateError);
        await expectLater(session.loadSnapshot(Uint8List(1)), throwsStateError);
        expect(channel.requests, hasLength(1));
        expect(await session.feedRun('None'), const MontyNone());
      },
    );
  }
  for (final request in [
    null,
    const Duration(seconds: 1),
    const Duration(seconds: 20),
  ]) {
    for (final turnFirst in [false, true]) {
      test(
        'REQ-print-delivery-37: print stall uses earliest deadline '
        '(request=$request, turnFirst=$turnFirst)',
        () => _printDeadline(request, turnFirst),
      );
    }
  }
}
