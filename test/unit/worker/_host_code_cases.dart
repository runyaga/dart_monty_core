// Host code against a real worker (C3-5): the OS handler's answers and
// declines, and the Python exception a host throw raises. The expected
// values are upstream's (pydantic-monty 1.1.0) for the same code and host
// answers. Shared by the VM harness
// (test/integration/worker/monty_snapshot_io_test.dart) and the Chrome one
// (pool_session_web_test.dart), so vm, dart2js and dart2wasm run the same
// cases.
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_not_handled_exception.dart'
    show OsCallNotHandledException;
import 'package:dart_monty_core/src/worker/host_answers.dart' show AsyncDecline;
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_session.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/os_policy.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart'
    show SessionConfig;
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';

/// Runs a test body with a session configured by [config] on a one-worker
/// pool.
typedef WithConfiguredSession =
    Future<void> Function(
      SessionConfig config,
      Future<void> Function(MontySession s) body,
    );

void _ignore(String stream, String text) => _ignored++;

/// How many prints [_ignore] dropped; never looked at.
var _ignored = 0;

/// Every session's memory is bounded.
const ResourceLimits _bounded = ResourceLimits(maxMemory: 64 * 1024 * 1024);

const SessionConfig _plain = SessionConfig(limits: _bounded);

const SessionConfig _callHost = SessionConfig(
  limits: _bounded,
  osPolicy: OsPolicy(datetime: 'call_host'),
);

/// Catches what `f()` raises: its type name, `repr` and `args`.
const String _catchF =
    'try:\n'
    '  f()\n'
    'except BaseException as e:\n'
    '  r = (type(e).__name__, repr(e), e.args)\n'
    'r';

/// Catches what reading `/x` raises, as [_catchF] does.
const String _catchRead =
    'from pathlib import Path\n'
    'try:\n'
    "  Path('/x').read_text()\n"
    'except BaseException as e:\n'
    '  r = (type(e).__name__, repr(e), e.args)\n'
    'r';

/// The tuple [_catchF] and [_catchRead] return.
MontyTuple _caught(String type, String repr, List<String> args) => MontyTuple([
  MontyString(type),
  MontyString(repr),
  MontyTuple([for (final a in args) MontyString(a)]),
]);

Never _decline(String name, List<MontyValue> a, Map<String, MontyValue> k) =>
    throw const OsCallNotHandledException();

Matcher _runtime(String excType, String message) => isA<MontyRuntimeError>()
    .having((e) => e.exception.excType, 'excType', excType)
    .having((e) => e.exception.message, 'message', message)
    .having((e) => e.toString(), 'message', '$excType: $message');

