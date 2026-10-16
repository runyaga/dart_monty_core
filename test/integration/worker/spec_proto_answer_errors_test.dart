// Answer conversion and Python exception rendering against the real worker.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

Future<MontyValue> _answer(
  MontySession session,
  MontyValue value, {
  required bool os,
  required bool caught,
}) {
  final call = os ? 'os.getenv("VALUE")' : 'f()';

  return session.feedRun(
    caught
        ? 'import os\ntry:\n    $call\nexcept Exception as e:\n'
              '    r = (type(e).__name__, str(e))\nr'
        : 'import os\n$call',
    externalLookup: {'f': MontyHostFunction('f', (_, _) => value)},
    os: (_, _, _) => value,
  );
}

void _refusal(String label, MontyValue value, String message) {
  for (final os in [false, true]) {
    test(
      '$label ${os ? 'OS' : 'host'} refusal preserves the session',
      () async {
        final session = await protoRealSession();
        expect(
          (await _answer(session, value, os: os, caught: true)).dartValue,
          ['Exception', message],
        );
        await expectLater(
          _answer(session, value, os: os, caught: false),
          throwsA(protoRuntime('Exception', message)),
        );
        expect(await session.feedRun('6 * 7'), const MontyInt(42));
      },
    );
  }
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  _refusal(
    'unhashable frozenset member',
    const MontyFrozenSet([MontyList([])]),
    "Invalid argument (value): TypeError: unhashable type: 'list': "
        "Instance of 'MontyFrozenSet'",
  );
  _refusal(
    'out-of-range time',
    const MontyTime(hour: 24, minute: 0, second: 0, microsecond: 0),
    'Invalid argument (value): invalid value for Time.hour: '
        "24 is outside the range 0..=23: Instance of 'MontyTime'",
  );
  _refusal(
    'out-of-range byte',
    const MontyBytes([256]),
    'Invalid argument (value): byte 256 at index 0 is outside 0..255: '
        "Instance of 'MontyBytes'",
  );

  test(
    'absent and empty messages render differently',
    () async {
      final session = await protoRealSession();
      for (final (message, expected) in [
        (null, 'ValueError'),
        ('', 'ValueError: '),
      ]) {
        final call = await session.feedStart('f()') as FunctionSnapshot;
        await expectLater(
          call.resume(ExternalException('ValueError', message)),
          throwsA(
            isA<MontyRuntimeError>().having(
              (e) => e.display('type-msg'),
              'rendering',
              expected,
            ),
          ),
        );
      }
      expect(await session.feedRun('42'), const MontyInt(42));
    },
  );
}
