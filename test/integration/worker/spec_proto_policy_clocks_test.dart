// Public OS policies against the native worker; no host timer sleeps.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

const String _zoneAttributes =
    'import time\n(time.timezone, time.altzone, time.daylight, time.tzname)';

void _zoneTest(TimeZone zone, String name) {
  test('fixed zone ${zone.offsetSeconds} named ${zone.name}', () async {
    final session = await protoRealSession(
      osPolicy: OsPolicy(datetime: 'call_host', fixedTimezone: zone),
    );
    var calls = 0;
    final result = await session.feedRun(
      _zoneAttributes,
      os: (_, _, _) {
        calls++;

        return const MontyNone();
      },
    );
    expect(result.dartValue, [
      -zone.offsetSeconds,
      -zone.offsetSeconds,
      0,
      [name, name],
    ]);
    expect(calls, 0);
  });
}

void _zones() {
  _zoneTest(const TimeZone(3601, name: ''), '');
  _zoneTest(const TimeZone(-60, name: 'named'), 'named');
  for (final (offset, name) in [
    (0, 'UTC'),
    (3600, 'UTC+01:00'),
    (3661, 'UTC+01:01:01'),
    (-3661, 'UTC-01:01:01'),
  ]) {
    _zoneTest(TimeZone(offset), name);
  }
  test(
    'fixed offset ignores an IANA daylight transition',
    () async {
      for (final (hour, fixedHour, namedHour) in [(6, 1, 1), (7, 2, 3)]) {
        final instant = DateTime.utc(2024, 3, 10, hour, 30);
        final fixed = await protoRealSession(
          osPolicy: OsPolicy(
            fixedDatetime: instant,
            fixedTimezone: const TimeZone(-18000, name: 'America/New_York'),
          ),
        );
        final named = await protoRealSession(
          osPolicy: OsPolicy(
            fixedDatetime: instant,
            timezone: 'America/New_York',
          ),
        );
        const code = 'import datetime\ndatetime.datetime.now().hour';
        expect(await fixed.feedRun(code), MontyInt(fixedHour));
        expect(await named.feedRun(code), MontyInt(namedHour));
      }
    },
  );
}

/// The two unseeded `random.Random().random()` draws of the seed test.
List<MontyValue?> _unseededDraws(MontyValue result) {
  final items = (result as MontyTuple).items;

  return [items.elementAtOrNull(1), items.elementAtOrNull(2)];
}

double _wallSeconds() => DateTime.now().millisecondsSinceEpoch / 1000;

void _clocks() {
  test(
    'host clocks route while process clocks stay independent',
    () async {
      final session = await protoRealSession(
        osPolicy: const OsPolicy(datetime: 'call_host', processTime: 'zero'),
      );
      final calls = <String>[];
      final result = await session.feedRun(
        'import time\nimport datetime\n'
        '(datetime.date.today(), datetime.datetime.now(), time.time(), '
        'time.monotonic(), time.perf_counter(), '
        'time.process_time(), time.thread_time())',
        os: (name, args, kwargs) {
          calls.add(name);

          return switch (name) {
            'date.today' => const MontyDate(year: 2000, month: 1, day: 2),
            'datetime.now' => const MontyDateTime(
              year: 2000,
              month: 1,
              day: 2,
              hour: 3,
              minute: 4,
              second: 5,
            ),
            _ => const MontyFloat(123.5),
          };
        },
      );
      expect(calls, [
        'date.today',
        'datetime.now',
        'time.time',
        'time.time',
        'time.time',
      ]);
      expect(
        result,
        const MontyTuple([
          MontyDate(year: 2000, month: 1, day: 2),
          MontyDateTime(
            year: 2000,
            month: 1,
            day: 2,
            hour: 3,
            minute: 4,
            second: 5,
          ),
          MontyFloat(123.5),
          MontyFloat(123.5),
          MontyFloat(123.5),
          MontyFloat(0),
          MontyFloat(0),
        ]),
      );
    },
  );
  test('system time is bounded by host wall clock', () async {
    final session = await protoRealSession(
      osPolicy: const OsPolicy(datetime: 'system'),
    );
    var calls = 0;
    final before = _wallSeconds();
    final result = await session.feedRun(
      'import time\ntime.time()',
      os: (_, _, _) {
        calls++;

        return const MontyFloat(-1);
      },
    );
    final after = _wallSeconds();
    expect(
      (result as MontyFloat).value,
      inInclusiveRange(before - 0.001, after + 0.001),
    );
    expect(calls, 0);
  });
  test('both process clocks stay zero', () async {
    final session = await protoRealSession(
      osPolicy: const OsPolicy(processTime: 'zero'),
    );
    for (var feed = 0; feed < 2; feed++) {
      expect(
        (await session.feedRun(
          'import time\nsum(range(10000))\n'
          '(time.process_time(), time.thread_time())',
        )).dartValue,
        [0.0, 0.0],
      );
    }
  });
}

