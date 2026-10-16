// Real worker replacement of oversized outbound events. Large values stay in
// the worker: Dart receives only the small replacement RuntimeError.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

const int _cap = 256 * 1024 * 1024;

Matcher _oversized(String kind) => isA<MontyRuntimeError>()
    .having((e) => e.exception.excType, 'type', 'RuntimeError')
    .having(
      (e) => e.exception.message,
      'message',
      matches(
        '^$kind frame of [0-9]+ bytes exceeds the maximum of $_cap bytes\$',
      ),
    )
    .having(
      (e) => int.tryParse(
        e.exception.message?.split(' ').elementAtOrNull(3) ?? '',
      ),
      'encoded length',
      greaterThan(_cap),
    );

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'oversized completion is replaced and session survives',
    () async {
      final session = await protoRealSession(
        limits: const ResourceLimits(maxMemory: 1536 * 1024 * 1024),
      );
      await expectLater(
        session.feedRun('"x" * $_cap'),
        throwsA(_oversized('result')),
      );
      expect(await session.feedRun('42'), const MontyInt(42));
    },
  );
  test(
    'oversized dump keeps the idle session usable',
    () async {
      final session = await protoRealSession(
        limits: const ResourceLimits(maxMemory: 1536 * 1024 * 1024),
      );
      expect(await session.feedRun('x = "a" * $_cap\n42'), const MontyInt(42));
      await expectLater(session.dump(), throwsA(_oversized('result')));
      expect(await session.feedRun('len(x)'), const MontyInt(_cap));
    },
  );
  test(
    'oversized error is replaced and session survives',
    () async {
      final session = await protoRealSession(
        limits: const ResourceLimits(maxMemory: 1536 * 1024 * 1024),
      );
      await expectLater(
        session.feedRun('raise ValueError("x" * $_cap)'),
        throwsA(_oversized('result')),
      );
      expect(await session.feedRun('42'), const MontyInt(42));
    },
  );
  for (final os in [false, true]) {
    test(
      'oversized ${os ? 'OS' : 'function'} call '
      'never suspends',
      () async {
        final session = await protoRealSession(
          limits: const ResourceLimits(maxMemory: 1536 * 1024 * 1024),
        );
        var calls = 0;
        MontyValue answer() {
          calls++;

          return const MontyNone();
        }

        final code = os
            ? 'import os\nos.getenv("x" * $_cap)'
            : 'f("x" * $_cap)';
        await expectLater(
          session.feedRun(
            code,
            externalLookup: {'f': MontyHostFunction('f', (_, _) => answer())},
            os: (_, _, _) => answer(),
          ),
          throwsA(_oversized('argument')),
        );
        expect(calls, 0);
        expect(await session.feedRun('42'), const MontyInt(42));
      },
    );
  }
}
