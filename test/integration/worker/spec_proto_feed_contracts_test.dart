// Eager input binding, type-check rejection and restored interpreter limits.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

void _returnCheck(String clock) {
  for (final code in ['42', 'raise ValueError("original")']) {
    test('$clock checkpoint replaces $code', () async {
      final session = await protoRealSession(
        limits: ResourceLimits(
          maxMemory: 64000000,
          maxFeedDuration: clock == 'feed' ? Duration.zero : null,
          maxTurnDuration: clock == 'turn' ? Duration.zero : null,
        ),
      );
      await expectLater(
        session.feedRun(code),
        throwsA(
          isA<MontyRuntimeError>()
              .having((e) => e.exception.excType, 'type', 'TimeoutError')
              .having(
                (e) => e.exception.message,
                'message',
                matches(
                  '^$clock time limit exceeded: '
                  r'[0-9]+(?:\.[0-9]+)?(?:ns|µs|ms|s) > 0ns$',
                ),
              ),
        ),
      );
    });
  }
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  _returnCheck('feed');
  _returnCheck('turn');
  test(
    'every input is bound '
    'before the first statement raises',
    () async {
      final session = await protoRealSession();
      expect(await session.feedRun('a = 1\n0'), const MontyInt(0));
      await expectLater(
        session.feedRun(
          'raise ValueError("first statement")',
          inputs: {
            'a': const MontyInt(7),
            'b': const MontyString('unused'),
            'c': const MontyList([MontyInt(9)]),
          },
        ),
        throwsA(protoRuntime('ValueError', 'first statement')),
      );
      expect((await session.feedRun('(a, b, c)')).dartValue, [
        7,
        'unused',
        [9],
      ]);
    },
  );

  test(
    'typing rejection executes no statements '
    'and session survives',
    () async {
      final session = await protoBoundedSession(typeCheck: true);
      expect(await session.feedRun('marker = 7\nmarker'), const MontyInt(7));
      final printed = <String>[];
      await expectLater(
        session.feedRun(
          'marker = 99\nprint("executed")\nbad: int = "wrong"',
          printCallback: (_, text) => printed.add(text),
        ),
        throwsA(
          isA<MontyTypingError>().having(
            (e) => e.toString(),
            'diagnostic',
            contains('invalid-assignment'),
          ),
        ),
      );
      expect(printed, isEmpty);
      expect(
        await session.feedRun('marker', skipTypeCheck: true),
        const MontyInt(7),
      );
      await expectLater(
        session.feedRun('raise ValueError("ordinary")'),
        throwsA(protoRuntime('ValueError', 'ordinary')),
      );
      expect(await session.feedRun('6 * 7'), const MontyInt(42));
    },
  );

  test(
    'restore keeps dumped recursion and memory limits',
    () async {
      final source = await protoRealSession(
        limits: const ResourceLimits(
          maxMemory: 2000000,
          maxRecursionDepth: 3,
          gcInterval: 1,
        ),
      );
      final dump = await source.dump();
      final restored = await protoRealSession(
        limits: const ResourceLimits(
          maxMemory: 64000000,
          maxRecursionDepth: 100,
          gcInterval: 100000,
        ),
      );
      await restored.loadSession(dump);
      expect(
        await restored.feedRun(
          'def descend(n):\n    try:\n        return descend(n + 1)\n'
          '    except RecursionError:\n        return n\ndescend(1)',
        ),
        const MontyInt(3),
      );
      await expectLater(
        restored.feedRun('x = "a" * 10000000'),
        throwsA(
          isA<MontyRuntimeError>()
              .having((e) => e.exception.excType, 'type', 'MemoryError')
              .having(
                (e) => e.exception.message,
                'dumped cap',
                matches(
                  r'^memory limit exceeded: [0-9]+ bytes > 2000000 bytes$',
                ),
              ),
        ),
      );
    },
  );
}
