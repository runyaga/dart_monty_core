// System clock routing, sleep exclusion and entropy policy against the worker.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

void _occupyHost() {
  final clock = Stopwatch()..start();
  var turns = 0;
  while (clock.elapsedMilliseconds < 1500) {
    turns++;
  }
  expect(turns, greaterThan(0));
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  test('every system clock bypasses the OS handler', () async {
    final session = await protoRealSession(
      osPolicy: const OsPolicy(datetime: 'system'),
    );
    var calls = 0;
    final before = DateTime.now().toUtc();
    final result = await session.feedRun(
      'import datetime\nimport time\n'
      '(datetime.date.today().isoformat(), '
      'datetime.datetime.now().isoformat(), '
      'time.time(), time.monotonic(), time.perf_counter())',
      os: (_, _, _) {
        calls++;

        return const MontyFloat(-1);
      },
    );
    final after = DateTime.now().toUtc();
    final values = (result as MontyTuple).items;
    final date = (values.firstOrNull ?? fail('missing date')) as MontyString;
    final datetime =
        (values.elementAtOrNull(1) ?? fail('missing datetime')) as MontyString;
    final instant = DateTime.parse('${datetime.value}Z');
    expect(
      instant.microsecondsSinceEpoch,
      inInclusiveRange(
        before.microsecondsSinceEpoch,
        after.microsecondsSinceEpoch,
      ),
    );
    expect(
      date.value,
      anyOf(
        before.toIso8601String().split('T').firstOrNull,
        after.toIso8601String().split('T').firstOrNull,
      ),
    );
    for (final value in values.skip(2)) {
      expect(
        (value as MontyFloat).value,
        inInclusiveRange(
          before.microsecondsSinceEpoch / 1000000,
          after.microsecondsSinceEpoch / 1000000,
        ),
      );
    }
    expect(calls, 0);
  });

  test(
    'both elapsed clocks exclude host-serviced sleep',
    () async {
      final session = await protoRealSession(
        osPolicy: const OsPolicy(processTime: 'elapsed', sleep: 'call_host'),
      );
      var sleeps = 0;
      expect(
        await session.feedRun(
          'import time\np = time.process_time()\nt = time.thread_time()\n'
          'wall = time.time()\ntime.sleep(30)\n'
          '(0 <= time.process_time() - p < 0.75, '
          '0 <= time.thread_time() - t < 0.75, time.time() - wall >= 1.5)',
          os: (name, args, kwargs) {
            expect(name, 'time.sleep');
            expect(args, [const MontyFloat(30)]);
            expect(kwargs, isEmpty);
            sleeps++;
            _occupyHost();

            return const MontyInt(99);
          },
        ),
        const MontyTuple([MontyBool(true), MontyBool(true), MontyBool(true)]),
      );
      expect(sleeps, 1);
      expect(
        await session.feedRun(
          '(time.process_time() > p, time.thread_time() > t)',
        ),
        const MontyTuple([MontyBool(true), MontyBool(true)]),
      );
    },
  );

  test(
    'system entropy initializes random '
    'without calling the handler',
    () async {
      final session = await protoRealSession(
        osPolicy: const OsPolicy(randomStart: 'system'),
      );
      var calls = 0;
      expect(
        await session.feedRun(
          'import random\n0 <= random.random() < 1',
          os: (_, _, _) {
            calls++;

            return MontyBytes(List.filled(2496, 0));
          },
        ),
        const MontyBool(true),
      );
      expect(calls, 0);
    },
  );
}
