// Feed/turn clocks and restore memory caps against the native worker.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

const int _memory = 64 * 1024 * 1024;

final Matcher _memoryError = isA<MontyRuntimeError>().having(
  (e) => e.exception.excType,
  'type',
  'MemoryError',
);

// Keep the host busy past the sandbox budget without a timer or sleep.
void _hostWork() {
  final clock = Stopwatch()..start();
  var spins = 0;
  while (clock.elapsedMilliseconds < 800) {
    // The worker is suspended or idle throughout this host-only work.
    spins++;
  }
  expect(spins, greaterThan(0));
}

void _excludedClocks() {
  test(
    'host, sleep and idle time are excluded',
    () async {
      final session = await protoRealSession(
        limits: const ResourceLimits(
          maxMemory: _memory,
          maxFeedDuration: Duration(milliseconds: 250),
          maxTurnDuration: Duration(milliseconds: 250),
        ),
      );
      expect(
        await session.feedRun(
          'f()\nimport time\ntime.sleep(0.6)\n42',
          externalLookup: {
            'f': MontyHostFunction('f', (_, _) {
              _hostWork();

              return const MontyNone();
            }),
          },
        ),
        const MontyInt(42),
      );
      _hostWork();
      expect(await session.feedRun('6 * 7'), const MontyInt(42));
    },
  );
  test(
    'internal task switches retain the turn clock',
    () async {
      final session = await protoRealSession(
        limits: const ResourceLimits(
          maxMemory: _memory,
          maxTurnDuration: Duration(milliseconds: 50),
        ),
        osPolicy: const OsPolicy(sleep: 'zero'),
      );
      await expectLater(
        session.feedRun(
          'import asyncio\nasync def part():\n'
          '    n = 0\n    for i in range(10000):\n        n += 1\n'
          '    await asyncio.sleep(0)\n    return n\n'
          'await asyncio.gather(*[part() for _ in range(2000)])',
        ),
        throwsA(
          isA<MontyRuntimeError>()
              .having((e) => e.exception.excType, 'type', 'TimeoutError')
              .having(
                (e) => e.exception.message,
                'message',
                matches(
                  r'^turn time limit exceeded: [0-9]+(?:\.[0-9]+)?(?:ms|s) > 50ms$',
                ),
              ),
        ),
      );
    },
  );
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  _excludedClocks();
  test(
    'omitted limits permit memory and execution',
    () async {
      final session = await protoRealSession(limits: const ResourceLimits());
      expect(
        await session.feedRun('x = "a" * 50000000\nlen(x)'),
        const MontyInt(50000000),
      );
      expect(
        await session.feedRun('sum(range(1000000))'),
        const MontyInt(499999500000),
      );
      final waits = <Duration>[];
      final result = await runZoned(
        () => session.feedRun(
          'import time\ntime.sleep(0.02)\ntime.sleep(0.02)\n42',
        ),
        zoneSpecification: ZoneSpecification(
          createTimer: (self, parent, zone, duration, callback) {
            if (duration != const Duration(milliseconds: 20)) {
              return parent.createTimer(zone, duration, callback);
            }
            waits.add(duration);

            return parent.createTimer(zone, Duration.zero, callback);
          },
        ),
      );
      expect(result, const MontyInt(42));
      expect(waits, [
        const Duration(milliseconds: 20),
        const Duration(milliseconds: 20),
      ]);
    },
  );
  test(
    'load uses checkout then dump cap',
    () async {
      final source = await protoRealSession();
      expect(
        await source.feedRun('x = "a" * 8000000\nlen(x)'),
        const MontyInt(8000000),
      );
      final dump = await source.dump();
      final small = await protoRealSession(
        limits: const ResourceLimits(maxMemory: 100000),
      );
      await expectLater(
        small.loadSession(dump),
        throwsA(
          _memoryError,
        ),
      );
      final large = await protoRealSession(
        limits: const ResourceLimits(maxMemory: 128 * 1024 * 1024),
      );
      await large.loadSession(dump);
      expect(await large.feedRun('len(x)'), const MontyInt(8000000));
      await expectLater(
        large.feedRun('y = "b" * 100000000'),
        throwsA(
          allOf(
            _memoryError,
            isA<MontyRuntimeError>().having(
              (e) => e.exception.message,
              'restored limit',
              matches(
                r'^memory limit exceeded: [0-9]+ bytes > 67108864 bytes$',
              ),
            ),
          ),
        ),
      );
    },
  );
}
