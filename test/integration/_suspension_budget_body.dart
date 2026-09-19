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
                'ping': (args, kwargs) async {
                  calls++;

                  return null;
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
            'ping': (args, kwargs) async {
              calls++;

              return null;
            },
          },
        );
        expect(first.isError, isFalse, reason: 'four calls fit in six');

        await expectLater(
          repl.feedRun(
            'for i in range(4):\n    ping()',
            externalFunctions: {
              'ping': (args, kwargs) async {
                calls++;

                return null;
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

    test('unlimited opts out', () async {
      var calls = 0;
      final repl = MontyRepl(
        limits: const MontyLimits(
          maxSuspensions: MontyLimits.unlimitedSuspensions,
        ),
      );
      try {
        final r = await repl.feedRun(
          'for i in range(2000):\n    ping()',
          externalFunctions: {
            'ping': (args, kwargs) async {
              calls++;

              return null;
            },
          },
        );
        expect(r.isError, isFalse);
      } finally {
        await repl.dispose();
      }
      expect(calls, 2000, reason: 'well past the default of 1000');
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
              'ping': (args, kwargs) async {
                calls++;

                return null;
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

    test('omitted limits apply the default, not unlimited', () {
      expect(MontyLimits.defaultMaxSuspensions, 1000);
      expect(const MontyLimits().maxSuspensions, isNull);
    });
  });
}
