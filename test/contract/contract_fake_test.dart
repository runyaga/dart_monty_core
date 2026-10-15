// The contract suite's fake side, with no worker: every scenario's script
// on FakeMontySession must show the trace and answers the worker showed
// (contract_worker_test.dart runs the worker side). Then the fake's own
// rules: the script, the recording, misuse, and the negative controls the
// comparison must catch. Pure Dart: vm, dart2js and dart2wasm.
import 'dart:async';
import 'dart:typed_data';

import 'package:collection/collection.dart';

import 'package:dart_monty_core/src/fake_monty_session.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_not_handled_exception.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:test/test.dart';

import '_contract.dart';
import '_scenarios.dart';

/// [scenario] with its script replaced by [script].
Scenario _rescripted(
  Scenario scenario,
  void Function(FakeMontySession fake) script,
) => Scenario(
  scenario.name,
  feeds: scenario.feeds,
  script: script,
  run: scenario.run,
  trace: scenario.trace,
  answers: scenario.answers,
);

Scenario _named(String name) =>
    scenarios.firstWhereOrNull((s) => s.name == name) ??
    (throw StateError('no scenario $name'));

/// Whether [scenario]'s fake run matches its expectations.
Future<bool> _matches(Scenario scenario) async {
  final outcome = await runFake(scenario);

  return outcome.trace.join('\n') == scenario.trace.join('\n') &&
      outcome.answers.join('\n') == scenario.answers.join('\n');
}

const MontyValue _none = MontyNone();

const List<MontyValue> _noArgs = [];

const Map<String, MontyValue> _noKwargs = {};

