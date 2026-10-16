// Resource contracts against the real worker executable.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

const int _memory = 64 * 1024 * 1024;
const _recursion =
    'def descend(n):\n'
    '    try:\n        return descend(n + 1)\n'
    '    except RecursionError:\n        return n\n'
    'descend(1)';

Matcher _timeout(String clock) => isA<MontyRuntimeError>()
    .having((e) => e.exception.excType, 'type', 'TimeoutError')
    .having(
      (e) => e.exception.message,
      'message',
      matches(
        '^$clock time limit exceeded: [0-9]+(?:\\.[0-9]+)?(?:ns|µs|ms|s) > 0ns\$',
      ),
    );

void _durationTests() {
  for (final clock in ['feed', 'turn']) {
    test(
      '$clock timeout is uncatchable',
      () async {
        final session = await protoRealSession(
          limits: ResourceLimits(
            maxMemory: _memory,
            maxFeedDuration: clock == 'feed' ? Duration.zero : null,
            maxTurnDuration: clock == 'turn' ? Duration.zero : null,
          ),
        );
        var handlerRuns = 0;
        await expectLater(
          session.feedRun(
            'try:\n    while True:\n        pass\n'
            'except BaseException:\n    f()\n42',
            externalLookup: {
              'f': MontyHostFunction('f', (_, _) {
                handlerRuns++;

                return const MontyNone();
              }),
            },
          ),
          throwsA(_timeout(clock)),
        );
        expect(handlerRuns, 0);
      },
    );
  }
  test(
    'feed limit wins when both clocks exceed zero',
    () async {
      final session = await protoRealSession(
        limits: const ResourceLimits(
          maxMemory: _memory,
          maxFeedDuration: Duration.zero,
          maxTurnDuration: Duration.zero,
        ),
      );
      await expectLater(
        session.feedRun('while True:\n    pass'),
        throwsA(_timeout('feed')),
      );
    },
  );
  for (final code in ['42', 'raise ValueError("original")']) {
    test(
      'return checkpoint replaces $code',
      () async {
        final session = await protoRealSession(
          limits: const ResourceLimits(
            maxMemory: _memory,
            maxTurnDuration: Duration.zero,
          ),
        );
        await expectLater(session.feedRun(code), throwsA(_timeout('turn')));
      },
    );
  }
}

void _allocationTest() {
  test(
    'failed allocation retains prior mutations',
    () async {
      final session = await protoRealSession(
        limits: const ResourceLimits(maxMemory: 2000000),
      );
      await expectLater(
        session.feedRun(
          'marker = []\nmarker.append(7)\nx = "a" * 100000000',
        ),
        throwsA(
          isA<MontyRuntimeError>().having(
            (e) => e.exception.excType,
            'type',
            'MemoryError',
          ),
        ),
      );
      expect(await session.feedRun('marker'), const MontyList([MontyInt(7)]));
    },
  );
}

void _memoryTests() {
  _allocationTest();
  test(
    'collector cap is enforced under a larger heap cap',
    () async {
      final session = await protoRealSession();
      final collector = CollectString(maxBytes: 3);
      await expectLater(
        session.feedRun('print("abcd", end="")', printCallback: collector.call),
        throwsA(
          protoRuntime(
            'MemoryError',
            'memory limit exceeded: 4 bytes > 3 bytes',
          ),
        ),
      );
      expect(collector.output, '');
      expect(await session.feedRun('42'), const MontyInt(42));
    },
  );
  test(
    'collected bytes can exceed the interpreter heap cap',
    () async {
      final session = await protoRealSession(
        limits: const ResourceLimits(maxMemory: 2000000),
      );
      final collector = CollectString(maxBytes: 3000000);
      expect(
        await session.feedRun(
          'for i in range(3000):\n    print("x" * 1000, end="")\n42',
          printCallback: collector.call,
        ),
        const MontyInt(42),
      );
      expect(collector.output, 'x' * 3000000);
    },
  );
  test(
    'memory error bypasses except',
    () async {
      final session = await protoRealSession(
        limits: const ResourceLimits(maxMemory: 2000000),
      );
      await expectLater(
        session.feedRun(
          'try:\n    x = []\n    while True:\n        x.append("a" * 10000)\n'
          'except BaseException:\n    pass\n42',
        ),
        throwsA(
          isA<MontyRuntimeError>()
              .having((e) => e.exception.excType, 'type', 'MemoryError')
              .having(
                (e) => e.exception.message,
                'message',
                matches(
                  r'^memory limit exceeded: [0-9]+ bytes > 2000000 bytes$',
                ),
              ),
        ),
      );
    },
  );
}

