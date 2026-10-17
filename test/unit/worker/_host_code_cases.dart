// Host code against a real worker (C3-5): the OS handler's answers and
// declines, and the Python exception a host throw raises. The expected
// values are upstream's (pydantic-monty 1.1.0) for the same code and host
// answers. Shared by the VM harness
// (test/integration/worker/monty_snapshot_io_test.dart) and the Chrome one
// (pool_session_web_test.dart), so vm, dart2js and dart2wasm run the same
// cases.
import 'dart:collection';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_not_handled_exception.dart'
    show OsCallNotHandledException;
import 'package:dart_monty_core/src/worker/host_answers.dart'
    show AsyncDecline, coroutine;
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

/// Catches what `datetime.now()` raises, as [_catchF] does.
const String _catchNow =
    'r = None\n'
    'import datetime\n'
    'try:\n'
    '  datetime.datetime.now()\n'
    'except BaseException as e:\n'
    '  r = (type(e).__name__, repr(e), e.args)\n'
    'r';

/// The tuple [_catchF] and [_catchRead] return.
MontyTuple _caught(String type, String repr, List<String> args) => MontyTuple([
  MontyString(type),
  MontyString(repr),
  MontyTuple([for (final a in args) MontyString(a)]),
]);

/// Attributes that throw when read: host code that breaks the map's
/// contract, so preparing the answer to an [ExternalException] fails.
final class _UnreadableAttributes
    extends UnmodifiableMapBase<String, MontyValue> {
  const _UnreadableAttributes();

  @override
  MontyValue? operator [](Object? key) =>
      throw const FormatException('unreadable');

  @override
  Iterable<String> get keys => const [];
}

/// The failure [_UnreadableAttributes] raises.
final Matcher _unreadable = isA<FormatException>();

/// A feed on a session that was ended, not one left awaiting an answer.
final Matcher _finished = throwsA(
  isA<StateError>().having(
    (e) => e.message,
    'message',
    'the session is finished',
  ),
);

/// A host function raising an exception whose answer cannot be prepared.
MontyHostFunction _unanswerable(String name, {bool async = false}) {
  MontyValue fail(List<MontyValue> _, Map<String, MontyValue> _) =>
      throw const ExternalException(
        'json.JSONDecodeError',
        'm',
        _UnreadableAttributes(),
      );

  return MontyHostFunction(name, async ? coroutine(fail) : fail);
}

Never _mustNotRun(List<MontyValue> args, Map<String, MontyValue> kwargs) =>
    throw StateError('this host function should not be invoked');

MontyValue _plainAnswer(
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) => const MontyInt(3);

final HostClass<Object> _lazyLookupClass = HostClass(
  'Lookup',
  instance: (
    fields: const {},
    properties: {
      'boom': (value) => throw const ExternalException('KeyError', 'boom'),
    },
    methods: const {},
  ),
);

final HostClass<Object> _syntaxClass = HostClass(
  'Broken',
  methods: {
    'parse': (args, kwargs) =>
        throw const ExternalException('SyntaxError', 'bad method'),
  },
);