void _sleepAndRandom() {
  test('host sleeps bypass cap and total', () async {
    final session = await protoRealSession(
      osPolicy: const OsPolicy(sleep: 'call_host'),
      limits: const ResourceLimits(
        maxMemory: 64000000,
        maxTotalSleep: Duration.zero,
      ),
    );
    final calls = <(String, List<MontyValue>, Map<String, MontyValue>)>[];
    final timers = <Duration>[];
    final result = await runZoned(
      () => session.feedRun(
        'import time\nimport asyncio\ntime.sleep(30)\n'
        'await asyncio.sleep(40)\n42',
        os: (name, args, kwargs) {
          calls.add((name, args, kwargs));

          return const MontyNone();
        },
      ),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, callback) {
          if (duration > Duration.zero) timers.add(duration);

          return parent.createTimer(zone, duration, callback);
        },
      ),
    );
    expect(result, const MontyInt(42));
    expect(
      [
        for (final (name, args, kwargs) in calls) [name, args, kwargs],
      ],
      [
        [
          'time.sleep',
          [const MontyFloat(30)],
          <String, MontyValue>{},
        ],
        [
          'asyncio.sleep',
          [const MontyFloat(40)],
          <String, MontyValue>{},
        ],
      ],
    );
    expect(
      timers.where(
        (d) =>
            d == const Duration(seconds: 10) ||
            d == const Duration(seconds: 30) ||
            d == const Duration(seconds: 40),
      ),
      isEmpty,
    );
  });
  test(
    'first random draw requests exactly 2496 bytes',
    () async {
      final session = await protoRealSession(
        osPolicy: const OsPolicy(randomStart: 'call_host'),
      );
      final calls = <(String, List<MontyValue>, Map<String, MontyValue>)>[];
      MontyValue entropy(
        String name,
        List<MontyValue> args,
        Map<String, MontyValue> kwargs,
      ) {
        calls.add((name, args, kwargs));

        return MontyBytes(List.filled(2496, 0));
      }

      expect(
        await session.feedRun('import random\n42', os: entropy),
        const MontyInt(42),
      );
      expect(calls, isEmpty);
      final drawRange = inInclusiveRange(0, 1);
      for (var draw = 0; draw < 2; draw++) {
        final result = await session.feedRun('random.random()', os: entropy);
        expect((result as MontyFloat).value, drawRange);
      }
      expect(
        [
          for (final (name, args, kwargs) in calls) [name, args, kwargs],
        ],
        [
          [
            'os.urandom',
            [const MontyInt(2496)],
            <String, MontyValue>{},
          ],
        ],
      );
    },
  );
  test(
    'configured seeds initialize Random and can be overridden',
    () async {
      final policy = OsPolicy(randomSeed: RandomSeed.integer(BigInt.from(42)));
      final sessions = await Future.wait([
        for (var i = 0; i < 2; i++) protoRealSession(osPolicy: policy),
      ]);
      final session = sessions.firstOrNull ?? fail('missing first session');
      final other = sessions.lastOrNull ?? fail('missing second session');
      const code =
          'import random\n(random.random(), random.Random().random(), '
          'random.Random().random())';
      final first = await session.feedRun(code);
      expect(await other.feedRun(code), first);
      expect(
        (first as MontyTuple).items.firstOrNull,
        const MontyFloat(0.6394267984578837),
      );
      final draws = _unseededDraws(first);
      expect(draws.toSet(), hasLength(2));
      final reseeded = await protoRealSession(
        osPolicy: OsPolicy(randomSeed: RandomSeed.integer(BigInt.from(43))),
      );
      final other43 = _unseededDraws(await reseeded.feedRun(code));
      expect(draws.toSet().intersection(other43.toSet()), isEmpty);
      // CPython/Monty MT19937's first draw for integer seed 7.
      expect(
        await session.feedRun('random.seed(7)\nrandom.random()'),
        const MontyFloat(0.32383276483316237),
      );
    },
  );
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  _zones();
  _clocks();
  _sleepAndRandom();
}
