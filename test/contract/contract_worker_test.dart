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
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/pool_session.dart';
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
