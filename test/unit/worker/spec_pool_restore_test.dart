// A committed restore consumes freshness even when its runtime error preserves
// the checkout (pool-and-lifetimes.md, restore failure paths).
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_pool_support.dart';

void main() {
  for (final snapshot in [false, true]) {
    test(
      'REQ-pool-and-lifetimes-70: runtime restore preserves used session '
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
        'REQ-pool-and-lifetimes-70: $name restore failure discards checkout '
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