/// A class proxy whose attribute value is a cyclic container.
MontyClassProxy _cyclicProxy() {
  final values = <MontyValue>[];
  final loop = MontyList(values);
  values.add(loop);

  return montyClassProxy(
    classType: montyClassTypeProxy(
      name: 'Loop',
      id: '00000000-0000-4000-8000-000000000200',
      hostDefined: false,
      isDataclass: false,
      attrs: const {},
    ),
    instanceId: '00000000-0000-4000-8000-000000000201',
    attrs: {'loop': loop},
  );
}

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
    test('feed retains chosen and fallback host exception types', () async {
      await withSession(_plain, (s) async {
        expect(
          await s.feedRun(
            _catchF,
            printCallback: _ignore,
            externalLookup: {
              'f': MontyHostFunction(
                'f',
                (_, _) => throw const ExternalException('KeyError', 'chosen'),
              ),
            },
          ),
          _caught('KeyError', "KeyError('chosen')", ['chosen']),
        );
        expect(
          await s.feedRun(
            _catchF,
            printCallback: _ignore,
            externalLookup: {
              'f': MontyHostFunction(
                'f',
                (_, _) => throw StateError('ordinary'),
              ),
            },
          ),
          _caught(
            'Exception',
            "Exception('Bad state: ordinary')",
            ['Bad state: ordinary'],
          ),
        );
      });
    });
    test('a lazy KeyError defeats hasattr and getattr defaults', () async {
      final value = ClassInstance(
        Object(),
        classType: ClassType(_lazyLookupClass),
        policies: const (
          eagerAttrs: null,
          lazyAttrs: 'all',
          allowedMethods: null,
        ),
      );
      await withSession(_plain, (s) async {
        final output = await s.feedRun(
          'try:\n'
          "  hasattr(x, 'boom')\n"
          'except BaseException as e:\n'
          '  has = type(e).__name__\n'
          'try:\n'
          "  getattr(x, 'boom', 'default')\n"
          'except BaseException as e:\n'
          '  got = type(e).__name__\n'
          '(has, got)',
          inputs: {'x': value},
          printCallback: _ignore,
        );
        expect(
          output,
          const MontyTuple([MontyString('KeyError'), MontyString('KeyError')]),
        );
      });
    });

    test('a class method SyntaxError surfaces as MontySyntaxError', () async {
      final value = ClassType(
        _syntaxClass,
        policies: const (
          eagerAttrs: null,
          lazyAttrs: null,
          allowedMethods: 'all',
        ),
      );
      await withSession(_plain, (s) async {
        await expectLater(
          s.feedRun(
            'C.parse()',
            inputs: {'C': value},
            printCallback: _ignore,
          ),
          throwsA(
            isA<MontySyntaxError>()
                .having(
                  (e) => e.exception.excType,
                  'exception type',
                  'SyntaxError',
                )
                .having(
                  (e) => e.exception.message,
                  'exception message',
                  'bad method',
                ),
          ),
        );
      });
    });

    test('a host function crossing back is a named string', () async {
      const function = MontyHostFunction('passed', _mustNotRun);
      await withSession(_plain, (s) async {
        expect(
          await s.feedRun(
            'f',
            inputs: {'f': function},
            printCallback: _ignore,
          ),
          const MontyString('passed'),
        );

        final snapshot =
            await s.feedStart(
                  'target(f)',
                  inputs: {
                    'f': function,
                    'target': const MontyHostFunction('target', _mustNotRun),
                  },
                  printCallback: _ignore,
                )
                as FunctionSnapshot;
        expect(snapshot.args, [const MontyString('passed')]);
        await snapshot.resume(const ExternalReturnValue(MontyNone()));

        final callbackArgs = <MontyValue>[];
        expect(
          await s.feedRun(
            'callback(f)',
            inputs: {'f': function},
            externalLookup: {
              'callback': MontyHostFunction('callback', (args, kwargs) {
                callbackArgs.addAll(args);

                return const MontyNone();
              }),
            },
            printCallback: _ignore,
          ),
          const MontyNone(),
        );
        expect(callbackArgs, [const MontyString('passed')]);
      });
    });

    test('a missing host dispatch name raises NameError without calling its '
        'body', () async {
      var calls = 0;
      final function = MontyHostFunction('missing', (args, kwargs) {
        calls++;

        return const MontyNone();
      });
      await withSession(_plain, (s) async {
        expect(
          await s.feedRun(
            'try:\n'
            '  f()\n'
            'except BaseException as e:\n'
            '  caught = type(e).__name__\n'
            'caught',
            inputs: {'f': function},
            printCallback: _ignore,
          ),
          const MontyString('NameError'),
        );
        await expectLater(
          s.feedRun(
            'f()',
            inputs: {'f': function},
            printCallback: _ignore,
          ),
          throwsA(
            isA<MontyRuntimeError>().having(
              (e) => e.exception.excType,
              'exception type',
              'NameError',
            ),
          ),
        );
        expect(calls, 0);
      });
    });

    test('a host function dispatching to a value raises TypeError without '
        'calling its body', () async {
      var calls = 0;
      final function = MontyHostFunction('value', (args, kwargs) {
        calls++;

        return const MontyNone();
      });
      await withSession(_plain, (s) async {
        expect(
          await s.feedRun(
            'try:\n'
            '  f()\n'
            'except BaseException as e:\n'
            '  caught = type(e).__name__\n'
            'caught',
            inputs: {
              'f': function,
            },
            externalLookup: {'value': const MontyInt(1)},
            printCallback: _ignore,
          ),
          const MontyString('TypeError'),
        );
        await expectLater(
          s.feedRun(
            'f()',
            inputs: {'f': function},
            externalLookup: {'value': const MontyInt(1)},
            printCallback: _ignore,
          ),
          throwsA(
            isA<MontyRuntimeError>().having(
              (e) => e.exception.excType,
              'exception type',
              'TypeError',
            ),
          ),
        );
        expect(calls, 0);
      });
    });

    group('host function results', () {
      const plain = MontyInt(3);
      final notAwaitable = _runtime(
        'TypeError',
        "'int' object can't be awaited",
      );

      test('awaiting a plain answer reports its Python type at every call '
          'path', () async {
        await withSession(_plain, (s) async {
          for (final code in ['await f()', 'x = f()\nawait x']) {
            await expectLater(
              s.feedRun(
                code,
                externalLookup: {
                  'f': const MontyHostFunction('f', _plainAnswer),
                },
                printCallback: _ignore,
              ),
              throwsA(notAwaitable),
              reason: code,
            );
          }

          final call =
              await s.feedStart(
                    'await f()',
                    inputs: {
                      'f': const MontyHostFunction('f', _mustNotRun),
                    },
                    printCallback: _ignore,
                  )
                  as FunctionSnapshot;
          expect(call.allowEagerAwait, isTrue);
          await expectLater(
            call.resume(const ExternalReturnValue(plain)),
            throwsA(notAwaitable),
          );
        });
      });

      test('an ordinary call accepts a plain answer', () async {
        await withSession(_plain, (s) async {
          expect(
            await s.feedRun(
              'f()',
              externalLookup: {
                'f': const MontyHostFunction('f', _plainAnswer),
              },
              printCallback: _ignore,
            ),
            plain,
          );
        });
      });

      test('gather rejects a plain answer as not awaitable', () async {
        await withSession(_plain, (s) async {
          await expectLater(
            s.feedRun(
              'import asyncio\nawait asyncio.gather(f())',
              externalLookup: {
                'f': const MontyHostFunction('f', _plainAnswer),
              },
              printCallback: _ignore,
            ),
            throwsA(
              _runtime(
                'TypeError',
                'An asyncio.Future, a coroutine or an awaitable is required',
              ),
            ),
          );
        });
      });
    });

    test('a host function cannot decline through the OS convention', () async {
      await withSession(_plain, (s) async {
        expect(
          await s.feedRun(
            _catchF,
            externalLookup: {
              'f': MontyHostFunction(
                'f',
                (args, kwargs) => throw const OsCallNotHandledException(),
              ),
            },
            printCallback: _ignore,
          ),
          _caught(
            'Exception',
            "Exception('OsCallNotHandledException()')",
            ['OsCallNotHandledException()'],
          ),
        );
      });
    });

    test('host functions are explicit values in inputs, answers and '
        'containers', () async {
      const function = MontyHostFunction('passed', _mustNotRun);
      expect(() => MontyValue.fromDart(_mustNotRun), throwsArgumentError);
      await withSession(_plain, (s) async {
        final call =
            await s.feedStart(
                  'target(f, functions[0])',
                  inputs: {
                    'f': function,
                    'functions': const MontyList([function]),
                  },
                  printCallback: _ignore,
                )
                as FunctionSnapshot;
        expect(
          call.args,
          [const MontyString('passed'), const MontyString('passed')],
        );
        final done =
            await call.resume(const ExternalReturnValue(function))
                as MontyComplete;
        expect(done.output, const MontyString('passed'));
      });
    });

    test(
      'later calls use the current lookup entry for a host function',
      () async {
        var firstCalls = 0;
        var replacementCalls = 0;
        final lookup = <String, MontyValue>{};
        lookup['f'] = MontyHostFunction('initial', (args, kwargs) {
          firstCalls++;
          lookup['f'] = MontyHostFunction(
            'replacement',
            (replacementArgs, replacementKwargs) {
              replacementCalls++;

              return const MontyInt(2);
            },
          );

          return const MontyInt(1);
        });
        await withSession(_plain, (s) async {
          expect(
            await s.feedRun(
              'first = f()\nsecond = f()\n(first, second)',
              externalLookup: lookup,
              printCallback: _ignore,
            ),
            const MontyTuple([MontyInt(1), MontyInt(2)]),
          );
          expect(firstCalls, 1);
          expect(replacementCalls, 1);
        });
      },
    );

    test(
      'a host function runs only from the dispatched lookup entry',
      () async {
        final calls = <String>[];
        await withSession(_plain, (s) async {
          expect(
            await s.feedRun(
              'f()',
              externalLookup: {
                'f': MontyHostFunction('other', (args, kwargs) {
                  calls.add('dispatched');

                  return const MontyInt(1);
                }),
                'other': MontyHostFunction('f', (args, kwargs) {
                  calls.add('named');

                  return const MontyInt(2);
                }),
              },
              printCallback: _ignore,
            ),
            const MontyInt(1),
          );
          expect(calls, ['dispatched']);
        });
      },
    );

    test('rejects invalid builtin proxy inputs and manual answers', () async {
      final invalid = montyStdTypeProxy('function', 'not_a_builtin');
      await withSession(_plain, (s) async {
        await expectLater(
          s.feedRun('1', inputs: {'x': invalid}, printCallback: _ignore),
          throwsArgumentError,
        );
        final snapshot =
            await s.feedStart(
                  'f()',
                  inputs: {
                    'f': const MontyHostFunction('f', _mustNotRun),
                  },
                  printCallback: _ignore,
                )
                as FunctionSnapshot;
        expect(
          () => snapshot.resume(ExternalReturnValue(invalid)),
          throwsArgumentError,
        );
        expect(snapshot.isSpent, isFalse);
      });
    });

    test(
      'a cyclic proxy automatic answer is catchable as ValueError',
      () async {
        const error = "ValueError('Circular reference detected')";
        await withSession(_callHost, (s) async {
          expect(
            await s.feedRun(
              _catchF,
              printCallback: _ignore,
              externalLookup: {
                'f': MontyHostFunction('f', (args, kwargs) => _cyclicProxy()),
              },
            ),
            _caught('ValueError', error, ['Circular reference detected']),
          );
          expect(
            await s.feedRun(
              _catchNow,
              printCallback: _ignore,
              os: (name, args, kwargs) => _cyclicProxy(),
            ),
            _caught('ValueError', error, ['Circular reference detected']),
          );
        });
      },
    );

    test(
      'an uncaught cyclic proxy answer is a runtime error and the '
      'session continues',
      () async {
        await withSession(_callHost, (s) async {
          await expectLater(
            s.feedRun(
              'f()',
              printCallback: _ignore,
              externalLookup: {
                'f': MontyHostFunction('f', (args, kwargs) => _cyclicProxy()),
              },
            ),
            throwsA(_runtime('ValueError', 'Circular reference detected')),
          );
          expect(
            await s.feedRun('6 * 7', printCallback: _ignore),
            const MontyInt(42),
          );
        });
      },
    );

    test(
      'comparing distinct self-containing lists raises RecursionError',
      () async {
        await withSession(_plain, (s) async {
          await expectLater(
            s.feedRun(
              'a = []\n'
              'a.append(a)\n'
              'b = []\n'
              'b.append(b)\n'
              'a == b',
              printCallback: _ignore,
            ),
            throwsA(
              isA<MontyRuntimeError>().having(
                (e) => e.exception.excType,
                'exception type',
                'RecursionError',
              ),
            ),
          );
        });
      },
    );
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

    group('a failure preparing a host answer', () {
      test('feedRun discards the worker and finishes the session', () async {
        await withSession(_plain, (s) async {
          await expectLater(
            s.feedRun(
              'f()',
              printCallback: _ignore,
              externalLookup: {'f': _unanswerable('f')},
            ),
            throwsA(_unreadable),
          );
          await expectLater(s.feedRun('1 + 1'), _finished);
        });
      });

      test('resumeAuto of a call discards the worker and finishes the '
          'session', () async {
        await withSession(_plain, (s) async {
          final call =
              await s.feedStart(
                    'f()',
                    printCallback: _ignore,
                    externalLookup: {'f': _unanswerable('f')},
                  )
                  as FunctionSnapshot;
          await expectLater(call.resumeAuto(), throwsA(_unreadable));
          await expectLater(s.feedRun('1 + 1'), _finished);
        });
      });

      test('resumeAuto of futures discards the worker and finishes the '
          'session', () async {
        await withSession(_plain, (s) async {
          final call =
              await s.feedStart(
                    'import asyncio\nawait asyncio.gather(f())',
                    printCallback: _ignore,
                    externalLookup: {'f': _unanswerable('f', async: true)},
                  )
                  as FunctionSnapshot;
          final waiting = await call.resumeAuto() as FutureSnapshot;
          await expectLater(waiting.resumeAuto(), throwsA(_unreadable));
          await expectLater(s.feedRun('1 + 1'), _finished);
        });
      });
    });
  });
}
