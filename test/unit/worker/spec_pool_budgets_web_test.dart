// Run unchanged on dart2js and dart2wasm against the committed worker assets.
@TestOn('browser')
@Tags(['worker'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:test/test.dart';

Future<void> _budget(
  ResourceLimits limits,
  String code,
  String type,
  Pattern message,
) async {
  await Monty.withPool(
    (pool) => pool.withSession((session) async {
      await expectLater(
        session.feedRun(code),
        throwsA(
          isA<MontyRuntimeError>()
              .having((e) => e.exception.excType, 'type', type)
              .having((e) => e.exception.message, 'message', matches(message)),
        ),
      );
    }, limits: limits),
    maxProcesses: 1,
    feedDurationLimitGrace: null,
    turnDurationLimitGrace: null,
  );
}

void main() {
  for (final (kind, limits, code, type, message) in [
    (
      'memory',
      const ResourceLimits(maxMemory: 16 * 1024 * 1024),
      'x = []\nwhile True:\n    x.append("a" * 100000)',
      'MemoryError',
      r'^memory limit exceeded: \d+ bytes > 16777216 bytes$',
    ),
    (
      'feed',
      const ResourceLimits(maxFeedDuration: Duration(milliseconds: 20)),
      'while True: pass',
      'TimeoutError',
      r'^feed time limit exceeded: .+ > 20ms$',
    ),
    (
      'turn',
      const ResourceLimits(maxTurnDuration: Duration(milliseconds: 20)),
      'while True: pass',
      'TimeoutError',
      r'^turn time limit exceeded: .+ > 20ms$',
    ),
    (
      'recursion',
      const ResourceLimits(maxRecursionDepth: 4),
      'def f():\n    return f()\nf()',
      'RecursionError',
      r'^maximum recursion depth exceeded$',
    ),
    (
      'sleep',
      const ResourceLimits(maxTotalSleep: Duration.zero),
      'import time\ntime.sleep(1)',
      'TimeoutError',
      r'^sleep limit exceeded: 1s > 0ns$',
    ),
  ]) {
    test(
      'REQ-budgets-and-limits-78: $kind budget has the shared backend outcome',
      () => _budget(limits, code, type, message),
    );
  }
  test(
    'REQ-budgets-and-limits-78: configured suspension budget aborts the '
    'second host call',
    () async {
      var calls = 0;
      await Monty.withPool(
        (pool) => pool.withSession((session) async {
          await expectLater(
            session.feedRun(
              'f(); f()',
              externalLookup: {
                'f': MontyHostFunction('f', (_, _) {
                  calls++;

                  return const MontyNone();
                }),
              },
            ),
            throwsA(
              isA<MontyRuntimeError>()
                  .having(
                    (e) => e.exception.excType,
                    'type',
                    'RuntimeError',
                  )
                  .having(
                    (e) => e.exception.message,
                    'message',
                    'suspension limit 1 exceeded',
                  ),
            ),
          );
        }, limits: const ResourceLimits(maxSuspensions: 1)),
        maxProcesses: 1,
        feedDurationLimitGrace: null,
        turnDurationLimitGrace: null,
      );
      expect(calls, 1);
    },
  );
  test(
    'REQ-budgets-and-limits-83: timeout bounds buffered print followed by '
    'endless execution',
    () async {
      final pool = await Monty.start(
        maxProcesses: 1,
        requestTimeout: const Duration(seconds: 1),
      );
      addTearDown(pool.close);
      final session = await pool.checkout(
        printFlushInterval: const Duration(days: 1),
      );
      addTearDown(session.close);
      final prints = CollectString();
      await expectLater(
        session.feedRun(
          'print("buffered", end="")\nwhile True: pass',
          printCallback: prints.call,
        ),
        throwsA(
          isA<MontyCrashedError>()
              .having((e) => e.timedOut, 'timedOut', isTrue)
              .having((e) => e.exitStatus, 'exitStatus', isNull),
        ),
      );
      expect(pool.liveWorkers, 0);
      await expectLater(session.feedRun('1'), throwsStateError);
    },
  );
}
