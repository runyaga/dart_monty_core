// Collector storage is owned by Dart independently of the worker heap.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'collector cap can be smaller than worker heap',
    () async {
      final session = await protoRealSession();
      final collector = CollectStreams(maxBytes: 67);
      await expectLater(
        session.feedRun('print("abcd", end="")', printCallback: collector.call),
        throwsA(
          protoRuntime(
            'MemoryError',
            'memory limit exceeded: 68 bytes > 67 bytes',
          ),
        ),
      );
      expect(collector.output, isEmpty);
      expect(await session.feedRun('42'), const MontyInt(42));
    },
  );
  test(
    'retained text can exceed worker heap cap',
    () async {
      final session = await protoRealSession(
        limits: const ResourceLimits(maxMemory: 2000000),
      );
      final collector = CollectStreams(maxBytes: 4000000);
      expect(
        await session.feedRun(
          'for i in range(3000):\n    print("x" * 1000, end="")\n42',
          printCallback: collector.call,
        ),
        const MontyInt(42),
      );
      expect(collector.output.map((entry) => entry.$1).toSet(), {'stdout'});
      expect(collector.output.map((entry) => entry.$2).join(), 'x' * 3000000);
    },
  );
}
