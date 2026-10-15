// The contract suite against the real worker, and the fake beside it: each
// scenario runs as Python on a worker-backed session and as a script on
// FakeMontySession, and both must show the scenario's trace and answers.
// Native workers come from tool/build_worker.sh; in a browser the committed
// assets are served under packages/.
//
//   dart test test/contract -p vm --tags=worker
//   dart test test/contract -p chrome -c dart2js --tags=worker  (and dart2wasm)
@Tags(['worker'])
library;

import 'dart:async';

import 'package:dart_monty_core/src/fake_monty_session.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/worker/channel_factory.dart' as chf;
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '_contract.dart';
import '_scenarios.dart';

/// [lines] as a Dart list literal, to read a mismatch against.
String _literal(List<String> lines) =>
    '[\n${lines.map((l) => '  ${_quote(l)},').join('\n')}\n]';

String _quote(String s) {
  final escaped = s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll('\n', r'\n');

  return "'$escaped'";
}

void main() {
  for (final scenario in scenarios) {
    test(scenario.name, () async {
      final real = await runReal(scenario, chf.openChannel);
      addTearDown(() {
        if (real.trace.join() != scenario.trace.join() ||
            real.answers.join() != scenario.answers.join()) {
          // The worker's lists as literals, to update the scenario from.
          // ignore: avoid_print
          print(
            'REAL ${scenario.name}\ntrace: ${_literal(real.trace)},\n'
            'answers: ${_literal(real.answers)},',
          );
        }
      });
      expectOutcome(scenario, real);
      final fake = await runFake(scenario);
      expect(fake.trace, real.trace, reason: 'fake trace against the worker');
      expect(fake.answers, real.answers, reason: 'fake answers');
    }, timeout: const Timeout(Duration(seconds: 60)));
  }

  // TGT1 B: install_dependencies on the pure-Monty worker, and the fake
  // beside it: an empty list succeeds, anything else is the worker's own
  // refusal (or the pool's, for a requirement uv would read as an option),
  // a suspension awaiting an answer refuses it, and the session runs on.
  test('installDependencies: the fake answers as the worker does', () async {
    Future<List<String>> installs(
      MontySession session,
      Future<void> Function() suspend,
    ) async {
      final seen = <String>[];
      Future<void> install(List<String> requirements) async {
        try {
          await session.installDependencies(requirements);
          seen.add('ok');
        } on Object catch (e) {
          seen.add(showError(e));
        }
      }

      // The list is read when called, not when the turn is free.
      final late = <String>[];
      final pendingInstall = session.installDependencies(late);
      late.add('numpy');
      await pendingInstall;
      seen.add('late ok');
      await install([]);
      await install(['httpx>=0.27']);
      await install(['numpy', '-e .', '']);
      await install(['   ']);
      await install(['-a"b\u{85}']);
      seen.add('value ${await session.feedRun('1 + 1')}');
      await suspend();
      await install([]);
      await install(['numpy']);
      await session.close();
      await install([]);
      await install(['\u{d800}']);

      return seen;
    }

    final pool = await startMonty(
      const PoolOptions(minProcesses: 0, maxProcesses: 1),
      open: chf.openChannel,
    );
    addTearDown(pool.close);
    final realSession = await pool.checkout();
    final real = await installs(realSession, () async {
      await realSession.feedStart('f');
    });
    final fake = FakeMontySession()
      ..willReturn(const MontyInt(2))
      ..willLookUp('f')
      ..willReturn(const MontyNone());
    final faked = await installs(fake, () async {
      await fake.feedStart('f');
    });
    String refused(String type, String message) =>
        'MontyRuntimeError $type: $message | $type: $message';
    const noWorker =
        'dependency installation is only supported by the CPython worker';
    const asOption =
        "must not start with '-' (it would be parsed as a uv option)";
    const pending =
        'StateError: Bad state: install_dependencies called while a '
        'suspension is awaiting an answer';
    const unencodable =
        'ArgumentError: Invalid argument (requirements): '
        r"'utf-8' codec can't encode character '\ud800' in position 0: "
        r'surrogates not allowed: "\ud800"';
    expect(real, [
      'late ok',
      'ok',
      refused('RuntimeError', noWorker),
      refused('ValueError', 'invalid requirement "-e .": $asOption'),
      refused('ValueError', 'invalid requirement "   ": must not be empty'),
      refused(
        'ValueError',
        r'invalid requirement "-a\"b\u{85}": ' + asOption,
      ),
      'value MontyInt(2)',
      pending,
      pending,
      'StateError: Bad state: the session is finished',
      unencodable,
    ]);
    expect(faked, real);
  });

  // An install from a host function's body waits on a turn that waits on it:
  // refused at once, as a feed is, with the install's own words.
  test('installDependencies from a host callback is refused', () async {
    Future<String> fromCallback(MontySession session) async {
      var seen = 'never called';
      await session.feedRun(
        'f()',
        externalLookup: {
          'f': MontyHostFunction('f', (args, kwargs) async {
            try {
              await session.installDependencies([]);
              seen = 'ok';
            } on Object catch (e) {
              seen = showError(e);
            }

            return const MontyNone();
          }),
        },
        printCallback: (stream, text) => null,
      );
      await session.close();

      return seen;
    }

    final pool = await startMonty(
      const PoolOptions(minProcesses: 0, maxProcesses: 1),
      open: chf.openChannel,
    );
    addTearDown(pool.close);
    final real = await fromCallback(await pool.checkout());
    final fake = FakeMontySession()
      ..willCall('f')
      ..willReturn(const MontyNone());
    expect(
      real,
      'StateError: Bad state: install_dependencies called while a '
      'suspension is awaiting an answer',
    );
    expect(await fromCallback(fake), real);
  });

  // hold.md: close while a turn is in flight, a real one blocked in the
  // worker and a held one on the fake, then a later call.
  test('close during a turn in flight', () async {
    Future<List<String>> closeMidTurn(MontySession session) async {
      final seen = <String>[];
      Future<void> loop() async {
        try {
          seen.add('value ${await session.feedRun('while True:\n    pass')}');
        } on Object catch (e) {
          seen.add(showError(e));
        }
      }

      final feed = loop();
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await session.close();
      await feed;
      try {
        await session.feedRun('1');
      } on Object catch (e) {
        seen.add(showError(e));
      }

      return seen;
    }

    final pool = await startMonty(
      const PoolOptions(minProcesses: 0, maxProcesses: 1),
      open: chf.openChannel,
    );
    addTearDown(pool.close);
    final real = await closeMidTurn(await pool.checkout());
    final fake = FakeMontySession()
      ..willHold(Completer<void>().future)
      ..willReturn(const MontyNone());
    expect(fake.isClosed, isFalse);
    final faked = await closeMidTurn(fake);
    expect(fake.isClosed, isTrue);
    expect(real, [
      'crashed killed',
      'StateError: Bad state: the session is finished',
    ]);
    expect(faked, real);
  });
}
