// MontyPool and its sessions against the COMMITTED
// lib/assets/dart_monty_core_proto_worker.{js,wasm} in Chrome, on dart2js and
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

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/pool_session.dart';
import 'package:test/test.dart';

const _backend = identical(1, 1.0) ? 'dart2js' : 'dart2wasm';

/// Every session's memory is bounded.
const _limits = SessionLimits(maxMemoryBytes: 64 * 1024 * 1024);

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
  test('feedRun, prints in order, Reset on close, reuse ($_backend)', () async {
    final pool = await MontyPool.start(maxProcesses: 1);
    try {
      final prints = <(String, String)>[];
      final value = await pool.withSession(
        (s) => s.feedRun(
          "import sys\nprint('one')\nprint('two', file=sys.stderr)\n"
          'x = 41\nx + 1',
          printCallback: (stream, text) async {
            await Future<void>.delayed(const Duration(milliseconds: 5));
            prints.add((stream, text));
          },
        ),
        limits: _limits,
      );
      expect(value, const MontyInt(42));
      expect(prints.map((p) => p.$2).join(), 'one\ntwo\n');
      expect(prints.map((p) => p.$1).toSet(), {'stdout', 'stderr'});
      expect(pool.idleWorkers, 1);
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
      }, limits: _limits);
      expect(pool.liveWorkers, 1);
    } finally {
      await pool.close();
    }
    expect(pool.liveWorkers, 0);
  });

  test('close during host code: Reset now ($_backend)', () async {
    await MontyPool.withPool((pool) async {
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
      expect(
        await pool.withSession(
          (s) => s.feedRun('7', printCallback: _ignore),
          limits: _limits,
        ),
        const MontyInt(7),
      );
    }, maxProcesses: 1);
  });

  test('requestTimeout ends a turn that runs on ($_backend)', () async {
    await MontyPool.withPool(
      (pool) async {
        final session = await pool.checkout(limits: _limits);
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
      requestTimeout: const Duration(seconds: 1),
    );
  });

  test('no print callback: each fragment reaches the console on its '
      'stream ($_backend)', () async {
    final (logged, errored) = _captureConsole();
    await MontyPool.withPool(
      (pool) => pool.withSession(
        (s) => s.feedRun(
          "print('a', end='')\nprint('b')\nimport sys\n"
          "print('e', file=sys.stderr)\n",
        ),
        limits: _limits,
      ),
      maxProcesses: 1,
    );
    expect(logged.join(), 'ab\n');
    expect(errored.join(), 'e\n');
  });
}
