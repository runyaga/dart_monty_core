// Shared test body for the ffi_/wasm_ repl_futures_test.dart files.
//
// Drives MontyRepl through the futures-capable progress loop end-to-end:
// feedStart → MontyPending → resumeAsFuture → MontyResolveFutures →
// resolveFutures → MontyComplete. Each test uses real Python code that
// awaits a Dart-registered external; we walk the loop manually so we can
// exercise resumeAsFuture/resolveFutures directly (the path that
// runtime/Monty.run does NOT take).
//
// Both files call [runReplFuturesTests] so the assertions stay in sync
// across FFI and WASM backends.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

/// Helper: walk the progress loop, treating every external call as a future.
/// Returns the terminal [MontyComplete] (or throws if the script never
/// completes / wraps an error).
///
/// [resolver] is consulted ONCE when the engine surfaces
/// [MontyResolveFutures] — it must produce a `(results, errors)` map for
/// every call ID listed in `pendingCallIds`. This lets each test observe
/// concurrent dispatch (gather) vs. sequential (one await at a time)
/// without the helper baking in a policy.
Future<MontyComplete> _runWithFutures(
  MontyRepl repl,
  String code, {
  required List<String> externalFunctions,
  required ({Map<int, Object?> results, Map<int, String> errors}) Function(
    List<int> pendingCallIds,
    List<MontyPending> pendings,
  )
  resolver,
}) async {
  final captured = <MontyPending>[];

  var progress = await repl.feedStart(
    code,
    externalFunctions: externalFunctions,
  );
  while (true) {
    switch (progress) {
      case final MontyComplete c:
        return c;
      case final MontyPending p:
        captured.add(p);
        progress = await repl.resumeAsFuture();
      case final MontyResolveFutures rf:
        final plan = resolver(rf.pendingCallIds, captured);
        progress = await repl.resolveFutures(
          plan.results,
          errors: plan.errors,
        );
        captured.clear();
      case final MontyOsCall _:
        fail('unexpected MontyOsCall in pure-async test');
      case final MontyNameLookup nl:
        fail('unexpected MontyNameLookup: ${nl.variableName}');
    }
  }
}

