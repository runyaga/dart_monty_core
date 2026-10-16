// A committed restore consumes freshness even when its runtime error preserves
// the checkout (pool-and-lifetimes.md, restore failure paths).
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:test/test.dart';

import '_pool_protocol_support.dart';
import '_pool_support.dart';
import '_scripted_channel.dart';

Future<void> _restoredSleep(String mode) async {
  final timers = PoolTimers();
  await timers.run(() async {
    final cap = Duration(seconds: mode == 'system' ? 2 : 10);
    final (session, channel) = await poolB2Session(
      [
        answer([ok()]),
        answer([poolB2Sleep(50)]),
        answer([completeNone()]),
        answer([poolB2Sleep(0.001)]),
        poolB2Abort,
      ],
      config: SessionConfig(
        osPolicy: OsPolicy(
          sleep: mode,
          sleepSystemMax: mode == 'system' ? cap : null,
        ),
        limits: ResourceLimits(maxTotalSleep: cap),
      ),
    );
    await session.loadSession(Uint8List.fromList([1]));
    final running = session.feedRun('restored system sleep');
    await pumpEventQueue();
    expect(timers.active, [cap]);
    timers.fire();
    expect(await running, const MontyNone());
    await expectLater(
      session.feedStart('next sleep'),
      throwsA(
        runtimePool(
          'TimeoutError',
          'sleep limit exceeded: ${cap.inSeconds}.001s > ${cap.inSeconds}s',
        ),
      ),
    );
    expect(channel.kills, 0);
  });
}

void main() {
  for (final mode in ['system', 'call_host', 'zero']) {
    test(
      'restored waits and charges keep $mode checkout cap',
      () => _restoredSleep(mode),
    );
  }
  for (final snapshot in [false, true]) {
    test(
      'runtime restore preserves used session '
      '($snapshot)',
      () async {
        final channel = ScriptedChannel([
          configurePool,
          answer([raised('ValueError', 'invalid dump')]),
          answer([completeNone()]),
          resetPool,
        ]);
        final pool = await poolWith([channel]);
        final session = await pool.checkout();
        addTearDown(session.close);
        final bytes = Uint8List.fromList([1]);
        await expectLater(
          snapshot ? session.loadSnapshot(bytes) : session.loadSession(bytes),
          throwsA(runtimePool('ValueError', 'invalid dump')),
        );
        expect(channel.kills, 0);
        expect(pool.liveWorkers, 1);
        await expectLater(
          session.loadSession(Uint8List.fromList([2])),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'load_session / load_snapshot is only valid on a fresh session, '
                  'before any feed_run / feed_start / load_session / load_snapshot',
            ),
          ),
        );
        expect(channel.requests, hasLength(2));
        expect(await session.feedRun('None'), const MontyNone());
      },
    );
    for (final (name, event) in [
      (
        'typing',
        pb.ChildEvent(typingError: pb.TypingError(diagnostics: 'bad type')),
      ),
      ('protocol', completeNone()),
    ]) {
      test(
        '$name restore failure discards checkout '
        '($snapshot)',
        () async {
          final channel = ScriptedChannel([
            configurePool,
            answer([event]),
          ]);
          final pool = await poolWith([channel]);
          final session = await pool.checkout();
          final bytes = Uint8List.fromList([1]);
          await expectLater(
            snapshot ? session.loadSnapshot(bytes) : session.loadSession(bytes),
            throwsA(isA<MontyError>()),
          );
          expect(channel.kills, 1);
          expect(pool.liveWorkers, 0);
          await expectLater(session.feedRun('1'), finishedPool);
        },
      );
    }
  }
}
