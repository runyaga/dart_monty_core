// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 09 — Session settings: resource limits and the OS policy
//
// ResourceLimits bound one session: how long a feed may run, how much the
// interpreter may allocate, how deep it may recurse, and how many host calls
// it may suspend for. A limit that is hit raises a Python exception inside
// the sandbox, which reaches Dart as MontyRuntimeError; the session survives
// it and runs the next feed.
//
// OsPolicy sets what the sandbox sees of the outside world: the clock and
// time zone, what time.sleep does, and how `random` is seeded. A fixed
// policy makes a run reproducible.
//
// Covers: ResourceLimits (maxFeedDuration, maxMemory, maxRecursionDepth,
//         maxSuspensions), OsPolicy (fixedDatetime, timezone, sleep,
//         randomSeed), withSession(limits:, osPolicy:), MontyRuntimeError.
//
// Run: dart run example/09_session_settings.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await Monty.withPool((monty) async {
    await monty.withSession(
      (session) async {
        print('\n── maxFeedDuration ──');
        await _expectLimit(session, 'while True:\n    pass', 'TimeoutError');

        print('\n── maxMemory ──');
        await _expectLimit(
          session,
          // Local to a function, so the memory is freed when it raises.
          'def grow():\n'
              '    chunks = []\n'
              '    while True:\n'
              '        chunks.append("x" * 100000)\n'
              'grow()',
          'MemoryError',
        );

        print('\n── maxRecursionDepth ──');
        await _expectLimit(
          session,
          'def down(n):\n    return down(n + 1)\ndown(0)',
          'RecursionError',
        );

        // Within the limits the session works as usual.
        final ok = await session.feedRun('sum(range(1000))');
        print('\nafter the limits: $ok');
        _check(ok == const MontyInt(499500), 'session survives');
      },
      limits: const ResourceLimits(
        maxFeedDuration: Duration(milliseconds: 200),
        maxMemory: 4 << 20,
        maxRecursionDepth: 50,
      ),
    );

    // Each host call is a suspension; maxSuspensions bounds them per session.
    await monty.withSession((session) async {
      print('\n── maxSuspensions ──');
      await _expectLimit(
        session,
        'for i in range(10):\n    ping()',
        'RuntimeError',
        externals: {'ping': (_, _) => const MontyNone()},
      );
    }, limits: const ResourceLimits(maxSuspensions: 5));

    // ── OsPolicy ─────────────────────────────────────────────────────────────
    print('\n── OsPolicy ──');
    final policy = OsPolicy(
      fixedDatetime: DateTime.utc(2030, 1, 2, 3, 4, 5),
      timezone: 'utc',
      sleep: 'zero',
      randomSeed: RandomSeed.integer(BigInt.from(42)),
    );
    const code = '''
import datetime, random, time
start = time.time()
time.sleep(30)
(str(datetime.datetime.now()), time.time() - start, random.random())
''';
    final first = await monty.withSession(
      (session) => session.feedRun(code),
      osPolicy: policy,
    );
    final second = await monty.withSession(
      (session) => session.feedRun(code),
      osPolicy: policy,
    );
    print('now, slept, random: ${first.dartValue}');
    final items = (first as MontyTuple).items;
    _check(items[0] == const MontyString('2030-01-02 03:04:05'), 'fixed now');
    _check(first == second, 'two runs under one policy agree');
  });
}

Future<void> _expectLimit(
  MontySession session,
  String code,
  String excType, {
  Map<String, MontyValue Function(List<MontyValue>, Map<String, MontyValue>)>?
  externals,
}) async {
  try {
    await session.feedRun(code, externals: externals);
  } on MontyRuntimeError catch (e) {
    print('raised: $e');
    _check(e.exception.excType == excType, 'expected $excType, got $e');

    return;
  }
  throw StateError('no $excType from: $code');
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}
