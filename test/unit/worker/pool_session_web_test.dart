// Monty and its sessions against the COMMITTED
// lib/assets/dart_monty_core_worker.{js,wasm} in Chrome, on dart2js and
// dart2wasm, with no workerLocation: the channel factory finds the assets
// itself.
//
//   bash tool/test_worker_web.sh
@TestOn('browser')
@Tags(['worker'])
library;

import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:dart_monty_core/dart_monty_core.dart'
    hide MontyError, MontySyntaxError, MontyTypingError;
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_attribute_cases.dart';
import '_config_cases.dart';
import '_cwd_cases.dart';
import '_host_cases.dart';
import '_host_code_cases.dart';
import '_os_handler_cases.dart';
import '_print_cases.dart';
import '_restore_cases.dart';
import '_session_cases.dart';

const _backend = identical(1, 1.0) ? 'dart2js' : 'dart2wasm';

/// Every session's memory is bounded.
const _limits = SessionConfig(
  limits: ResourceLimits(maxMemory: 64 * 1024 * 1024),
);

/// What a test passes as `printCallback` when it does not look at prints.
void _ignore(String stream, String text) => _ignored++;

/// How many prints [_ignore] dropped; never looked at.
var _ignored = 0;

@JS('console')
external JSObject get _console;

/// Replaces `console.log` and `console.error` until the test ends, and
/// returns what each receives.
(List<String>, List<String>) _captureConsole() {
  final logged = <String>[];
  final errored = <String>[];
  final log = _console['log'];
  final error = _console['error'];
  _console['log'] = ((JSAny? text) => logged.add('${text.dartify()}')).toJS;
  _console['error'] = ((JSAny? text) => errored.add('${text.dartify()}')).toJS;
  addTearDown(() {
    _console['log'] = log;
    _console['error'] = error;
  });

  return (logged, errored);
}

