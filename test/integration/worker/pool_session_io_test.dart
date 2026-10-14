// MontyPool and its sessions against the real worker executable
// (tool/build_worker.sh, or the CI artefact), and against the fake worker
// for the memory-limit exit: the session path end to end on the VM.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart'
    hide MontyError, MontySyntaxError, MontyTypingError;
import 'package:dart_monty_core/src/worker/frame.dart' as wire;
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '../../unit/worker/_config_cases.dart';
import '../../unit/worker/_host_cases.dart';
import '../../unit/worker/_restore_cases.dart';
import '_worker_harness.dart';

/// Every session's memory is bounded.
const _limits = SessionConfig(
  limits: ResourceLimits(maxMemory: 64 * 1024 * 1024),
);

/// What a test passes as `printCallback` when it does not look at prints.
void _ignore(String stream, String text) => _ignored++;

/// How many prints [_ignore] dropped; never looked at.
var _ignored = 0;

/// Above [_runProbe]'s own 60 s, so its kill and message come first.
const _probeTimeout = Timeout(Duration(seconds: 90));

/// Runs the probe program [name] with the worker's path; its exit code,
/// stdout and stderr. A probe still running after 60 s is killed and fails
/// the test; the test's own teardown kills it too, so a probe that cannot
/// exit never outlives its test, whichever timeout fires first. Tests that
/// run a probe set a timeout above 60 s.
///
/// With [drainStdout] false the probe's stdout is never read, so its pipe
/// fills; the returned stdout is then empty.
Future<(int, String, String)> _runProbe(
  String name, {
  bool drainStdout = true,
  List<String> vmArgs = const [],
}) async {
  final probe = await Process.start(Platform.resolvedExecutable, [
    ...vmArgs,
    File('test/integration/worker/$name').absolute.path,
    await _workerPath(),
  ]);
  addTearDown(() async {
    probe.kill(ProcessSignal.sigkill);
    await probe.exitCode;
  });
  final out = drainStdout
      ? probe.stdout.transform(utf8.decoder).join()
      : Future.value('');
  final err = probe.stderr.transform(utf8.decoder).join();
  try {
    final code = await probe.exitCode.timeout(const Duration(seconds: 60));

    return (code, await out, await err);
  } on TimeoutException {
    probe.kill(ProcessSignal.sigkill);
    await probe.exitCode;
    fail('$name did not exit within 60 s; stderr: ${await err}');
  }
}

