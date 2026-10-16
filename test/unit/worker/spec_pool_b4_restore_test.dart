// Restored sleep waits and charges retain the checkout's own ceiling.
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:test/test.dart';

import '_scripted_channel.dart';
import '_spec_pool_b2_support.dart';
import '_spec_pool_support.dart';

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
      'REQ-os-calls-21: restored waits and charges keep $mode checkout cap',
      () => _restoredSleep(mode),
    );
  }
}