void main() {
  configOracleTests(
    _backend,
    () => startMonty(const PoolOptions(maxProcesses: 1)),
  );
  restoreOracleTests(
    _backend,
    startMonty,
  );
  hostOracleTests(
    _backend,
    startMonty,
  );
  printOracleTests(
    _backend,
    startMonty,
  );
  osHandlerOracleTests(_backend, startMonty);

  test(
    'workerPid is null: a Web Worker has no process id ($_backend)',
    () async {
      await withMonty(
        (pool) => pool.withSessionWith((s) async {
          expect(
            await s.feedRun('1', printCallback: _ignore),
            const MontyInt(1),
          );
          expect(s.workerPid, isNull);
        }, _limits),
        const PoolOptions(maxProcesses: 1),
      );
    },
  );
  attributeSessionTests(
    _backend,
    (body) => withMonty(
      (pool) => pool.withSessionWith(body, _limits),
      const PoolOptions(maxProcesses: 1),
    ),
  );
  hostCodeSessionTests(
    _backend,
    (config, body) => withMonty(
      (pool) => pool.withSessionWith(body, config),
      const PoolOptions(maxProcesses: 1),
    ),
  );
  cwdSessionTests(
    _backend,
    (body) => withMonty(
      (pool) => pool.withSessionWith(body, _limits),
      const PoolOptions(maxProcesses: 1),
    ),
  );
  sessionSurfaceTests(
    _backend,
    (body) => withMonty(
      (pool) => pool.withSessionWith(body, _limits),
      const PoolOptions(maxProcesses: 1),
    ),
  );
  sessionSurfacePoolTests(
    _backend,
    (body) => withMonty(body, const PoolOptions(maxProcesses: 1)),
  );

  test('feedRun, prints in order, Reset on close, reuse ($_backend)', () async {
    final pool = await startMonty(
      const PoolOptions(
        maxProcesses: 1,
      ),
    );
    try {
      final prints = <(String, String)>[];
      final value = await pool.withSessionWith(
        (s) => s.feedRun(
          "import sys\nprint('one')\nprint('two', file=sys.stderr)\n"
          'x = 41\nx + 1',
          printCallback: (stream, text) async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            prints.add((stream, text));
          },
        ),
        _limits,
      );
      expect(value, const MontyInt(42));
      expect(prints.map((p) => p.$2).join(), 'one\ntwo\n');
      expect(prints.map((p) => p.$1).toSet(), {'stdout', 'stderr'});
      expect(pool.idleWorkers, 1);
      await pool.withSessionWith(
        (s) async {
          await expectLater(
            s.feedRun('x', printCallback: _ignore),
            throwsA(
              isA<MontyRuntimeError>().having(
                (e) => e.exception.excType,
                'excType',
                'NameError',
              ),
            ),
          );
        },
        _limits,
      );
      expect(pool.liveWorkers, 1);
    } finally {
      await pool.close();
    }
    expect(pool.liveWorkers, 0);
  });

  test('close during host code: Reset now ($_backend)', () async {
    await withMonty(
      (pool) async {
        final session = await pool.checkoutWith(
          _limits,
        );
        final entered = Completer<void>();
        final release = Completer<MontyValue>();
        final run = session.feedRun(
          'host()',
          externalLookup: {
            'host': MontyHostFunction('host', (args, kwargs) {
              entered.complete();

              return release.future;
            }),
          },
          printCallback: _ignore,
        );
        final failed = expectLater(run, throwsA(isA<StateError>()));
        await entered.future;
        await session.close();
        // The call fails with the close; the callback has not returned.
        await failed.timeout(const Duration(seconds: 5));
        expect(pool.idleWorkers, 1);
        release.complete(const MontyInt(1));
        expect(
          await pool.withSessionWith(
            (s) => s.feedRun('7', printCallback: _ignore),
            _limits,
          ),
          const MontyInt(7),
        );
      },
      const PoolOptions(
        maxProcesses: 1,
      ),
    );
  });

  test('requestTimeout ends a turn that runs on ($_backend)', () async {
    await withMonty(
      (pool) async {
        final session = await pool.checkoutWith(
          _limits,
        );
        await expectLater(
          session.feedRun('while True:\n    pass', printCallback: _ignore),
          throwsA(
            isA<MontyCrashedError>()
                .having((e) => e.cause, 'cause', CrashCause.killed)
                // Upstream's MontyCrashedError for a request_timeout kill.
                .having((e) => e.timedOut, 'timedOut', isTrue)
                .having((e) => e.exitStatus, 'exitStatus', isNull)
                .having(
                  (e) => e.toString(),
                  'message',
                  'monty worker killed after exceeding request '
                      'timeout of 1s',
                )
                .having(
                  (e) => e.exception,
                  'exception',
                  MontyExceptionValue(
                    'RuntimeError',
                    'monty worker killed after exceeding request '
                        'timeout of 1s',
                  ),
                ),
          ),
        );
        expect(pool.liveWorkers, 0);
        expect(
          await pool.withSessionWith(
            (s) => s.feedRun('1 + 1', printCallback: _ignore),
            _limits,
          ),
          const MontyInt(2),
        );
      },
      const PoolOptions(
        maxProcesses: 1,
        requestTimeout: Duration(seconds: 1),
      ),
    );
  });

  test('time.sleep is waited by the session ($_backend)', () async {
    await withMonty(
      (pool) async {
        final clock = Stopwatch()..start();
        final value = await pool.withSessionWith(
          (s) => s.feedRun(
            'import time\ntime.sleep(0.05)\n7',
            printCallback: _ignore,
          ),
          _limits,
        );
        expect(value, const MontyInt(7));
        expect(
          clock.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 45)),
        );
      },
      const PoolOptions(
        maxProcesses: 1,
      ),
    );
  });

  test(
    'past 1000 host calls the feed fails in the sandbox ($_backend)',
    () async {
      await withMonty(
        (pool) async {
          final session = await pool.checkoutWith(
            _limits,
          );
          var calls = 0;
          await expectLater(
            session.feedRun(
              'while True:\n    f()',
              externalLookup: {
                'f': MontyHostFunction(
                  'f',
                  (args, kwargs) => MontyInt(++calls),
                ),
              },
              printCallback: _ignore,
            ),
            throwsA(
              isA<MontyRuntimeError>()
                  .having((e) => e.exception.excType, 'excType', 'RuntimeError')
                  .having((e) => e.toString(), 'message', contains('1000')),
            ),
          );
          expect(calls, lessThanOrEqualTo(1000));
          expect(
            await session.feedRun('calls_left = 1', printCallback: _ignore),
            const MontyNone(),
          );
          await session.close();
        },
        const PoolOptions(
          maxProcesses: 1,
        ),
      );
    },
  );

  test(
    'a type-checking session rejects a mistyped snippet ($_backend)',
    () async {
      await withMonty(
        (pool) => pool.withSessionWith(
          (s) async {
            await expectLater(
              s.feedRun('x: int = "a"', printCallback: _ignore),
              throwsA(isA<MontyTypingError>()),
            );
            expect(
              await s.feedRun('y: int = 2\ny', printCallback: _ignore),
              const MontyInt(2),
            );
          },
          const SessionConfig(
            limits: ResourceLimits(maxMemory: 64 * 1024 * 1024),
            typeCheck: true,
          ),
        ),
        const PoolOptions(
          maxProcesses: 1,
        ),
      );
    },
  );

  test('no print callback: each fragment reaches the console on its '
      'stream ($_backend)', () async {
    final (logged, errored) = _captureConsole();
    await withMonty(
      (pool) => pool.withSessionWith(
        (s) => s.feedRun(
          "print('a', end='')\nprint('b')\nimport sys\n"
          "print('e', file=sys.stderr)\n",
        ),
        _limits,
      ),
      const PoolOptions(
        maxProcesses: 1,
      ),
    );
    expect(logged.join(), 'ab\n');
    expect(errored.join(), 'e\n');
  });
  group('print failure (upstream binding)', () {
    test('then completion: the failure wins, the session runs on '
        '($_backend)', () async {
      await withMonty(
        (pool) => pool.withSessionWith(
          (s) async {
            final seen = <String>[];
            await expectLater(
              s.feedRun(
                "print('a')\nprint('b')\nx = 41\nx + 1",
                printCallback: (stream, text) {
                  seen.add(text);
                  throw StateError('sink');
                },
              ),
              throwsA(
                isA<MontyRuntimeError>().having(
                  (e) => e.display('type-msg'),
                  "display('type-msg')",
                  'Exception: Bad state: sink',
                ),
              ),
            );
            expect(seen, hasLength(1));
            expect(
              await s.feedRun('x', printCallback: _ignore),
              const MontyInt(41),
            );
          },
          _limits,
        ),
        const PoolOptions(maxProcesses: 1),
      );
    });

    test('then a suspension: the session is discarded ($_backend)', () async {
      await withMonty(
        (pool) async {
          final session = await pool.checkoutWith(_limits);
          var calls = 0;
          await expectLater(
            session.feedRun(
              "print('a')\nf()\n7",
              externalLookup: {
                'f': MontyHostFunction(
                  'f',
                  (args, kwargs) => MontyInt(++calls),
                ),
              },
              printCallback: (stream, text) => throw StateError('sink'),
            ),
            throwsA(
              isA<MontyRuntimeError>().having(
                (e) => e.display('type-msg'),
                "display('type-msg')",
                'Exception: Bad state: sink',
              ),
            ),
          );
          expect(calls, 0);
          expect(pool.liveWorkers, 0);
          await expectLater(
            session.feedRun('1', printCallback: _ignore),
            throwsA(isA<StateError>()),
          );
          await session.close();
          expect(
            await pool.withSessionWith(
              (s) => s.feedRun('2', printCallback: _ignore),
              _limits,
            ),
            const MontyInt(2),
          );
        },
        const PoolOptions(maxProcesses: 1),
      );
    });
  });

  group('print stall (gate)', () {
    for (final byClose in [false, true]) {
      final how = byClose ? 'close' : 'requestTimeout';
      test('a callback that never completes, ended by $how: the call '
          'fails, the slot serves a new checkout ($_backend)', () async {
        await withMonty(
          (pool) async {
            final session = await pool.checkoutWith(_limits);
            final entered = Completer<void>();
            final never = Completer<void>();
            final run = session.feedRun(
              "print('x')\n1",
              printCallback: (stream, text) {
                if (!entered.isCompleted) entered.complete();

                return never.future;
              },
            );
            final failed = expectLater(
              run,
              throwsA(
                isA<MontyCrashedError>().having(
                  (e) => e.cause,
                  'cause',
                  CrashCause.killed,
                ),
              ),
            );
            await entered.future;
            if (byClose) await session.close();
            await failed.timeout(const Duration(seconds: 10));
            expect(pool.liveWorkers, 0);
            expect(
              await pool.withSessionWith(
                (s) => s.feedRun('1 + 1', printCallback: _ignore),
                _limits,
              ),
              const MontyInt(2),
            );
            never.complete();
            await session.close();
          },
          PoolOptions(
            maxProcesses: 1,
            requestTimeout: byClose ? null : const Duration(seconds: 1),
          ),
        );
      });
    }
  });

  group('close while busy (q8 gates)', () {
    test('during a turn, after feedRun(...).timeout: close ends it '
        '($_backend)', () async {
      await withMonty(
        (pool) async {
          final session = await pool.checkoutWith(_limits);
          await expectLater(
            session
                .feedRun('while True:\n    pass', printCallback: _ignore)
                .timeout(const Duration(milliseconds: 300)),
            throwsA(isA<TimeoutException>()),
          );
          await session.close().timeout(const Duration(seconds: 5));
          expect(pool.liveWorkers, 0);
          expect(
            await pool.withSessionWith(
              (s) => s.feedRun('4', printCallback: _ignore),
              _limits,
            ),
            const MontyInt(4),
          );
        },
        const PoolOptions(maxProcesses: 1),
      );
    });

    test('during an unresolved host call: the call fails at once, close '
        'returns, the worker is reset and reused ($_backend)', () async {
      await withMonty(
        (pool) async {
          final session = await pool.checkoutWith(_limits);
          final entered = Completer<void>();
          final run = session.feedRun(
            'x = 1\nnever()',
            externalLookup: {
              'never': MontyHostFunction('never', (args, kwargs) {
                entered.complete();

                return Completer<MontyValue>().future;
              }),
            },
            printCallback: _ignore,
          );
          await entered.future;
          final failed = expectLater(run, throwsA(isA<StateError>()));
          await session.close().timeout(const Duration(seconds: 5));
          // The pending call fails at once; the callback never returns.
          await failed.timeout(const Duration(seconds: 5));
          expect(pool.idleWorkers, 1);
          await pool.withSessionWith(
            (s) async {
              await expectLater(
                s.feedRun('x', printCallback: _ignore),
                throwsA(isA<MontyRuntimeError>()),
              );
            },
            _limits,
          );
          expect(pool.liveWorkers, 1);
        },
        const PoolOptions(maxProcesses: 1),
      );
    });

    test('twice: the second close is a no-op ($_backend)', () async {
      await withMonty(
        (pool) async {
          final session = await pool.checkoutWith(_limits);
          final run = session.feedRun(
            'while True:\n    pass',
            printCallback: _ignore,
          );
          final failed = expectLater(run, throwsA(isA<MontyCrashedError>()));
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await Future.wait([session.close(), session.close()]);
          await session.close();
          await failed;
          expect(pool.liveWorkers, 0);
          expect(
            await pool.withSessionWith(
              (s) => s.feedRun('5', printCallback: _ignore),
              _limits,
            ),
            const MontyInt(5),
          );
        },
        const PoolOptions(maxProcesses: 1),
      );
    });
  });

  // The outbound outcomes are not repeated here: a real 257 MiB value is
  // seconds of synchronous work in the page, which starves the other suites
  // sharing the browser. The session's outcomes run on dart2js and dart2wasm
  // in pool_session_test.dart, and the Worker channel's own refusal before
  // posting in worker_connection_test.dart.
}