void runReplFuturesTests() {
  group('MontyRepl.resumeAsFuture / resolveFutures', () {
    late MontyRepl repl;

    setUp(() => repl = MontyRepl());
    tearDown(() async => repl.dispose());

    // --- Single await ------------------------------------------------------

    test('await of a single external returns the resolved value', () async {
      final pendings = <MontyPending>[];
      final result = await _runWithFutures(
        repl,
        '''
result = await fetch("token")
result
''',
        externalFunctions: ['fetch'],
        resolver: (ids, ps) {
          pendings.addAll(ps);
          // Resolve every pending ID with a synthesised value.
          final results = <int, Object?>{};
          for (final id in ids) {
            final pending = ps.firstWhere(
              (p) => p.callId == id,
              orElse: () => fail('callId $id not in observed pendings'),
            );
            final arg = pending.arguments.first.dartValue! as String;
            results[id] = 'value-for-$arg';
          }

          return (results: results, errors: <int, String>{});
        },
      );

      expect(result.result.error, isNull);
      expect(result.result.value.dartValue, 'value-for-token');
      expect(pendings, hasLength(1));
      expect(pendings.first.functionName, 'fetch');
    });

    // --- Error path --------------------------------------------------------
    //
    // Observed contract (probed on FFI 2026-05-04): an `errors` entry on
    // resolveFutures terminates the script with `MontyScriptError`, even
    // when Python wraps the await in `try/except`. The docstring says the
    // error is "raised as RuntimeError in Python", but in practice the
    // failure short-circuits past Python's exception handling. Tests
    // below verify the actual contract; if the engine's per-call error
    // delivery is fixed later, swap them for try/except-catches-it
    // assertions.

    test(
      'resolveFutures errors terminate the script with MontyScriptError',
      () async {
        expect(
          () => _runWithFutures(
            repl,
            '''
try:
    result = await fetch(1)
    out = ("ok", result)
except RuntimeError as e:
    out = ("err", str(e))
out
''',
            externalFunctions: ['fetch'],
            resolver: (ids, _) => (
              results: <int, Object?>{},
              errors: {for (final id in ids) id: 'simulated upstream failure'},
            ),
          ),
          throwsA(
            isA<MontyScriptError>().having(
              (e) => e.message,
              'message',
              contains('simulated upstream failure'),
            ),
          ),
        );
      },
    );

    // --- Concurrent dispatch (asyncio.gather) ------------------------------

    test('asyncio.gather over externals dispatches concurrently and '
        'resolves in argument order', () async {
      final dispatched = <int>[];
      final result = await _runWithFutures(
        repl,
        '''
import asyncio
results = await asyncio.gather(fetch(1), fetch(2), fetch(3))
results
''',
        externalFunctions: ['fetch'],
        resolver: (ids, ps) {
          // Every observed pending should have one int arg; record dispatch
          // order so we can assert all three fired before await yielded.
          for (final p in ps) {
            dispatched.add(p.arguments.first.dartValue! as int);
          }
          final results = <int, Object?>{};
          for (final p in ps) {
            results[p.callId] = (p.arguments.first.dartValue! as int) * 10;
          }

          return (results: results, errors: <int, String>{});
        },
      );

      expect(result.result.error, isNull);
      expect(result.result.value.dartValue, [10, 20, 30]);
      // All three externals dispatched (in some order) before gather
      // surfaced MontyResolveFutures — that's the whole point of gather.
      expect(dispatched.toSet(), {1, 2, 3});
      expect(dispatched, hasLength(3));
    });

    // --- Mixed values + errors in the same gather --------------------------

    test(
      'gather: an errored task terminates the script (not '
      'per-task try/except)',
      () async {
        // Same observed-contract caveat as the simpler error test:
        // resolveFutures errors short-circuit Python's exception handling,
        // so the script terminates rather than letting `safe()`'s
        // try/except catch.
        expect(
          () => _runWithFutures(
            repl,
            '''
import asyncio
async def safe(n):
    try:
        return ("ok", await fetch(n))
    except RuntimeError as e:
        return ("err", str(e))

results = await asyncio.gather(safe(1), safe(2), safe(3))
results
''',
            externalFunctions: ['fetch'],
            resolver: (ids, ps) {
              final results = <int, Object?>{};
              final errors = <int, String>{};
              for (final p in ps) {
                final n = p.arguments.first.dartValue! as int;
                if (n == 2) {
                  errors[p.callId] = 'broken-$n';
                } else {
                  results[p.callId] = n * 100;
                }
              }

              return (results: results, errors: errors);
            },
          ),
          throwsA(isA<MontyScriptError>()),
        );
      },
    );

    // --- Sequential awaits (one cycle per await) ---------------------------

    test(
      'sequential awaits each take their own resolveFutures cycle',
      () async {
        var cycles = 0;
        final result = await _runWithFutures(
          repl,
          '''
a = await fetch(7)
b = await fetch(13)
[a, b, a + b]
''',
          externalFunctions: ['fetch'],
          resolver: (ids, ps) {
            cycles++;
            final results = <int, Object?>{};
            for (final p in ps) {
              results[p.callId] = (p.arguments.first.dartValue! as int) * 2;
            }

            return (results: results, errors: <int, String>{});
          },
        );

        expect(result.result.error, isNull);
        expect(result.result.value.dartValue, [14, 26, 40]);
        // Two awaits → two distinct resolveFutures cycles (sequential, not
        // gathered).
        expect(cycles, equals(2));
      },
    );

    // --- Coroutine that awaits external internally -------------------------

    test('async function awaiting an external composes correctly', () async {
      final result = await _runWithFutures(
        repl,
        '''
async def doubled(n):
    val = await fetch(n)
    return val * 2

await doubled(21)
''',
        externalFunctions: ['fetch'],
        resolver: (ids, ps) {
          final results = <int, Object?>{};
          for (final p in ps) {
            results[p.callId] = p.arguments.first.dartValue;
          }

          return (results: results, errors: <int, String>{});
        },
      );

      expect(result.result.error, isNull);
      expect(result.result.value.dartValue, 42);
    });

    // --- State checks ------------------------------------------------------

    test('resumeAsFuture after dispose throws StateError', () async {
      // Use a fresh repl so the dispose doesn't trip our tearDown.
      final r = MontyRepl();
      await r.feedStart('1 + 1', externalFunctions: ['fetch']);
      await r.dispose();

      expect(r.resumeAsFuture, throwsStateError);
    });

    test('resolveFutures after dispose throws StateError', () async {
      final r = MontyRepl();
      await r.feedStart('1 + 1', externalFunctions: ['fetch']);
      await r.dispose();

      expect(
        () => r.resolveFutures({0: 'noop'}),
        throwsStateError,
      );
    });

    // --- Errors-only resolveFutures (no values) ----------------------------

    test(
      'resolveFutures with errors-only map carries the message into '
      'the terminal error',
      () async {
        // The error string the host supplies surfaces verbatim in the
        // terminal MontyScriptError.message, so callers can route it
        // back to whichever Dart-side exception classification they
        // prefer.
        expect(
          () => _runWithFutures(
            repl,
            'await fetch(1)',
            externalFunctions: ['fetch'],
            resolver: (ids, _) => (
              results: <int, Object?>{},
              errors: {for (final id in ids) id: 'all-broken'},
            ),
          ),
          throwsA(
            isA<MontyScriptError>().having(
              (e) => e.message,
              'message',
              contains('all-broken'),
            ),
          ),
        );
      },
    );

    // --- Resolved value preserves type fidelity ----------------------------

    test('resolveFutures preserves value type fidelity '
        '(int / string / list / map)', () async {
      final result = await _runWithFutures(
        repl,
        '''
import asyncio
results = await asyncio.gather(fetch("int"), fetch("str"), fetch("list"), fetch("map"))
[type(r).__name__ for r in results] + results
''',
        externalFunctions: ['fetch'],
        resolver: (ids, ps) {
          final results = <int, Object?>{};
          for (final p in ps) {
            final tag = p.arguments.first.dartValue! as String;
            results[p.callId] = switch (tag) {
              'int' => 42,
              'str' => 'hello',
              'list' => [1, 2, 3],
              'map' => {'k': 'v'},
              _ => null,
            };
          }

          return (results: results, errors: <int, String>{});
        },
      );

      expect(result.result.error, isNull);
      final list = result.result.value.dartValue! as List;
      // First four entries are the type names; last four are the values.
      expect(list.sublist(0, 4), ['int', 'str', 'list', 'dict']);
      expect(list.sublist(4), [
        42,
        'hello',
        [1, 2, 3],
        {'k': 'v'},
      ]);
    });
  });
}