void _sleepTests() {
  for (final (label, policy) in [
    ('omitted', const OsPolicy()),
    ('system', const OsPolicy(sleep: 'system')),
  ]) {
    test(
      'system sleep cap ($label)',
      () async {
        final session = await protoRealSession(osPolicy: policy);
        final waits = <Duration>[];
        var osCalls = 0;
        final result = await runZoned(
          () => session.feedRun(
            'import time\nimport asyncio\ntime.sleep(30)\n'
            'await asyncio.sleep(30)\n42',
            os: (_, _, _) {
              osCalls++;

              return const MontyNone();
            },
          ),
          zoneSpecification: ZoneSpecification(
            createTimer: (self, parent, zone, duration, callback) {
              // Advance system sleep; leave deadlines alone.
              if (duration != const Duration(seconds: 10)) {
                return parent.createTimer(zone, duration, callback);
              }
              waits.add(duration);

              return parent.createTimer(zone, Duration.zero, callback);
            },
          ),
        );
        expect(result, const MontyInt(42));
        expect(waits, [
          const Duration(seconds: 10),
          const Duration(seconds: 10),
        ]);
        expect(osCalls, 0);
      },
    );
  }
  test(
    'zero sleep never suspends',
    () async {
      final session = await protoRealSession(
        limits: const ResourceLimits(maxMemory: _memory, maxSuspensions: 0),
        osPolicy: const OsPolicy(sleep: 'zero'),
      );
      final result = await session.feedStart(
        'import time\nimport asyncio\ntime.sleep(30)\n'
        'await asyncio.sleep(30)\n42',
      );
      expect((result as MontyComplete).output, const MontyInt(42));
    },
  );
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  _durationTests();
  _memoryTests();
  _sleepTests();
  for (final depth in [1, 7, 25]) {
    test(
      'call ${depth + 1} is catchably rejected',
      () async {
        final session = await protoRealSession(
          limits: ResourceLimits(maxMemory: _memory, maxRecursionDepth: depth),
        );
        expect(await session.feedRun(_recursion), MontyInt(depth));
      },
    );
  }
  test(
    'default call depth rejects call 1001',
    () async {
      final session = await protoRealSession();
      expect(await session.feedRun(_recursion), const MontyInt(1000));
    },
  );
  test(
    'independent reentry ceiling',
    () async {
      final counts = <int>[];
      for (final depth in [1000, 2000]) {
        final session = await protoRealSession(
          limits: ResourceLimits(maxMemory: _memory, maxRecursionDepth: depth),
        );
        final result =
            await session.feedRun(
                  'calls = []\nclass R:\n    def __repr__(self):\n'
                  '        calls.append(1)\n        return repr(self)\n'
                  'try:\n    repr(R())\nexcept RecursionError as e:\n'
                  '    result = (len(calls), str(e))\nresult',
                )
                as MontyTuple;
        expect(
          itemAt(result.items, 1),
          const MontyString('maximum recursion depth exceeded'),
        );
        final count = (firstItem(result.items) as MontyInt).value;
        expect(count, inExclusiveRange(1, 1000));
        counts.add(count);
      }
      expect(firstItem(counts), itemAt(counts, 1));
    },
  );
}