/// The C3-5 cases, labelled with [label], each in a session [withSession]
/// gives.
void hostCodeSessionTests(String label, WithConfiguredSession withSession) {
  group('host code ($label)', () {
    test('an OS handler answers datetime.now with a MontyDateTime', () async {
      const now = MontyDateTime(
        year: 2024,
        month: 5,
        day: 6,
        hour: 7,
        minute: 8,
        second: 9,
        microsecond: 123000,
        offsetSeconds: 7200,
        timezoneName: 'X',
      );
      await withSession(_callHost, (s) async {
        final calls = <(String, List<MontyValue>, Map<String, MontyValue>)>[];
        final out = await s.feedRun(
          'import datetime\n'
          'd = datetime.datetime.now()\n'
          '(repr(d), d.isoformat(), str(d.tzinfo))',
          printCallback: _ignore,
          os: (name, args, kwargs) {
            calls.add((name, args, kwargs));

            return now;
          },
        );
        expect(
          out,
          const MontyTuple([
            MontyString(
              'datetime.datetime(2024, 5, 6, 7, 8, 9, 123000, '
              'tzinfo=datetime.timezone(datetime.timedelta(seconds=7200), '
              "'X'))",
            ),
            MontyString('2024-05-06T07:08:09.123000+02:00'),
            MontyString('X'),
          ]),
        );
        final (name, args, kwargs) = onlyItem(calls);
        expect(name, 'datetime.now');
        expect(args, [const MontyNone()]);
        expect(kwargs, isEmpty);
      });
    });

    test('an OS handler returning None answers None', () async {
      await withSession(_callHost, (s) async {
        expect(
          await s.feedRun(
            'import datetime\ndatetime.datetime.now()',
            printCallback: _ignore,
            os: (name, args, kwargs) => const MontyNone(),
          ),
          const MontyNone(),
        );
      });
    });

    test('a decline from a future is no decline: TypeError, as upstream '
        'raises for a NOT_HANDLED a coroutine returns', () async {
      const sleepHost = SessionConfig(
        limits: _bounded,
        osPolicy: OsPolicy(datetime: 'call_host', sleep: 'call_host'),
      );
      await withSession(sleepHost, (s) async {
        for (final code in [
          'import datetime\ndatetime.datetime.now()',
          'import asyncio\nawait asyncio.sleep(0.01)',
        ]) {
          await expectLater(
            s.feedRun(
              code,
              printCallback: _ignore,
              os: (name, args, kwargs) async =>
                  throw const OsCallNotHandledException(),
            ),
            throwsA(_runtime('TypeError', AsyncDecline.message)),
            reason: code,
          );
        }
        // A coroutine's value is not the sleep's: it still returns None.
        expect(
          await s.feedRun(
            'import asyncio\nawait asyncio.sleep(0.01)',
            printCallback: _ignore,
            os: (name, args, kwargs) async => const MontyInt(5),
          ),
          const MontyNone(),
        );
      });
    });

    test('an OS handler throwing ExternalException raises its type', () async {
      await withSession(_plain, (s) async {
        expect(
          await s.feedRun(
            _catchRead,
            printCallback: _ignore,
            os: (name, args, kwargs) =>
                throw const ExternalException('FileNotFoundError', 'nope'),
          ),
          _caught('FileNotFoundError', "FileNotFoundError('nope')", ['nope']),
        );
      });
    });

    test('an OS handler throwing anything else raises Exception', () async {
      await withSession(_plain, (s) async {
        expect(
          await s.feedRun(
            _catchRead,
            printCallback: _ignore,
            os: (name, args, kwargs) => throw StateError('x'),
          ),
          _caught('Exception', "Exception('Bad state: x')", ['Bad state: x']),
        );
      });
    });

    test("a declined call raises the worker's default: PermissionError for "
        'the filesystem, RuntimeError for the rest', () async {
      await withSession(_callHost, (s) async {
        for (final (code, excType, message) in [
          (
            "from pathlib import Path\nPath('/x').read_text()",
            'PermissionError',
            "Permission denied: '/x'",
          ),
          ("open('/y')", 'PermissionError', "Permission denied: '/y'"),
          (
            "import os\nos.getenv('A')",
            'RuntimeError',
            "'os.getenv' is not supported in this environment",
          ),
          (
            'import datetime\ndatetime.datetime.now()',
            'RuntimeError',
            "'datetime.now' is not supported in this environment",
          ),
        ]) {
          await expectLater(
            s.feedRun(code, printCallback: _ignore, os: _decline),
            throwsA(_runtime(excType, message)),
            reason: code,
          );
        }
      });
    });

    test('with no OS handler, the same defaults', () async {
      await withSession(_callHost, (s) async {
        await expectLater(
          s.feedRun(
            "from pathlib import Path\nPath('/x').read_text()",
            printCallback: _ignore,
          ),
          throwsA(_runtime('PermissionError', "Permission denied: '/x'")),
        );
        await expectLater(
          s.feedRun(
            'import datetime\ndatetime.datetime.now()',
            printCallback: _ignore,
          ),
          throwsA(
            _runtime(
              'RuntimeError',
              "'datetime.now' is not supported in this environment",
            ),
          ),
        );
      });
    });

    test('a host function throwing a StateError raises Exception', () async {
      await withSession(_plain, (s) async {
        expect(
          await s.feedRun(
            _catchF,
            printCallback: _ignore,
            externalLookup: {
              'f': MontyHostFunction(
                'f',
                (args, kwargs) => throw StateError('x'),
              ),
            },
          ),
          _caught('Exception', "Exception('Bad state: x')", ['Bad state: x']),
        );
      });
    });

    test('a thrown ExternalException without a message raises with an '
        "empty one, as a raised Python exception's argument", () async {
      await withSession(_plain, (s) async {
        expect(
          await s.feedRun(
            _catchF,
            printCallback: _ignore,
            externalLookup: {
              'f': MontyHostFunction(
                'f',
                (args, kwargs) => throw const ExternalException('ValueError'),
              ),
            },
          ),
          _caught('ValueError', "ValueError('')", ['']),
        );
      });
    });

    test('a manual resume without a message raises with none, as '
        "upstream's {'exc_type': ...} form does", () async {
      await withSession(_plain, (s) async {
        final snap =
            await s.feedStart(_catchF, printCallback: _ignore)
                as FunctionSnapshot;
        final done =
            await snap.resume(const ExternalException('ValueError'))
                as MontyComplete;
        expect(done.output, _caught('ValueError', 'ValueError()', []));
      });
    });

    test('an unknown excType: an ArgumentError at a manual resume, which '
        'leaves the snapshot to retry; thrown, the sandbox gets '
        'Exception', () async {
      await withSession(_plain, (s) async {
        final snap =
            await s.feedStart(_catchF, printCallback: _ignore)
                as FunctionSnapshot;
        expect(
          () => snap.resume(const ExternalException('NoSuchError', 'm')),
          throwsA(
            isA<ArgumentError>().having(
              (e) => e.message,
              'message',
              "Unknown exception type: 'NoSuchError'",
            ),
          ),
        );
        final done =
            await snap.resume(const ExternalException('KeyError', 'k'))
                as MontyComplete;
        expect(done.output, _caught('KeyError', "KeyError('k')", ['k']));

        final text = unknownExcType('NoSuchError').toString();
        expect(
          await s.feedRun(
            'try:\n'
            '  f()\n'
            'except BaseException as e:\n'
            '  r = (type(e).__name__, e.args)\n'
            'r',
            printCallback: _ignore,
            externalLookup: {
              'f': MontyHostFunction(
                'f',
                (args, kwargs) =>
                    throw const ExternalException('NoSuchError', 'm'),
              ),
            },
          ),
          MontyTuple([
            const MontyString('Exception'),
            MontyTuple([MontyString(text)]),
          ]),
        );
      });
    });
  });
}
