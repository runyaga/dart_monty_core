// Exception attributes and the writer's refusals against a real worker
// (C3-4). The expected values are upstream's (pydantic-monty 1.1.0) for the
// same code and values. Shared by the VM harness
// (test/integration/worker/monty_snapshot_io_test.dart) and the Chrome one
// (pool_session_web_test.dart), so vm, dart2js and dart2wasm run the same
// cases.
import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/exception_attributes.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/host_answers.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/pool_session.dart';
import 'package:test/test.dart';

/// Runs a test body with a session on a one-worker pool.
typedef WithSession =
    Future<void> Function(
      Future<void> Function(MontySession s) body,
    );

void _ignore(String stream, String text) => _ignored++;

/// How many prints [_ignore] dropped; never looked at.
var _ignored = 0;

/// A list that contains itself.
MontyList _cyclic() {
  final items = <MontyValue>[];
  final list = MontyList(items);
  items.add(list);

  return list;
}

const String _surrogateText =
    r"'utf-8' codec can't encode character '\ud800' in position 0: "
    'surrogates not allowed';

/// A `json.JSONDecodeError` as upstream's host reports `json.loads('[1, }')`.
const ExternalException _jsonError = ExternalException(
  'json.JSONDecodeError',
  'Expecting value: line 1 column 5 (char 4)',
  {
    'msg': MontyString('Expecting value'),
    'doc': MontyString('[1, }'),
    'pos': MontyInt(4),
    'lineno': MontyInt(1),
    'colno': MontyInt(5),
  },
);

/// A cycle refused at the caller, as upstream's binding raises it.
final Matcher _throwsCircular = throwsA(
  _runtime('ValueError: Circular reference detected'),
);

Matcher _runtime(String message, {String? excType}) => isA<MontyRuntimeError>()
    .having((e) => e.toString(), 'message', message)
    .having(
      (e) => e.exception.excType,
      'excType',
      excType ?? message.substring(0, message.indexOf(':')),
    );

/// The error [future] fails with.
Future<MontyError> _failure(Future<Object?> future) async {
  try {
    await future;
  } on MontyError catch (e) {
    return e;
  }
  fail('no MontyError');
}

Map<String, MontyValue> _attrs(MontyError e) =>
    exceptionAttributes(e.exception);

