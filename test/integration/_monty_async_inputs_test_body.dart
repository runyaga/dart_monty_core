// Shared test body for ffi_monty_async_inputs_test.dart and
// wasm_monty_async_inputs_test.dart.
//
// Pins down how `Monty(code).run(inputs: ...)` interacts with async
// scripts on the current `main` (without the unmerged feat/repl-future-capable
// REPL-level futures wiring). The intent is to make the boundary testable:
// what works today, and what depends on landing the futures-capable REPL.
//
// Both files call [runMontyAsyncInputsTests] so the assertions stay in sync
// across the FFI and WASM backends.

import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runMontyAsyncInputsTests() {
  group('Monty(code).run(inputs:) + async', () {
    // ----- Pure-Python async (no external futures) -------------------------
    // `async def` + `await coro()` runs entirely inside the interpreter — no
    // MontyResolveFutures event fires, so it does not depend on the
    // futures-capable REPL wiring.
    group('pure-Python async', () {
      test('await of a local coroutine returns the awaited value', () async {
        final r = await Monty('''
async def foo():
    return n * 2
result = await foo()
result
''').run(inputs: {'n': 21});

        expect(r.error, isNull);
        expect(r.value.dartValue, 42);
      });

      test('inputs visible inside async closure', () async {
        final r = await Monty('''
async def greet():
    return f"hello, {name}!"
await greet()
''').run(inputs: {'name': 'alice'});

        expect(r.error, isNull);
        expect(r.value.dartValue, 'hello, alice!');
      });

      test('asyncio.gather over local coroutines', () async {
        final r = await Monty('''
import asyncio
async def add(a, b):
    return a + b
await asyncio.gather(add(x, 1), add(x, 2), add(x, 3))
''').run(inputs: {'x': 10});

        expect(r.error, isNull);
        expect(r.value.dartValue, [11, 12, 13]);
      });
    });

    // ----- External calls: synchronous resolution -------------------------
    // On `main`, externalFunctions resolve *synchronously* from Python's
    // perspective: the callback's awaited Dart Future is unwrapped before
    // resume(), so Python sees the plain value. That means externals work
    // fine when called like a normal function but break when Python tries
    // to `await` them.
    group('external calls — synchronous on main', () {
      test(
        'plain (non-await) external call returns the resolved value',
        () async {
          var fetchCallCount = 0;
          final r =
              await Monty('''
result = fetch(key)
result
''').run(
                inputs: {'key': 'token'},
                externalFunctions: {
                  'fetch': (args) async {
                    fetchCallCount++;
                    await Future<void>.delayed(Duration.zero);

                    return 'value-for-${args['_0']}';
                  },
                },
              );

          expect(r.error, isNull);
          expect(r.value.dartValue, 'value-for-token');
          expect(fetchCallCount, equals(1));
        },
      );
    });

    // ----- External async (depends on futures-capable REPL) ---------------
    // When Python uses `await fetch(...)` against a Dart external, the
    // platform needs to surface the call as an awaitable so Python's event
    // loop can suspend on it. That requires `MontyFutureCapable.
    // resumeAsFuture` + `resolveFutures` to be wired through the REPL —
    // the work on the unmerged feat/repl-future-capable branch.
    //
    // Today (probed on main):
    //   - `result = await fetch(key)` raises TypeError:
    //         "'str' object can't be awaited"
    //   - `await asyncio.gather(fetch(a), fetch(b), fetch(c))` raises
    //         TypeError: "An asyncio.Future, a coroutine or an awaitable is
    //         required"
    //   In both cases the Dart callback DOES fire (so dispatch works), but
    //   the value is returned eagerly as a plain Python value rather than
    //   as an awaitable that Python can suspend on.
    //
    // The two tests below codify the SPEC that feat/repl-future-capable
    // must satisfy. They are skipped on main and should be flipped to
    // green once that branch lands.
    group('external async — pending feat/repl-future-capable', () {
      test(
        'await of a Dart external returns the resolved value',
        tags: 'pending-futures',
        () async {
          var fetchCallCount = 0;
          final r =
              await Monty('''
result = await fetch(key)
result
''').run(
                inputs: {'key': 'token'},
                externalFunctions: {
                  'fetch': (args) async {
                    fetchCallCount++;
                    await Future<void>.delayed(Duration.zero);

                    return 'value-for-${args['_0']}';
                  },
                },
              );

          expect(r.error, isNull);
          expect(fetchCallCount, equals(1));
          expect(r.value.dartValue, 'value-for-token');
        },
      );

      test(
        'asyncio.gather over Dart externals resolves in argument order',
        tags: 'pending-futures',
        () async {
          final calls = <int>[];
          final r =
              await Monty('''
import asyncio
results = await asyncio.gather(
    fetch(a),
    fetch(b),
    fetch(c),
)
results
''').run(
                inputs: {'a': 1, 'b': 2, 'c': 3},
                externalFunctions: {
                  'fetch': (args) async {
                    final n = args['_0']! as int;
                    calls.add(n);
                    await Future<void>.delayed(Duration.zero);

                    return n * 10;
                  },
                },
              );

          expect(r.error, isNull);
          expect(calls.toSet(), equals({1, 2, 3}));
          expect(r.value.dartValue, equals([10, 20, 30]));
        },
      );
    });
  });
}
