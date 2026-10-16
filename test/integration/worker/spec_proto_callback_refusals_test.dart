// Exact sandbox failures and session survival, against the native worker.
@Tags(['worker'])
@TestOn('vm')
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '../../unit/worker/_spec_proto_support.dart';
import '_worker_harness.dart';

const _surrogateMessage =
    "'utf-8' codec can't encode character "
    r"'\ud800' in position 0: surrogates not allowed";

// Dart ArgumentError renders a non-primitive with Error.safeToString.
const _timedeltaMessage =
    'Invalid argument (value): invalid value for TimeDelta.seconds: '
    '86400 is outside the normalized range 0..86400: '
    "Instance of 'MontyTimeDelta'";

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
              '    result = (type(e).__name__, str(e))\nresult'
        : 'import os\n$call',
    externalLookup: {'f': MontyHostFunction('f', (_, _) => value)},
    os: (_, _, _) => value,
  );
}

void _surrogates() {
  for (final os in [false, true]) {
    test(
      '${os ? 'OS' : 'host'} surrogate is catchable and preserves session',
      () async {
        final session = await protoRealSession();
        const value = MontyString('\uD800');
        expect(
          (await _answer(session, value, os: os, caught: true)).dartValue,
          ['UnicodeEncodeError', _surrogateMessage],
        );
        await expectLater(
          _answer(session, value, os: os, caught: false),
          throwsA(
            isA<MontyRuntimeError>()
                .having((e) => e.exception.excType, 'type', 'ValueError')
                .having(
                  (e) => e.toString(),
                  'message',
                  'UnicodeEncodeError: $_surrogateMessage',
                ),
          ),
        );
        expect(await session.feedRun('42'), const MontyInt(42));
      },
    );
  }
}

void main() {
  expectNoWorkersLeftAfterEachTest();
  _surrogates();
  for (final os in [false, true]) {
    test(
      '${os ? 'OS' : 'host'} refusal raises Exception',
      () async {
        final session = await protoRealSession();
        const value = MontyTimeDelta(days: 0, seconds: 86400);
        expect(
          (await _answer(session, value, os: os, caught: true)).dartValue,
          ['Exception', _timedeltaMessage],
        );
        expect(await session.feedRun('42'), const MontyInt(42));
      },
    );
  }
  test(
    'default permission error '
    'uses normalized path',
    () async {
      final session = await protoRealSession();
      await expectLater(
        session.feedRun(
          "from pathlib import Path\nPath('/a//b/../c/./').read_text()",
          os: (_, _, _) => throw const OsCallNotHandledException(),
        ),
        throwsA(protoRuntime('PermissionError', "Permission denied: '/a/c'")),
      );
      expect(await session.feedRun('42'), const MontyInt(42));
    },
  );
}