/// [worker]'s read-ahead once reading has paused at the limit (the frame in
/// flight at the limit completed), polled for up to 4 s.
Future<int> _filled(ProcessChannel worker) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!worker.readAhead.paused ||
      worker.readAhead.now < ProcessChannel.readAheadLimit) {
    if (DateTime.now().isAfter(deadline)) {
      fail('reading never paused at the limit: ${worker.readAhead.now}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  return worker.readAhead.now;
}

Future<String> _workerPath() async =>
    ((await realWorker()) as WorkerExecutable).path;

void main() {
  expectNoWorkersLeftAfterEachTest();

  configOracleTests(
    'vm',
    () => MontyPool.start(options: const PoolOptions(maxProcesses: 1)),
  );
  restoreOracleTests('vm', (options) => MontyPool.start(options: options));
  hostOracleTests('vm', (options) => MontyPool.start(options: options));

  test('feedRun, prints in order, Reset on close, the worker reused', () async {
    await MontyPool.withPool(
      (pool) async {
        final prints = <(String, String)>[];
        final value = await pool.withSession(
          (s) => s.feedRun(
            "import sys\nprint('one')\nprint('two', file=sys.stderr)\n"
            'x = 41\nx + 1',
            printCallback: (stream, text) async {
              // Each callback finishes before the next starts.
              await Future<void>.delayed(const Duration(milliseconds: 20));
              prints.add((stream, text));
            },
          ),
          options: _limits,
        );
        expect(value, const MontyInt(42));
        expect(prints.map((p) => p.$1).toSet(), {'stdout', 'stderr'});
        expect(prints.map((p) => p.$2).join(), 'one\ntwo\n');
        expect(pool.idleWorkers, 1);
        final worker = onlyItem(ProcessChannel.live);

        // The same process, reset: the global is gone.
        await pool.withSession(
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
            // The session runs on after an in-band error.
            expect(
              await s.feedRun('2 * 3', printCallback: _ignore),
              const MontyInt(6),
            );
          },
          options: _limits,
        );
        expect(ProcessChannel.live, [worker]);
      },
      options: PoolOptions(
        maxProcesses: 1,
        workerLocation: await _workerPath(),
      ),
    );
  });

  test('close during host code: Reset now, the call fails at once', () async {
    await MontyPool.withPool(
      (pool) async {
        final session = await pool.checkout(
          options: _limits,
        );
        final entered = Completer<void>();
        final release = Completer<MontyValue>();
        final run = session.feedRun(
          'host()',
          externals: {
            'host': (args, kwargs) {
              entered.complete();

              return release.future;
            },
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
        // The worker took its Reset and serves the next session.
        expect(
          await pool.withSession(
            (s) => s.feedRun('7', printCallback: _ignore),
            options: _limits,
          ),
          const MontyInt(7),
        );
      },
      options: PoolOptions(
        maxProcesses: 1,
        workerLocation: await _workerPath(),
      ),
    );
  });

  test(
    'requestTimeout kills a turn that runs on; the slot is reused',
    () async {
      await MontyPool.withPool(
        (pool) async {
          final session = await pool.checkout(
            options: _limits,
          );
          final first = onlyItem(ProcessChannel.live);
          await expectLater(
            session.feedRun('while True:\n    pass', printCallback: _ignore),
            throwsA(
              isA<MontyCrashedError>()
                  .having((e) => e.cause, 'cause', CrashCause.killed)
                  // Upstream's MontyCrashedError for a request_timeout kill.
                  .having((e) => e.timedOut, 'timedOut', isTrue)
                  .having((e) => e.exitStatus, 'exitStatus', isNull)
                  .having(
                    (e) => e.message,
                    'message',
                    'monty worker killed after exceeding request '
                        'timeout of 500ms',
                  )
                  .having(
                    (e) => e.exception,
                    'exception',
                    const MontyExceptionValue(
                      excType: 'RuntimeError',
                      message:
                          'monty worker killed after exceeding request '
                          'timeout of 500ms',
                    ),
                  ),
            ),
          );
          await first.exitCode.timeout(const Duration(seconds: 5));
          await session.close();
          expect(pool.liveWorkers, 0);
          expect(
            await pool.withSession(
              (s) => s.feedRun('1 + 1', printCallback: _ignore),
              options: _limits,
            ),
            const MontyInt(2),
          );
        },
        options: PoolOptions(
          maxProcesses: 1,
          requestTimeout: const Duration(milliseconds: 500),
          workerLocation: await _workerPath(),
        ),
      );
    },
  );

  test(
    'within the feed backstop the sandbox raises TimeoutError itself',
    () async {
      await MontyPool.withPool(
        (pool) async {
          final session = await pool.checkout(
            options: const SessionConfig(
              limits: ResourceLimits(
                maxMemory: 64 * 1024 * 1024,
                maxFeedDuration: Duration(milliseconds: 200),
              ),
            ),
          );
          // The sandbox raises TimeoutError itself, within its budget.
          await expectLater(
            session.feedRun('while True:\n    pass', printCallback: _ignore),
            throwsA(
              isA<MontyRuntimeError>().having(
                (e) => e.exception.excType,
                'excType',
                'TimeoutError',
              ),
            ),
          );
          await session.close();
        },
        options: PoolOptions(
          maxProcesses: 1,
          workerLocation: await _workerPath(),
        ),
      );
    },
  );

  test('time.sleep is waited by the session', () async {
    await MontyPool.withPool(
      (pool) async {
        final clock = Stopwatch()..start();
        final value = await pool.withSession(
          (s) => s.feedRun(
            'import time\ntime.sleep(0.05)\n7',
            printCallback: _ignore,
          ),
          options: _limits,
        );
        expect(value, const MontyInt(7));
        expect(
          clock.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 45)),
        );
      },
      options: PoolOptions(
        maxProcesses: 1,
        workerLocation: await _workerPath(),
      ),
    );
  });

  test('past 1000 host calls the feed fails in the sandbox', () async {
    await MontyPool.withPool(
      (pool) async {
        final session = await pool.checkout(
          options: _limits,
        );
        var calls = 0;
        await expectLater(
          session.feedRun(
            'while True:\n    f()',
            externals: {'f': (args, kwargs) => MontyInt(++calls)},
            printCallback: _ignore,
          ),
          throwsA(
            isA<MontyRuntimeError>()
                .having((e) => e.exception.excType, 'excType', 'RuntimeError')
                .having((e) => e.message, 'message', contains('1000')),
          ),
        );
        expect(calls, lessThanOrEqualTo(1000));
        expect(
          await session.feedRun('calls_left = 1', printCallback: _ignore),
          const MontyNone(),
        );
        await session.close();
      },
      options: PoolOptions(
        maxProcesses: 1,
        workerLocation: await _workerPath(),
      ),
    );
  });

  test('a type-checking session rejects a mistyped snippet', () async {
    await MontyPool.withPool(
      (pool) => pool.withSession(
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
        options: const SessionConfig(
          limits: ResourceLimits(maxMemory: 64 * 1024 * 1024),
          typeCheck: true,
        ),
      ),
      options: PoolOptions(
        maxProcesses: 1,
        workerLocation: await _workerPath(),
      ),
    );
  });

  test('exit 65 is a MemoryError that finishes the session', () async {
    final pool = await MontyPool.startWith(
      const PoolOptions(maxProcesses: 1),
      open: () =>
          PendingSpawn((_) => ProcessChannel.spawn(fakeWorker('oom-on-feed'))),
    );
    addTearDown(pool.close);
    final session = await pool.checkout();
    await expectLater(
      // The same call twice on purpose: once alive, once finished.
      // ignore: prefer-moving-to-variable
      session.feedRun('1', printCallback: _ignore),
      throwsA(
        isA<MontyRuntimeError>()
            .having((e) => e.exception.excType, 'excType', 'MemoryError')
            .having((e) => e.message, 'message', contains('memory limit')),
      ),
    );
    expect(pool.liveWorkers, 0);
    await expectLater(
      // The same call again on purpose: now the session is finished.
      // ignore: prefer-moving-to-variable
      session.feedRun('1', printCallback: _ignore),
      throwsA(isA<StateError>()),
    );
    await session.close();
  });

  group('print failure (upstream binding)', () {
    test('then completion: the failure wins, the session runs on', () async {
      await MontyPool.withPool(
        (pool) => pool.withSession(
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
                isA<StateError>().having((e) => e.message, 'message', 'sink'),
              ),
            );
            expect(seen, hasLength(1));
            // The turn completed in the worker: its state is kept.
            expect(
              await s.feedRun('x', printCallback: _ignore),
              const MontyInt(41),
            );
          },
          options: _limits,
        ),
        options: PoolOptions(
          maxProcesses: 1,
          workerLocation: await _workerPath(),
        ),
      );
    });

    test('then a suspension: the session is discarded', () async {
      await MontyPool.withPool(
        (pool) async {
          final session = await pool.checkout(options: _limits);
          final worker = onlyItem(ProcessChannel.live);
          var calls = 0;
          await expectLater(
            session.feedRun(
              "print('a')\nf()\n7",
              externals: {'f': (args, kwargs) => MontyInt(++calls)},
              printCallback: (stream, text) => throw StateError('sink'),
            ),
            throwsA(
              isA<StateError>().having((e) => e.message, 'message', 'sink'),
            ),
          );
          expect(calls, 0);
          await worker.exitCode.timeout(const Duration(seconds: 5));
          await expectLater(
            session.feedRun('1', printCallback: _ignore),
            throwsA(isA<StateError>()),
          );
          await session.close();
          expect(
            await pool.withSession(
              (s) => s.feedRun('2', printCallback: _ignore),
              options: _limits,
            ),
            const MontyInt(2),
          );
        },
        options: PoolOptions(
          maxProcesses: 1,
          workerLocation: await _workerPath(),
        ),
      );
    });
  });

  group('print stall (gate)', () {
    for (final byClose in [false, true]) {
      final how = byClose ? 'close' : 'requestTimeout';
      test('a callback that never completes, ended by $how: the call '
          'fails, the slot serves a new checkout', () async {
        await MontyPool.withPool(
          (pool) async {
            final session = await pool.checkout(options: _limits);
            final first = onlyItem(ProcessChannel.live);
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
            await first.exitCode.timeout(const Duration(seconds: 5));
            expect(pool.liveWorkers, 0);
            expect(
              await pool.withSession(
                (s) => s.feedRun('1 + 1', printCallback: _ignore),
                options: _limits,
              ),
              const MontyInt(2),
            );
            never.complete();
            await session.close();
          },
          options: PoolOptions(
            maxProcesses: 1,
            requestTimeout: byClose ? null : const Duration(milliseconds: 500),
            workerLocation: await _workerPath(),
          ),
        );
      });
    }

    test('a stalled callback while the worker keeps printing: reading '
        'stops at the read-ahead limit, requestTimeout cleans up', () async {
      await MontyPool.withPool(
        (pool) async {
          final session = await pool.checkout(options: _limits);
          final worker = onlyItem(ProcessChannel.live);
          final never = Completer<void>();
          final failed = expectLater(
            session.feedRun(
              "line = 'x' * 1000\nwhile True:\n    print(line)",
              printCallback: (stream, text) => never.future,
            ),
            throwsA(
              isA<MontyCrashedError>().having(
                (e) => e.cause,
                'cause',
                CrashCause.killed,
              ),
            ),
          );
          // Once reading pauses at the limit, it must stay paused, the
          // read-ahead unchanged, for a second while the worker, still alive,
          // keeps flooding: the worker is blocked on its pipe. How far past the
          // limit the pause lands is the platform's (measured: about 0.1 MiB
          // on macOS and 1.3 MiB on Linux CI); that reading stops is the
          // bound. requestTimeout leaves room for both waits.
          final early = await _filled(worker);
          await Future<void>.delayed(const Duration(seconds: 1));
          expect(worker.isAlive, isTrue, reason: 'still within the turn');
          expect(worker.readAhead.paused, isTrue);
          expect(worker.readAhead.now, early);
          await failed;
          expect(
            worker.readAhead.peak,
            lessThan(ProcessChannel.readAheadLimit * 2),
          );
          await worker.exitCode.timeout(const Duration(seconds: 5));
          expect(pool.liveWorkers, 0);
          expect(
            await pool.withSession(
              (s) => s.feedRun('3', printCallback: _ignore),
              options: _limits,
            ),
            const MontyInt(3),
          );
          never.complete();
          await session.close();
        },
        options: PoolOptions(
          maxProcesses: 1,
          requestTimeout: const Duration(seconds: 8),
          workerLocation: await _workerPath(),
        ),
      );
    });
  });

  group('close while busy (q8 gates)', () {
    test('during a turn, after feedRun(...).timeout: close ends it', () async {
      await MontyPool.withPool(
        (pool) async {
          final session = await pool.checkout(options: _limits);
          final worker = onlyItem(ProcessChannel.live);
          await expectLater(
            session
                .feedRun('while True:\n    pass', printCallback: _ignore)
                .timeout(const Duration(milliseconds: 200)),
            throwsA(isA<TimeoutException>()),
          );
          await session.close().timeout(const Duration(seconds: 5));
          await worker.exitCode.timeout(const Duration(seconds: 5));
          expect(
            await pool.withSession(
              (s) => s.feedRun('4', printCallback: _ignore),
              options: _limits,
            ),
            const MontyInt(4),
          );
        },
        options: PoolOptions(
          maxProcesses: 1,
          workerLocation: await _workerPath(),
        ),
      );
    });

    test('during an unresolved host call: the call fails at once, close '
        'returns, the worker is reset and reused', () async {
      await MontyPool.withPool(
        (pool) async {
          final session = await pool.checkout(options: _limits);
          final worker = onlyItem(ProcessChannel.live);
          final entered = Completer<void>();
          final run = session.feedRun(
            'x = 1\nnever()',
            externals: {
              'never': (args, kwargs) {
                entered.complete();

                return Completer<MontyValue>().future;
              },
            },
            printCallback: _ignore,
          );
          await entered.future;
          final failed = expectLater(run, throwsA(isA<StateError>()));
          await session.close().timeout(const Duration(seconds: 5));
          // The pending call fails at once; the callback never returns.
          await failed.timeout(const Duration(seconds: 5));
          expect(pool.idleWorkers, 1);
          await pool.withSession(
            (s) async {
              await expectLater(
                s.feedRun('x', printCallback: _ignore),
                throwsA(isA<MontyRuntimeError>()),
              );
            },
            options: _limits,
          );
          expect(ProcessChannel.live, [worker]);
        },
        options: PoolOptions(
          maxProcesses: 1,
          workerLocation: await _workerPath(),
        ),
      );
    });

    test('twice: the second close is a no-op', () async {
      await MontyPool.withPool(
        (pool) async {
          final session = await pool.checkout(options: _limits);
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
            await pool.withSession(
              (s) => s.feedRun('5', printCallback: _ignore),
              options: _limits,
            ),
            const MontyInt(5),
          );
        },
        options: PoolOptions(
          maxProcesses: 1,
          workerLocation: await _workerPath(),
        ),
      );
    });
  });

  group('outbound outcomes', () {
    /// A str one MiB past the frame limit: refused before it is sent. Built
    /// by the tests that use it, not when the suite loads.
    MontyString big() => MontyString('x' * (257 * 1024 * 1024));
    final oversized = isA<MontyRuntimeError>()
        .having((e) => e.exception.excType, 'excType', 'RuntimeError')
        .having(
          (e) => e.message,
          'message',
          matches(
            RegExp(
              r'^RuntimeError: request frame of \d+ bytes exceeds the maximum of '
              '${wire.Frame.maxLength} bytes\$',
            ),
          ),
        );

    test('an oversized input fails the call; the session runs on', () async {
      await MontyPool.withPool(
        (pool) => pool.withSession(
          (s) async {
            await expectLater(
              s.feedRun('len(v)', inputs: {'v': big()}, printCallback: _ignore),
              throwsA(oversized),
            );
            expect(
              await s.feedRun(
                'len(v)',
                inputs: {'v': const MontyString('abc')},
                printCallback: _ignore,
              ),
              const MontyInt(3),
            );
          },
          options: _limits,
        ),
        options: PoolOptions(
          maxProcesses: 1,
          workerLocation: await _workerPath(),
        ),
      );
    });

    test('an oversized automatic answer: the suspension stays pending, '
        'later feeds are refused, close resets the worker', () async {
      await MontyPool.withPool(
        (pool) async {
          final session = await pool.checkout(options: _limits);
          final worker = onlyItem(ProcessChannel.live);
          await expectLater(
            session.feedRun(
              'g()\n3',
              externals: {'g': (args, kwargs) => big()},
              printCallback: _ignore,
            ),
            throwsA(oversized),
          );
          for (final code in ['1', 'g()\n3']) {
            await expectLater(
              session.feedRun(
                code,
                externals: {'g': (args, kwargs) => const MontyString('ok')},
                printCallback: _ignore,
              ),
              throwsA(
                isA<StateError>().having(
                  (e) => e.message,
                  'message',
                  contains('suspension is awaiting an answer'),
                ),
              ),
            );
          }
          await session.close();
          expect(
            await pool.withSession(
              (s) => s.feedRun('4', printCallback: _ignore),
              options: _limits,
            ),
            const MontyInt(4),
          );
          expect(ProcessChannel.live, [worker]);
        },
        options: PoolOptions(
          maxProcesses: 1,
          workerLocation: await _workerPath(),
        ),
      );
    });
  });

  test(
    'the default sink on an undrained stdout: the isolate stays live, '
    'requestTimeout and close end the stall, the slot is reused',
    () async {
      final (code, out, err) = await _runProbe(
        'default_print_stall_probe.dart',
        drainStdout: false,
      );
      expect(code, 0, reason: err);
      expect(err, contains('stall probe ok'));
    },
    timeout: _probeTimeout,
  );

  test('a busy close leaves nothing that keeps the process alive', () async {
    final (code, out, err) = await _runProbe('close_exit_probe.dart');
    expect(code, 0, reason: err);
    expect(out, 'closed\n');
  }, timeout: _probeTimeout);

  test(
    'no print callback: fragments reach the process stdout and stderr',
    () async {
      final (code, out, err) = await _runProbe('default_print_probe.dart');
      expect(code, 0, reason: err);
      expect(out, 'ab\n');
      expect(err, 'e\n');
    },
    timeout: _probeTimeout,
  );

  group('workerPid and the finalizer (q2)', () {
    test("workerPid is the worker process's id; null in a turn and once "
        'closed', () async {
      final pool = await MontyPool.start(
        options: const PoolOptions(maxProcesses: 1),
      );
      try {
        final session = await pool.checkout(options: _limits);
        final pid = session.workerPid;
        expect(pid, onlyItem(ProcessChannel.live).pid);
        int? inTurn = -1;
        await session.feedRun(
          'print(1)',
          printCallback: (stream, text) => inTurn = session.workerPid,
        );
        expect(inTurn, isNull);
        expect(session.workerPid, pid);
        await session.close();
        expect(session.workerPid, isNull);
      } finally {
        await pool.close();
      }
    });

    test(
      'a session dropped without close gives its worker back once '
      'collected (GC forced through the VM service)',
      () async {
        final (code, out, err) = await _runProbe(
          'finalize_probe.dart',
          vmArgs: ['--enable-vm-service=0'],
        );
        // The VM announces its service on stdout first.
        final lines = out.trim().split('\n');
        expect(itemAt(lines, lines.length - 1), 'finalized', reason: err);
        expect(code, 0, reason: err);
      },
      timeout: _probeTimeout,
    );
  });
}