void main() {
  group('scenarios', () {
    for (final scenario in scenarios) {
      test(scenario.name, () async {
        expectOutcome(scenario, await runFake(scenario));
      });
    }
  });

  group('negative controls', () {
    test('an extra scripted call fails the comparison', () async {
      final scenario = _rescripted(
        _named('a call answered with a value'),
        (f) => f
          ..willCall(
            'f',
            args: [const MontyInt(1)],
            kwargs: {'k': const MontyInt(2)},
          )
          ..willCall('f')
          ..willReturn(const MontyInt(42)),
      );
      expect(await _matches(scenario), isFalse);
    });

    test('a print moved across a host call fails the comparison', () async {
      final scenario = _rescripted(
        _named('prints before a call and after it'),
        (f) => f
          ..willCall('f')
          ..willPrint('before\n')
          ..willPrint('after')
          ..willPrint('!\n')
          ..willReturn(const MontyInt(7)),
      );
      expect(await _matches(scenario), isFalse);
    });

    test('a refused handler result shows in the answers', () async {
      // answer-control.md: a handler test asserts on `answers`, so a valid
      // result turned into a refused one fails it.
      Future<List<String>> answersWith(MontyValue result) async {
        final fake = FakeMontySession()
          ..willCall('f')
          ..willReturn(const MontyInt(7));
        try {
          await fake.feedRun('f()', externals: {'f': (_, _) => result});
        } on MontyRuntimeError {
          // The refused value raised in the sandbox; the answers say why.
        }
        await fake.close();

        return [for (final a in fake.answers) showAnswer(a)];
      }

      expect(await answersWith(const MontyString('ok')), [
        '0 value MontyString("ok")',
      ]);
      expect(
        await answersWith(const MontyString('\uD800')),
        isNot(['0 value MontyString("ok")']),
      );
    });
  });

  group('the script', () {
    test('a feed with no complete segment throws StateError', () async {
      final fake = FakeMontySession()..willCall('f');
      await expectLater(fake.feedRun('f()'), throwsStateError);
      expect(fake.feeds, isEmpty);
      // The session runs on: completing the segment makes it playable.
      fake.willReturn(const MontyInt(1));
      expect(
        await fake.feedRun('f()', externals: {'f': (_, _) => _none}),
        const MontyInt(1),
      );
      await fake.close();
    });

    test('events queued for later feeds wait for them', () async {
      final fake = FakeMontySession()
        ..willReturn(const MontyInt(1))
        ..willPrint('two\n')
        ..willReturn(const MontyInt(2));
      expect(await fake.feedRun('1'), const MontyInt(1));
      final printed = <String>[];
      expect(
        await fake.feedRun('2', printCallback: (_, t) => printed.add(t)),
        const MontyInt(2),
      );
      expect(printed, ['two\n']);
      expect(fake.feeds, ['1', '2']);
      await expectLater(fake.feedRun('3'), throwsStateError);
      await fake.close();
    });

    test('an uncaught answer drops the rest of its segment', () async {
      final fake = FakeMontySession()
        ..willCall('g')
        ..willPrint('never\n')
        ..willReturn(_none)
        ..willReturn(const MontyInt(2));
      final printed = <String>[];
      await expectLater(
        fake.feedRun('g()', printCallback: (_, t) => printed.add(t)),
        throwsA(isA<MontyRuntimeError>()),
      );
      expect(printed, isEmpty);
      expect(await fake.feedRun('2'), const MontyInt(2));
      await fake.close();
    });

    test('call ids count from 0 within each segment', () {
      final fake = FakeMontySession();
      expect([fake.willCall('f'), fake.willCallOs('os.environ')], [0, 1]);
      fake.willReturn(_none);
      expect(fake.willCall('f'), 0);
    });

    test('misuse is refused where it is scripted', () {
      final fake = FakeMontySession();
      expect(fake.willCatch, throwsStateError);
      fake.willPrint('x');
      expect(fake.willCatch, throwsStateError);
      expect(() => fake.willAwait([0]), throwsArgumentError);
      expect(() => fake.willAwait([]), throwsArgumentError);
      expect(() => fake.willPrint('x', stream: 'err'), throwsArgumentError);
      expect(() => fake.willRaise('NoSuchError'), throwsArgumentError);
      expect(() => fake.willCallOs('os.nothing'), throwsArgumentError);
      expect(
        () => fake.willCallOs('Path.read_text', args: [const MontyInt(1)]),
        throwsArgumentError,
      );
      // inbound.md: a value a worker could not send.
      expect(
        () => fake.willCall('f', args: [const MontyString('\uD800')]),
        throwsArgumentError,
      );
      expect(
        () => fake.willReturn(const MontyString('\uD800')),
        throwsArgumentError,
      );
    });

    test('willCatch with nothing raised fails the feed', () async {
      final fake = FakeMontySession()
        ..willCall('f')
        ..willCatch()
        ..willReturn(_none);
      await expectLater(
        fake.feedRun('f()', externals: {'f': (_, _) => _none}),
        throwsStateError,
      );
      await fake.close();
    });

    test('a raise after a partial gather does not wait for it', () async {
      final fake = FakeMontySession()
        ..willCall('f')
        ..willCall('f')
        ..willAwait([0, 1], gathered: true)
        ..willCall('g')
        ..willRaise('ValueError', message: 'x');
      final a = await fake.feedStart('x') as FunctionSnapshot;
      final b = await a.resume(const ExternalFuture()) as FunctionSnapshot;
      final wait = await b.resume(const ExternalFuture()) as FutureSnapshot;
      final g =
          await wait.resume({0: const ExternalReturnValue(MontyInt(1))})
              as FunctionSnapshot;
      await expectLater(
        g.resume(const ExternalReturnValue(MontyInt(2))),
        throwsA(isA<MontyRuntimeError>()),
      );
      await fake.close();
    });

    test('a crash after a partial gather ends the session at once', () async {
      // A dead worker owes the gather nothing: no further wait.
      final fake = FakeMontySession()
        ..willCall('f')
        ..willCall('f')
        ..willAwait([0, 1], gathered: true)
        ..willCall('g')
        ..willCrash();
      final a = await fake.feedStart('x') as FunctionSnapshot;
      final b = await a.resume(const ExternalFuture()) as FunctionSnapshot;
      final wait = await b.resume(const ExternalFuture()) as FutureSnapshot;
      final g =
          await wait.resume({0: const ExternalReturnValue(MontyInt(1))})
              as FunctionSnapshot;
      await expectLater(
        g.resume(const ExternalFuture()),
        throwsA(isA<MontyCrashedError>()),
      );
      await fake.close();
    });

    test('willCrash finishes the session', () async {
      final fake = FakeMontySession()..willCrash(timedOut: true);
      await expectLater(
        fake.feedRun('1'),
        throwsA(
          isA<MontyCrashedError>().having((e) => e.timedOut, 'timedOut', true),
        ),
      );
      await expectLater(fake.feedRun('2'), throwsStateError);
      await fake.close();
    });
  });

  group('OS calls', () {
    // Each OS function name, scripted and read back through the session's
    // own decoding (osCallParts): name, arguments and keywords.
    final calls = [
      for (final name in [
        'exists',
        'is_file',
        'is_dir',
        'is_symlink',
        'read_text',
        'read_bytes',
        'stat',
        'iterdir',
        'resolve',
        'absolute',
        'unlink',
        'rmdir',
      ])
        ('Path.$name', [const MontyPath('/a/b')], _noKwargs),
      (
        'Path.write_text',
        [const MontyPath('/a'), const MontyString('t')],
        _noKwargs,
      ),
      (
        'Path.append_text',
        [const MontyPath('/a'), const MontyString('t')],
        _noKwargs,
      ),
      (
        'Path.write_bytes',
        [
          const MontyPath('/a'),
          MontyBytes(Uint8List.fromList([1])),
        ],
        _noKwargs,
      ),
      (
        'Path.append_bytes',
        [
          const MontyPath('/a'),
          MontyBytes(Uint8List.fromList([2])),
        ],
        _noKwargs,
      ),
      ('open', [const MontyPath('/a'), const MontyString('r')], _noKwargs),
      (
        'Path.mkdir',
        [const MontyPath('/a')],
        {'parents': const MontyBool(true), 'exist_ok': const MontyBool(false)},
      ),
      (
        'Path.rename',
        [const MontyPath('/a'), const MontyPath('/b')],
        _noKwargs,
      ),
      (
        'os.getenv',
        [const MontyString('K'), const MontyString('d')],
        _noKwargs,
      ),
      ('os.environ', _noArgs, _noKwargs),
      ('date.today', _noArgs, _noKwargs),
      ('datetime.now', [_none], _noKwargs),
      ('datetime.now', [const MontyTimeZone(offsetSeconds: 3600)], _noKwargs),
      ('os.urandom', [const MontyInt(4)], _noKwargs),
      ('time.time', [const MontyString('time')], _noKwargs),
      ('time.sleep', [const MontyFloat(0.5)], _noKwargs),
      ('asyncio.sleep', [const MontyFloat(0.5)], _noKwargs),
    ];
    for (final (name, args, kwargs) in calls) {
      test('$name$args', () async {
        final fake = FakeMontySession()
          ..willCallOs(name, args: args, kwargs: kwargs)
          ..willReturn(_none);
        final snapshot = await fake.feedStart('x') as FunctionSnapshot;
        expect(snapshot.functionName, name);
        expect(snapshot.isOsFunction, isTrue);
        expect(snapshot.args, args);
        expect(snapshot.kwargs, kwargs.isEmpty ? isEmpty : kwargs);
        await fake.close();
      });
    }

    test('the session sleeps a system sleep itself', () async {
      final fake = FakeMontySession()
        ..willCallOs('system.sleep', args: [const MontyInt(0)])
        ..willCallOs(
          'system.async_sleep',
          args: [const MontyFloat(0)],
          eager: true,
        )
        ..willReturn(const MontyInt(1));
      expect(await fake.feedRun('x'), const MontyInt(1));
      expect(
        [for (final a in fake.answers) showAnswer(a)],
        [
          '0 value MontyNone()',
          '1/b0 value MontyNone()',
        ],
      );
      await fake.close();
    });

    test('bad arguments are refused', () {
      final fake = FakeMontySession();
      for (final (name, args, kwargs)
          in <(String, List<MontyValue>, Map<String, MontyValue>)>[
            ('Path.read_text', [], {}),
            ('Path.write_text', [const MontyPath('/a'), const MontyInt(1)], {}),
            (
              'Path.write_bytes',
              [const MontyPath('/a'), const MontyString('x')],
              {},
            ),
            (
              'Path.mkdir',
              [const MontyPath('/a')],
              {'parents': const MontyInt(1)},
            ),
            ('time.sleep', [const MontyString('x')], {}),
            ('datetime.now', [const MontyInt(1)], {}),
          ]) {
        expect(
          () => fake.willCallOs(name, args: args, kwargs: kwargs),
          throwsArgumentError,
          reason: name,
        );
      }
    });
  });

  test('past the suspension budget the session aborts the feed', () async {
    // C3-6's budget is the session's: it sends AbortFeed, and the fake's
    // worker ends the feed with the session's exception.
    final fake = FakeMontySession();
    for (var i = 0; i <= 1000; i++) {
      fake.willCall('f');
    }
    fake.willReturn(_none);
    await expectLater(
      fake.feedRun('x', externals: {'f': (_, _) => _none}),
      throwsA(
        isA<MontyRuntimeError>().having(
          (e) => e.toString(),
          'message',
          'RuntimeError: suspension limit 1000 exceeded',
        ),
      ),
    );
    expect(fake.answers, hasLength(1000));
    await fake.close();
  });

  group('the recording', () {
    test('each answers kind', () async {
      final fake = FakeMontySession()
        ..willCall('value')
        ..willCall('raises')
        ..willCatch()
        ..willCall('future')
        ..willCall('missing')
        ..willCatch()
        ..willCallOs('os.getenv', args: [const MontyString('A'), _none])
        ..willCatch()
        ..willLookUp('found')
        ..willLookUp('undefined')
        ..willCatch()
        ..willAwait([2])
        ..willReturn(_none);
      await fake.feedRun(
        'script',
        externals: {
          'value': (_, _) => const MontyInt(1),
          'raises': (_, _) => throw const ExternalException('KeyError', 'k'),
          'future': coroutine((_, _) async => const MontyInt(3)),
          'found': (_, _) => _none,
        },
        os: (_, _, _) => throw const OsCallNotHandledException(),
      );
      expect(
        [for (final a in fake.answers) showAnswer(a)],
        [
          '0 value MontyInt(1)',
          '1 raise KeyError: k',
          '2 future',
          '3 none',
          '4 none',
          '- value MontyString("found")',
          '- none',
          '2/b0 value MontyInt(3)',
        ],
      );
      expect(fake.answers.firstOrNull?.answer, isA<ExternalReturnValue>());
      await fake.close();
    });
  });

  group('lifecycle', () {
    test('close during a held turn kills it; later calls fail', () async {
      final gate = Completer<void>();
      final fake = FakeMontySession()
        ..willHold(gate.future)
        ..willReturn(_none);
      final feed = fake.feedRun('1');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.isClosed, isFalse);
      final killed = expectLater(
        feed,
        throwsA(
          isA<MontyCrashedError>()
              .having((e) => e.cause, 'cause', CrashCause.killed)
              .having((e) => e.timedOut, 'timedOut', false),
        ),
      );
      await fake.close();
      expect(fake.isClosed, isTrue);
      await killed;
      await expectLater(fake.feedRun('2'), throwsStateError);
    });

    test('a held turn queues a second call until its gate opens', () async {
      final gate = Completer<void>();
      final fake = FakeMontySession()
        ..willHold(gate.future)
        ..willReturn(const MontyInt(1))
        ..willReturn(const MontyInt(2));
      final first = fake.feedRun('1');
      final second = fake.feedRun('2');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(fake.feeds, ['1']);
      gate.complete();
      expect(await first, const MontyInt(1));
      expect(await second, const MontyInt(2));
      await fake.close();
    });

    test('isClosed after an idle close, and before any feed', () async {
      final idle = FakeMontySession()..willReturn(_none);
      await idle.feedRun('None');
      await idle.close();
      expect(idle.isClosed, isTrue);
      await expectLater(idle.feedRun('1'), throwsStateError);
      final unused = FakeMontySession();
      await unused.close();
      expect(unused.isClosed, isTrue);
      await expectLater(unused.feedRun('1'), throwsStateError);
    });

    test('no dump or load; no worker pid', () async {
      final fake = FakeMontySession()
        ..willCall('f')
        ..willReturn(_none);
      await expectLater(fake.dump(), throwsUnsupportedError);
      await expectLater(fake.loadSession(Uint8List(0)), throwsUnsupportedError);
      await expectLater(
        fake.loadSnapshot(Uint8List(0)),
        throwsUnsupportedError,
      );
      expect(fake.workerPid, isNull);
      final snapshot = await fake.feedStart('f()') as FunctionSnapshot;
      await expectLater(snapshot.dump(), throwsUnsupportedError);
      expect(
        await snapshot.resume(const ExternalReturnValue(_none)),
        isA<MontyComplete>(),
      );
      await fake.close();
    });
  });
}
