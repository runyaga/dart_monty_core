// Outbound refusal and print-failure state contracts, with bounded frames.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:test/test.dart';

import '_pool_protocol_support.dart';
import '_pool_support.dart';
import '_scripted_channel.dart';

Future<void> _oversizedLoad(bool snapshot) async {
  final timers = PoolTimers();
  await timers.run(() async {
    final (session, channel) = await poolB2Session(
      [
        hangAfter([]),
      ],
      frameLimit: 64,
      config: const SessionConfig(
        limits: ResourceLimits(maxFeedDuration: Duration(seconds: 2)),
      ),
    );
    final bytes = Uint8List(100);
    await expectLater(
      snapshot ? session.loadSnapshot(bytes) : session.loadSession(bytes),
      poolB2Oversized,
    );
    expect(channel.requests, hasLength(1));
    final failed = expectLater(
      session.feedRun('1'),
      throwsA(
        isA<MontyCrashedError>().having((e) => e.timedOut, 'timedOut', isTrue),
      ),
    );
    await pumpEventQueue();
    expect(timers.active, [const Duration(seconds: 3)]);
    timers.fire();
    await failed;
    expect(channel.requests, hasLength(2));
  });
}

void main() {
  test(
    'first overflow suppresses deliveries and drains',
    () async {
      final collector = CollectString(maxBytes: 3);
      final (session, channel) = await poolB2Session([
        answer([
          printed([
            (pb.PrintStream.PRINT_STREAM_STDOUT, 'a'),
            (pb.PrintStream.PRINT_STREAM_STDERR, 'xxxx'),
          ]),
          printed([(pb.PrintStream.PRINT_STREAM_STDOUT, 'b')]),
          raised('ValueError', 'turn outcome'),
        ]),
        answer([completeNone()]),
      ]);
      await expectLater(
        session.feedRun('print', printCallback: collector.call),
        throwsA(
          runtimePool(
            'MemoryError',
            'memory limit exceeded: 5 bytes > 3 bytes',
          ),
        ),
      );
      expect(collector.output, 'a');
      expect(await session.feedRun('None'), const MontyNone());
      expect(channel.requests, hasLength(3));
    },
  );
  test(
    'oversized feedStart inputs send nothing and '
    'permit retry',
    () async {
      final (session, channel) = await poolB2Session([
        answer([completeNone()]),
      ], frameLimit: 64);
      await expectLater(
        session.feedStart('x', inputs: {'x': MontyString('x' * 100)}),
        poolB2Oversized,
      );
      expect(channel.requests, hasLength(1));
      final done = await session.feedStart('None') as MontyComplete;
      expect(done.output, const MontyNone());
      expect(channel.requests, hasLength(2));
    },
  );
  test(
    'oversized OS answer stays pending until close',
    () async {
      final channel = ScriptedChannel([
        configurePool,
        answer([poolOs()]),
        resetPool,
        configurePool,
        answer([completeNone()]),
        resetPool,
      ], frameLimit: 64);
      final pool = await poolWith([channel]);
      final session = await pool.checkout();
      await expectLater(
        session.feedRun('read()', os: (_, _, _) => MontyString('x' * 100)),
        poolB2Oversized,
      );
      await expectLater(session.feedRun('1'), poolB2Pending);
      await expectLater(session.feedStart('2'), poolB2Pending);
      expect(channel.requests, hasLength(2));
      await session.close();
      expect(pool.idleWorkers, 1);
      final next = await pool.checkout(scriptName: 'next.py');
      expect(await next.feedRun('None'), const MontyNone());
      await next.close();
      expect(channel.kills, 0);
    },
  );
  for (final snapshot in [false, true]) {
    test(
      'oversized load restores duration budget ($snapshot)',
      () => _oversizedLoad(snapshot),
    );
    test(
      'oversized load leaves feeds usable ($snapshot)',
      () async {
        final (session, channel) = await poolB2Session([
          answer([completeNone()]),
        ], frameLimit: 64);
        final bytes = Uint8List(100);
        await expectLater(
          snapshot ? session.loadSnapshot(bytes) : session.loadSession(bytes),
          poolB2Oversized,
        );
        expect(channel.requests, hasLength(1));
        expect(await session.feedRun('None'), const MontyNone());
      },
    );
    test(
      'oversized restored announcement consumes '
      'freshness ($snapshot)',
      () async {
        const message =
            'protocol violation: argument frame of 268435457 bytes exceeds '
            'the maximum of 268435456 bytes';
        final (session, channel) = await poolB2Session([
          answer([raised('RuntimeError', message)]),
          answer([completeNone()]),
        ]);
        final bytes = Uint8List.fromList([1]);
        await expectLater(
          snapshot ? session.loadSnapshot(bytes) : session.loadSession(bytes),
          throwsA(runtimePool('RuntimeError', message)),
        );
        await expectLater(session.loadSession(bytes), throwsStateError);
        await expectLater(session.loadSnapshot(bytes), throwsStateError);
        expect(channel.requests, hasLength(2));
        expect(await session.feedRun('None'), const MontyNone());
      },
    );
  }
}
