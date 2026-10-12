// core#156 — the session suspension budget.
//
// The rules are traced from `pydantic-monty` 0.0.23, which reaches the same
// guarantee through `monty-pool` (a crate this package does not depend on):
//
//   BOUNDARY   a budget of N admits at most N chargeable suspensions; the
//              (N+1)th is refused. Upstream: budget 1 -> 1 call, budget 5 ->
//              5 calls, each then "suspension limit N exceeded".
//   SCOPE      per SESSION, accumulating across feeds — NOT per feed.
//              Upstream: two feeds of four callbacks under a budget of six
//              trip during the SECOND feed, having served six in total.
//   TERMINAL   the sandbox cannot catch it and carry on. Upstream: a body of
//              `try: f() except Exception: pass` still terminates.
//
// IT THROWS, it does not return an error result, and that is deliberate.
// `monty.dart` already promises "Binding-level failures (e.g. resource limits)
// still throw"; core#154 is that the promise is unkept for the errors that
// existed when it was written. A new host-enforced bound keeps it rather than
// joining the exception. #154 stays open for the rest.
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runSuspensionBudgetTests(String backend) {
  group('suspension budget — $backend', () {
    test('a budget of N admits at most N suspensions', () async {
      for (final budget in [1, 2, 5]) {
        var calls = 0;
        final repl = MontyRepl(limits: MontyLimits(maxSuspensions: budget));
        try {
          await expectLater(
            repl.feedRun(
              'for i in range(500):\n    ping()',
              externalFunctions: {
                'ping': (args, kwargs) {
                  calls++;

                  return Future<Object?>.value();
                },
              },
            ),
            throwsA(isA<MontySuspensionBudgetExceeded>()),
            reason: 'budget $budget should have stopped the run',
          );
        } finally {
          await repl.dispose();
        }
        expect(
          calls,
          budget,
          reason: 'budget $budget should admit exactly $budget callbacks',
        );
      }
    });

    test('the budget is per SESSION, not per feed', () async {
      var calls = 0;
      final repl = MontyRepl(limits: const MontyLimits(maxSuspensions: 6));
      try {
        final first = await repl.feedRun(
          'for i in range(4):\n    ping()',
          externalFunctions: {
            'ping': (args, kwargs) {
              calls++;

              return Future<Object?>.value();
            },
          },
        );
        expect(first.isError, isFalse, reason: 'four calls fit in six');

        await expectLater(
          repl.feedRun(
            'for i in range(4):\n    ping()',
            externalFunctions: {
              'ping': (args, kwargs) {
                calls++;

                return Future<Object?>.value();
              },
            },
          ),
          throwsA(isA<MontySuspensionBudgetExceeded>()),
          reason: 'the second feed must exhaust the SHARED budget',
        );
      } finally {
        await repl.dispose();
      }
      expect(calls, 6, reason: 'six served across both feeds, then refused');
    });

    test('a zero budget still allows work that never suspends', () async {
      final repl = MontyRepl(limits: const MontyLimits(maxSuspensions: 0));
      try {
        final r = await repl.feedRun('x = 1 + 1\nx');
        expect(r.isError, isFalse, reason: 'no suspension was needed');
      } finally {
        await repl.dispose();
      }
    });

    test('a negative budget is rejected, not read as unlimited', () {
      // Upstream's max_suspensions cannot be disabled; there is no opt-out.
      expect(
        () => MontyRepl(limits: const MontyLimits(maxSuspensions: -1)),
        throwsA(
          isA<ArgumentError>().having((e) => e.name, 'name', 'maxSuspensions'),
        ),
      );
    });

    test('the sandbox cannot catch it and carry on', () async {
      var calls = 0;
      final repl = MontyRepl(limits: const MontyLimits(maxSuspensions: 3));
      try {
        await expectLater(
          repl.feedRun(
            'def f():\n'
            '    try:\n'
            '        ping()\n'
            '    except Exception:\n'
            '        pass\n'
            'for i in range(100):\n'
            '    f()\n',
            externalFunctions: {
              'ping': (args, kwargs) {
                calls++;

                return Future<Object?>.value();
              },
            },
          ),
          throwsA(isA<MontySuspensionBudgetExceeded>()),
        );
      } finally {
        await repl.dispose();
      }
      expect(
        calls,
        3,
        reason: 'a Python try/except must not buy more callbacks',
      );
    });

    test('omitted limits ENFORCE the default, not merely declare it', () async {
      // Asserting the constant's value only proves it exists; deleting the
      // `?? defaultMax` that applies it would leave that green. So: no limits
      // configured, count the callbacks.
      var calls = 0;
      final repl = MontyRepl();
      try {
        await expectLater(
          repl.feedRun(
            'while True:\n    ping()',
            externalFunctions: {
              'ping': (args, kwargs) {
                calls++;

                return Future<Object?>.value();
              },
            },
          ),
          throwsA(isA<MontySuspensionBudgetExceeded>()),
        );
      } finally {
        await repl.dispose();
      }
      expect(calls, MontyLimits.defaultMaxSuspensions);
    });

    test('async callbacks are charged too', () async {
      // Future resolution arrives as its own suspension and is charged too,
      // so callbacks land below the budget, not on it. externalFunctions —
      // what every other test here uses — never reaches this arm. The await
      // is required: an un-awaited async external is a coroutine that never
      // runs, as in Python.
      var calls = 0;
      final repl = MontyRepl(limits: const MontyLimits(maxSuspensions: 8));
      try {
        await expectLater(
          repl.feedRun(
            'while True:\n    await ping()',
            externalAsyncFunctions: {
              'ping': (args, kwargs) {
                calls++;

                return Future<Object?>.value();
              },
            },
          ),
          throwsA(isA<MontySuspensionBudgetExceeded>()),
        );
      } finally {
        await repl.dispose();
      }
      expect(
        calls,
        lessThanOrEqualTo(8),
        reason: 'future resolution charges as well, so callbacks <= budget',
      );
      expect(calls, greaterThan(0), reason: 'the async path must have run');
    });
  });
}