/// The C3-4 cases, labelled with [label], each in a session [withSession]
/// gives.
void attributeSessionTests(String label, WithSession withSession) {
  group('exception attributes ($label)', () {
    test('a decode error raised in the sandbox carries its data', () async {
      await withSession((s) async {
        final e = await _failure(
          s.feedRun(r"b'a\xff'.decode()", printCallback: _ignore),
        );
        expect(
          e.toString(),
          "UnicodeDecodeError: 'utf-8' codec can't decode byte 0xff in "
          'position 1: invalid start byte',
        );
        expect(e.exception.excType, 'UnicodeDecodeError');
        expect(_attrs(e), {
          'encoding': const MontyString('utf-8'),
          'object': MontyBytes(Uint8List.fromList([0x61, 0xff])),
          'start': const MontyInt(1),
          'end': const MontyInt(2),
          'reason': const MontyString('invalid start byte'),
        });
      });
    });

    test('a JSON error raised in the sandbox carries its data', () async {
      await withSession((s) async {
        final e = await _failure(
          s.feedRun(
            'import json\njson.loads(\'{"a": x}\')',
            printCallback: _ignore,
          ),
        );
        expect(
          e.toString(),
          'json.JSONDecodeError: Expecting value: line 1 column 7 (char 6)',
        );
        expect(e.exception.excType, 'json.JSONDecodeError');
        expect(_attrs(e), {
          'msg': const MontyString('Expecting value'),
          'doc': const MontyString('{"a": x}'),
          'pos': const MontyInt(6),
          'lineno': const MontyInt(1),
          'colno': const MontyInt(7),
        });
      });
    });

    test(
      'raised manually, without data: ValueError, the type rendered',
      () async {
        await withSession((s) async {
          for (final (code, rendered) in [
            ("raise UnicodeDecodeError('x')", 'UnicodeDecodeError: x'),
            ("raise UnicodeEncodeError('y')", 'UnicodeEncodeError: y'),
            (
              "import json\nraise json.JSONDecodeError('z')",
              'json.JSONDecodeError: z',
            ),
          ]) {
            final e = await _failure(s.feedRun(code, printCallback: _ignore));
            expect(e.exception.excType, 'ValueError', reason: code);
            expect(_attrs(e), isEmpty, reason: code);
            expect((e as MontyRuntimeError).display('type-msg'), rendered);
          }
        });
      },
    );

    test('a JSON error answered by a manual resume round-trips', () async {
      await withSession((s) async {
        final snap =
            await s.feedStart('f()', printCallback: _ignore)
                as FunctionSnapshot;
        final e = await _failure(snap.resume(_jsonError));
        expect(
          e.toString(),
          'json.JSONDecodeError: Expecting value: line 1 column 5 (char 4)',
        );
        expect(e.exception.excType, 'json.JSONDecodeError');
        expect(_attrs(e), _jsonError.attributes);
      });
    });

    test('a JSON error settling a future round-trips', () async {
      await withSession((s) async {
        final call =
            await s.feedStart('await f()', printCallback: _ignore)
                as FunctionSnapshot;
        final wait =
            await call.resume(const ExternalFuture()) as FutureSnapshot;
        final e = await _failure(wait.resume({call.callId: _jsonError}));
        expect(_attrs(e), _jsonError.attributes);
      });
    });

    test('a JSON error thrown by a host function: the sandbox catches it, '
        'and uncaught it round-trips', () async {
      await withSession((s) async {
        Never f(List<MontyValue> _, Map<String, MontyValue> _) =>
            throw _jsonError;
        final caught = await s.feedRun(
          'try:\n  f()\nexcept ValueError as e:\n'
          '  r = (type(e).__name__, str(e))\nr',
          externals: {'f': f},
          printCallback: _ignore,
        );
        expect(
          caught,
          const MontyTuple([
            MontyString('JSONDecodeError'),
            MontyString('Expecting value: line 1 column 5 (char 4)'),
          ]),
        );
        final e = await _failure(
          s.feedRun('f()', externals: {'f': f}, printCallback: _ignore),
        );
        expect(_attrs(e), _jsonError.attributes);
      });
    });

    test('answered with no, mistyped or oversized data', () async {
      await withSession((s) async {
        Future<MontyError> answer(ExternalException result) async {
          final snap =
              await s.feedStart('f()', printCallback: _ignore)
                  as FunctionSnapshot;

          return _failure(snap.resume(result));
        }

        final none = await answer(
          const ExternalException('json.JSONDecodeError', 'm'),
        );
        expect(none.exception.excType, 'ValueError');
        expect(none.toString(), 'json.JSONDecodeError: m');
        final mistyped = await answer(
          ExternalException('json.JSONDecodeError', 'm', {
            ..._jsonError.attributes,
            'pos': const MontyString('4'),
          }),
        );
        expect(mistyped.exception.excType, 'ValueError');
        // A 70 KiB document is dropped; the location is kept.
        final big = await answer(
          ExternalException('json.JSONDecodeError', 'm', {
            ..._jsonError.attributes,
            'doc': MontyString('x' * (70 * 1024)),
          }),
        );
        expect(big.exception.excType, 'json.JSONDecodeError');
        expect(_attrs(big), {
          ..._jsonError.attributes,
          'doc': const MontyString(''),
        });
      });
    });

    test(
      "a Unicode error's attributes are not sent: ValueError back",
      () async {
        await withSession((s) async {
          final snap =
              await s.feedStart('f()', printCallback: _ignore)
                  as FunctionSnapshot;
          const message =
              "'utf-8' codec can't decode byte 0xff in position 0: "
              'invalid start byte';
          final e = await _failure(
            snap.resume(
              const ExternalException('UnicodeDecodeError', message, {
                'encoding': MontyString('utf-8'),
                'object': MontyBytes([0xff]),
                'start': MontyInt(0),
                'end': MontyInt(1),
                'reason': MontyString('invalid start byte'),
              }),
            ),
          );
          expect(e.exception.excType, 'ValueError');
          expect(_attrs(e), isEmpty);
          expect(
            (e as MontyRuntimeError).display('type-msg'),
            'UnicodeDecodeError: $message',
          );
        });
      },
    );
  });

  group('writer refusals, by path ($label)', () {
    test(
      "inputs: the call throws upstream's error; the session runs on",
      () async {
        await withSession((s) async {
          expect(
            s.feedRun('x', inputs: {'x': _cyclic()}, printCallback: _ignore),
            _throwsCircular,
          );
          // The surrogate's error has no data, so it reads as ValueError.
          await expectLater(
            s.feedRun(
              'x',
              inputs: {'x': const MontyString('\uD800')},
              printCallback: _ignore,
            ),
            throwsA(
              _runtime(
                'UnicodeEncodeError: $_surrogateText',
                excType: 'ValueError',
              ),
            ),
          );
          await expectLater(
            s.feedStart(
              'x',
              inputs: {
                'x': const MontyList([MontyString('a\uD800\uD801b')]),
              },
              printCallback: _ignore,
            ),
            throwsA(
              _runtime(
                "UnicodeEncodeError: 'utf-8' codec can't encode characters in "
                'position 1-2: surrogates not allowed',
                excType: 'ValueError',
              ),
            ),
          );
          // A value Python cannot build: ArgumentError.
          await expectLater(
            s.feedRun(
              'x',
              inputs: {
                'x': const MontyBytes([256]),
              },
              printCallback: _ignore,
            ),
            throwsArgumentError,
          );
          expect(
            await s.feedRun('1 + 1', printCallback: _ignore),
            const MontyInt(2),
          );
        });
      },
    );

    test('a manual resume throws; the snapshot stays retryable', () async {
      await withSession((s) async {
        final call =
            await s.feedStart('f()', printCallback: _ignore)
                as FunctionSnapshot;
        await expectLater(
          () => call.resume(ExternalReturnValue(_cyclic())),
          _throwsCircular,
        );
        await expectLater(
          () => call.resume(const ExternalReturnValue(MontyString('\uD800'))),
          throwsA(
            _runtime(
              'UnicodeEncodeError: $_surrogateText',
              excType: 'ValueError',
            ),
          ),
        );
        expect(call.isSpent, isFalse);
        final done =
            await call.resume(const ExternalReturnValue(MontyInt(1)))
                as MontyComplete;
        expect(done.output, const MontyInt(1));

        final lookup =
            await s.feedStart('v', printCallback: _ignore)
                as NameLookupSnapshot;
        await expectLater(
          () => lookup.resume(value: _cyclic()),
          _throwsCircular,
        );
        expect(lookup.isSpent, isFalse);
        final looked =
            await lookup.resume(value: const MontyInt(3)) as MontyComplete;
        expect(looked.output, const MontyInt(3));

        final started =
            await s.feedStart('await f()', printCallback: _ignore)
                as FunctionSnapshot;
        final wait =
            await started.resume(const ExternalFuture()) as FutureSnapshot;
        await expectLater(
          () => wait.resume({started.callId: ExternalReturnValue(_cyclic())}),
          _throwsCircular,
        );
        expect(wait.isSpent, isFalse);
        final settled =
            await wait.resume({
                  started.callId: const ExternalReturnValue(MontyInt(4)),
                })
                as MontyComplete;
        expect(settled.output, const MontyInt(4));
      });
    });

    test('an automatic answer raises it in the sandbox', () async {
      await withSession((s) async {
        MontyValue cyclic(List<MontyValue> _, Map<String, MontyValue> _) =>
            _cyclic();
        MontyValue surrogate(List<MontyValue> _, Map<String, MontyValue> _) =>
            const MontyString('\uD800');
        expect(
          await s.feedRun(
            "try:\n  f()\nexcept ValueError as e:\n  r = 'caught ' + str(e)\nr",
            externals: {'f': cyclic},
            printCallback: _ignore,
          ),
          const MontyString('caught Circular reference detected'),
        );
        expect(
          await s.feedRun(
            'try:\n  f()\nexcept Exception as e:\n'
            "  r = type(e).__name__ + ' ' + str(e)\nr",
            externals: {'f': surrogate},
            printCallback: _ignore,
          ),
          const MontyString('UnicodeEncodeError $_surrogateText'),
        );
        await expectLater(
          s.feedRun('f()', externals: {'f': cyclic}, printCallback: _ignore),
          _throwsCircular,
        );
        // A coroutine's value is answered the same way.
        expect(
          await s.feedRun(
            'try:\n  await g()\nexcept ValueError as e:\n  r = str(e)\nr',
            externals: {'g': coroutine((_, _) async => _cyclic())},
            printCallback: _ignore,
          ),
          const MontyString('Circular reference detected'),
        );
        // A value Python cannot build is a throw from the host function.
        expect(
          await s.feedRun(
            "try:\n  f()\nexcept Exception:\n  r = 'caught'\nr",
            externals: {
              'f': (_, _) => const MontyBytes([256]),
            },
            printCallback: _ignore,
          ),
          const MontyString('caught'),
        );
        expect(
          await s.feedRun('1 + 1', printCallback: _ignore),
          const MontyInt(2),
        );
      });
    });

    test('resumeAuto answers the same way', () async {
      await withSession((s) async {
        final call =
            await s.feedStart(
                  'f()',
                  externals: {'f': (_, _) => _cyclic()},
                  printCallback: _ignore,
                )
                as FunctionSnapshot;
        await expectLater(
          call.resumeAuto(),
          _throwsCircular,
        );
        expect(
          await s.feedRun('2 + 2', printCallback: _ignore),
          const MontyInt(4),
        );
      });
    });
  });
}
