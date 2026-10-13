// MontyPool and its sessions against the real worker executable
// (tool/build_worker.sh, or the CI artefact), and against the fake worker
// for the memory-limit exit: the session path end to end on the VM.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/pool_session.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_worker_harness.dart';

/// Every session's memory is bounded.
const _limits = SessionLimits(maxMemoryBytes: 64 * 1024 * 1024);

/// What a test passes as `printCallback` when it does not look at prints.
void _ignore(String stream, String text) => _ignored++;

/// How many prints [_ignore] dropped; never looked at.
var _ignored = 0;

Future<String> _workerPath() async =>
    ((await realWorker()) as WorkerExecutable).path;

void main() {
  expectNoWorkersLeftAfterEachTest();

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
          limits: _limits,
        );
        expect(value, const MontyInt(42));
        expect(prints.map((p) => p.$1).toSet(), {'stdout', 'stderr'});
        expect(prints.map((p) => p.$2).join(), 'one\ntwo\n');
        expect(pool.idleWorkers, 1);
        final worker = onlyItem(ProcessChannel.live);

        // The same process, reset: the global is gone.
        await pool.withSession((s) async {
          await expectLater(
            s.feedRun('x', printCallback: _ignore),
            throwsA(
              isA<MontyScriptError>().having(
                (e) => e.excType,
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
        }, limits: _limits);
        expect(ProcessChannel.live, [worker]);
      },
      maxProcesses: 1,
      workerLocation: await _workerPath(),
    );
  });

  test('close during host code: Reset now, the drive fails later', () async {
    await MontyPool.withPool(
      (pool) async {
        final session = await pool.checkout(limits: _limits);
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
        expect(pool.idleWorkers, 1);
        release.complete(const MontyInt(1));
        await failed;
        // The worker took its Reset and serves the next session.
        expect(
          await pool.withSession(
            (s) => s.feedRun('7', printCallback: _ignore),
            limits: _limits,
          ),
          const MontyInt(7),
        );
      },
      maxProcesses: 1,
      workerLocation: await _workerPath(),
    );
  });

  test(
    'requestTimeout kills a turn that runs on; the slot is reused',
    () async {
      await MontyPool.withPool(
        (pool) async {
          final session = await pool.checkout(limits: _limits);
          final first = onlyItem(ProcessChannel.live);
          await expectLater(
            session.feedRun('while True:\n    pass', printCallback: _ignore),
            throwsA(
              isA<MontyCrashedError>().having(
                (e) => e.cause,
                'cause',
                CrashCause.killed,
              ),
            ),
          );
          await first.exitCode.timeout(const Duration(seconds: 5));
          await session.close();
          expect(pool.liveWorkers, 0);
          expect(
            await pool.withSession(
              (s) => s.feedRun('1 + 1', printCallback: _ignore),
              limits: _limits,
            ),
            const MontyInt(2),
          );
        },
        maxProcesses: 1,
        requestTimeout: const Duration(milliseconds: 500),
        workerLocation: await _workerPath(),
      );
    },
  );

  test(
    'within the feed backstop the sandbox raises TimeoutError itself',
    () async {
      await MontyPool.withPool(
        (pool) async {
          final session = await pool.checkout(
            limits: const SessionLimits(
              maxMemoryBytes: 64 * 1024 * 1024,
              maxFeedDuration: Duration(milliseconds: 200),
            ),
          );
          // The sandbox raises TimeoutError itself, within its budget.
          await expectLater(
            session.feedRun('while True:\n    pass', printCallback: _ignore),
            throwsA(
              isA<MontyScriptError>().having(
                (e) => e.excType,
                'excType',
                'TimeoutError',
              ),
            ),
          );
          await session.close();
        },
        maxProcesses: 1,
        workerLocation: await _workerPath(),
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
          limits: _limits,
        );
        expect(value, const MontyInt(7));
        expect(
          clock.elapsed,
          greaterThanOrEqualTo(const Duration(milliseconds: 45)),
        );
      },
      maxProcesses: 1,
      workerLocation: await _workerPath(),
    );
  });

  test('past 1000 host calls the feed fails in the sandbox', () async {
    await MontyPool.withPool(
      (pool) async {
        final session = await pool.checkout(limits: _limits);
        var calls = 0;
        await expectLater(
          session.feedRun(
            'while True:\n    f()',
            externals: {'f': (args, kwargs) => MontyInt(++calls)},
            printCallback: _ignore,
          ),
          throwsA(
            isA<MontyScriptError>()
                .having((e) => e.excType, 'excType', 'RuntimeError')
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
      maxProcesses: 1,
      workerLocation: await _workerPath(),
    );
  });

  test('a type-checking session rejects a mistyped snippet', () async {
    await MontyPool.withPool(
      (pool) => pool.withSession(
        (s) async {
          await expectLater(
            s.feedRun('x: int = "a"', printCallback: _ignore),
            throwsA(isA<MontyTypeCheckError>()),
          );
          expect(
            await s.feedRun('y: int = 2\ny', printCallback: _ignore),
            const MontyInt(2),
          );
        },
        limits: _limits,
        typeCheck: true,
      ),
      maxProcesses: 1,
      workerLocation: await _workerPath(),
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
        isA<MontyScriptError>()
            .having((e) => e.excType, 'excType', 'MemoryError')
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

  test(
    'no print callback: fragments reach the process stdout and stderr',
    () async {
      final result = await Process.run(Platform.resolvedExecutable, [
        File('test/integration/worker/default_print_probe.dart').absolute.path,
        await _workerPath(),
      ]).timeout(const Duration(seconds: 60));
      expect(result.exitCode, 0, reason: '${result.stderr}');
      expect(result.stdout, 'ab\n');
      expect(result.stderr, 'e\n');
    },
  );
}
