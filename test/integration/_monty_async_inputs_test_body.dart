// Shared test body for ffi_monty_async_inputs_test.dart and
// wasm_monty_async_inputs_test.dart.
//
// Pins down how `Monty(code).run(inputs: ...)` interacts with async scripts.
// Three groups:
//   - pure-Python async (no Dart externals — works on every release)
//   - external calls without await (the long-standing sync path —
//     callback resolves Dart-side, Python sees the plain value)
//   - external async with `useFutures: true` (the futures path that
//     `_driveLoop` wires through `resumeAsFuture`/`resolveFutures` —
//     enables Python `await ext()` and `asyncio.gather` over externals)
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

    // ----- External async via `useFutures: true` -------------------------
    // When Python uses `await fetch(...)` against a Dart external, the
    // engine needs the host to surface the call as an awaitable so Python's
    // event loop can suspend on it. With `useFutures: true`, `_driveLoop`
    // launches each callback as an unawaited Future, replies with
    // `resumeAsFuture`, and batches the results back via `resolveFutures`
    // when MontyResolveFutures fires.
    group('external async with useFutures: true', () {
      test('await of a Dart external returns the resolved value', () async {
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
              useFutures: true,
            );

        expect(r.error, isNull);
        expect(fetchCallCount, equals(1));
        expect(r.value.dartValue, 'value-for-token');
      });

      test(
        'asyncio.gather over Dart externals resolves in argument order',
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
                useFutures: true,
              );

          expect(r.error, isNull);
          expect(calls.toSet(), equals({1, 2, 3}));
          expect(r.value.dartValue, equals([10, 20, 30]));
        },
      );
    });
  });
}
