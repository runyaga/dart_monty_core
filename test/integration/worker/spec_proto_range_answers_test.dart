// Host range refusals become exact Python exceptions for both callback kinds.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

Future<MontyValue> _answer(
  MontySession session,
  MontyValue Function() value, {
  required bool os,
  required bool caught,
}) {
  final call = os ? 'os.getenv("VALUE")' : 'f()';

  return session.feedRun(
    caught
        ? 'import os\ntry:\n    $call\nexcept Exception as e:\n'
              '    r = (type(e).__name__, str(e))\nr'
        : 'import os\n$call',
    externalLookup: {'f': MontyHostFunction('f', (_, _) => value())},
    os: (_, _, _) => value(),
  );
}

void _refusal(
  String label,
  MontyValue Function() value,
  String message,
) {
  for (final os in [false, true]) {
    test('$label ${os ? 'OS' : 'host'} refusal is catchable', () async {
      final session = await protoRealSession();
      expect((await _answer(session, value, os: os, caught: true)).dartValue, [
        'Exception',
        message,
      ]);
      await expectLater(
        _answer(session, value, os: os, caught: false),
        throwsA(protoRuntime('Exception', message)),
      );
      expect(await session.feedRun('42'), const MontyInt(42));
    });
  }
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  _refusal(
    'timezone',
    () => const MontyTimeZone(offsetSeconds: 86400),
    'Invalid argument (value): invalid value for TimeZone.offset_seconds: '
        '86400 is outside the range -86399..=86399: '
        "Instance of 'MontyTimeZone'",
  );
  _refusal(
    'byte',
    () => const MontyBytes([256]),
    'Invalid argument (value): byte 256 at index 0 is outside 0..255: '
        "Instance of 'MontyBytes'",
  );
  _refusal(
    'date',
    () => const MontyDate(year: 10000, month: 1, day: 1),
    'Invalid argument (value): invalid value for Date.year: '
        '10000 is outside the range 1..=9999: '
        "Instance of 'MontyDate'",
  );
  _refusal(
    'time',
    () => const MontyTime(hour: 24, minute: 0, second: 0, microsecond: 0),
    'Invalid argument (value): invalid value for Time.hour: '
        '24 is outside the range 0..=23: '
        "Instance of 'MontyTime'",
  );
  // File position is validated at construction, inside the callback.
  _refusal(
    'position',
    () => MontyFileHandle('/x', 'r', position: BigInt.from(-1)),
    ArgumentError.value(
      BigInt.from(-1),
      'position',
      'a file position is in 0..2^64-1',
    ).toString(),
  );
}
