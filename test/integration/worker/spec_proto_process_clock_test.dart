// Elapsed process time accumulates execution across feeds, excluding host work.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

MontyValue _hostWork(Duration duration) {
  final clock = Stopwatch()..start();
  var count = 0;
  while (clock.elapsed < duration) {
    count++;
  }
  expect(count, greaterThan(0));

  return const MontyNone();
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  test(
    'elapsed clock includes blocked print wall time',
    () async {
      final session = await protoRealSession(
        osPolicy: const OsPolicy(processTime: 'elapsed'),
      );
      var bytes = 0;
      // Eight MiB exceeds native read-ahead and pipe capacity. While the first
      // callback occupies the Dart thread, the worker blocks writing the rest;
      // The blocked interval is execution wall time with no worker CPU use.
      expect(
        await session.feedRun(
          'import time\nstart = time.process_time()\n'
          'print("x" * 8388608, end="")\n'
          'time.process_time() - start >= 0.15',
          printCallback: (stream, text) {
            expect(stream, 'stdout');
            if (bytes == 0) _hostWork(const Duration(milliseconds: 300));
            bytes += text.length;
          },
        ),
        const MontyBool(true),
      );
      expect(bytes, 8388608);
    },
  );
  test(
    'elapsed clock accumulates and excludes host suspension',
    () async {
      final session = await protoRealSession(
        osPolicy: const OsPolicy(processTime: 'elapsed'),
      );
      expect(
        await session.feedRun(
          'import time\n'
          'first = time.process_time()\n'
          'for i in range(10000):\n    x = i + 1\n'
          'last = time.process_time()\nlast > first',
        ),
        const MontyBool(true),
      );
      expect(
        await session.feedRun(
          'start = time.process_time()\n'
          'wall = time.time()\nf()\n'
          'elapsed = time.process_time() - start\n'
          '(start >= last, elapsed < 1.5, time.time() - wall >= 2, '
          'time.thread_time() >= start)',
          externalLookup: {
            'f': MontyHostFunction(
              'f',
              (_, _) => _hostWork(const Duration(seconds: 2)),
            ),
          },
        ),
        const MontyTuple([
          MontyBool(true),
          MontyBool(true),
          MontyBool(true),
          MontyBool(true),
        ]),
      );
    },
  );
}
