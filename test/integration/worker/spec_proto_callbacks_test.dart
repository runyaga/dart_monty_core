// Callback refusals delivered to Python by the real worker executable.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart'
    show montyClassTypeProxy;
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

const _invalidBytes = MontyBytes([256]);
const _invalidDict = MontyDict([(MontyList([]), MontyNone())]);
const _invalidSet = MontySet([MontyList([])]);
const _invalidDate = MontyDateTime(
  year: 2026,
  month: 13,
  day: 1,
  hour: 0,
  minute: 0,
  second: 0,
);

// ArgumentError's complete text, from Dart's rendering and the spec's
// byte/range/hashability refusals. Do not derive it by running ArenaWriter.
const _bytesError =
    'Invalid argument (value): byte 256 at index 0 is outside 0..255: '
    "Instance of 'MontyBytes'";

Future<MontyValue> _answer(
  MontySession session,
  MontyValue value, {
  required bool os,
  required bool caught,
}) {
  final call = os ? 'os.getenv("VALUE")' : 'f()';
  final code = caught
      ? 'import os\ntry:\n    $call\nexcept Exception as e:\n'
            '    result = (type(e).__name__, str(e))\nresult'
      : 'import os\n$call';

  return session.feedRun(
    code,
    externalLookup: {'f': MontyHostFunction('f', (_, _) => value)},
    os: (_, _, _) => value,
  );
}

MontyClassTypeProxy _cyclicClassType() {
  final items = <MontyValue>[];
  final loop = MontyList(items);
  items.add(loop);

  return montyClassTypeProxy(
    name: 'P',
    id: '0123abcd-0000-4000-8000-00000000cafe',
    hostDefined: true,
    isDataclass: true,
    attrs: {'loop': loop},
  );
}

void _conversion(String label, MontyValue value, String message) {
  for (final os in [false, true]) {
    test(
      '$label ${os ? 'OS' : 'host'} conversion raises exact Exception',
      () async {
        final session = await protoRealSession();
        final result = await _answer(session, value, os: os, caught: true);
        expect(result.dartValue, ['Exception', message]);
        expect(await session.feedRun('6 * 7'), const MontyInt(42));
      },
    );
  }
}

void _cycle(String label) {
  for (final os in [false, true]) {
    test(
      '$label ${os ? 'OS' : 'host'} cycle is catchable; session survives',
      () async {
        final session = await protoRealSession();
        final value = protoCycle();
        final call = os ? 'os.getenv("VALUE")' : 'f()';
        expect(
          await session.feedRun(
            'import os\ntry:\n    $call\nexcept ValueError as e:\n'
            '    result = str(e)\nresult',
            externalLookup: {'f': MontyHostFunction('f', (_, _) => value)},
            os: (_, _, _) => value,
          ),
          const MontyString('Circular reference detected'),
        );
        await expectLater(
          _answer(session, value, os: os, caught: false),
          throwsA(protoRuntime('ValueError', 'Circular reference detected')),
        );
        expect(await session.feedRun('6 * 7'), const MontyInt(42));
      },
    );
  }
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  _conversion('invalid bytes', _invalidBytes, _bytesError);
  _conversion(
    'invalid datetime',
    _invalidDate,
    'Invalid argument (value): invalid value for DateTime.month: '
        "13 is outside the range 1..=12: Instance of 'MontyDateTime'",
  );
  _conversion(
    'unhashable dict key',
    _invalidDict,
    "Invalid argument (value): TypeError: unhashable type: 'list': "
        "Instance of 'MontyDict'",
  );
  _conversion(
    'unhashable set member',
    _invalidSet,
    "Invalid argument (value): TypeError: unhashable type: 'list': "
        "Instance of 'MontySet'",
  );
  _cycle('cyclic dict');
  test(
    'an uncaught cyclic class type answer fails but keeps the session',
    () async {
      final session = await protoRealSession();

      await expectLater(
        _answer(session, _cyclicClassType(), os: false, caught: false),
        throwsA(protoRuntime('ValueError', 'Circular reference detected')),
      );
      expect(await session.feedRun('6 * 7'), const MontyInt(42));
    },
  );
}
