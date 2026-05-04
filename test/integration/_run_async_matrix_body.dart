// Shared test body for the Layer 3 (`Monty.run`) async/sync matrix.
//
// `Monty.run` wraps `MontyRepl.feedRun` in a one-shot REPL lifecycle. The
// matrix here mirrors the Layer 2 cells but exercises the public one-shot
// surface — proves the wrapper preserves the contract (no leakage,
// no extra serialisation steps, externalAsyncFunctions threads through).
//
// Both `ffi_run_async_matrix_test.dart` and
// `wasm_run_async_matrix_test.dart` call [runRunAsyncMatrixTests].

import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runRunAsyncMatrixTests() {
  group('Monty(code).run async/sync matrix', () {
    // matrix-cell: (sync Dart) × (sync Python)
    test('cell 1: sync handler + bare Python call', () async {
      var calls = 0;
      final r = await Monty('fetch(7)').run(
        externalFunctions: {
          'fetch': (args, _) {
            calls++;

            return Future.value((args[0]! as int) + 1);
          },
        },
      );

      expect(r.error, isNull);
      expect(r.value.dartValue, 8);
      expect(calls, 1);
    });

    // matrix-cell: (async Dart) × (sync Python)
    test('cell 2: async handler + bare Python call', () async {
      var calls = 0;
      final r = await Monty('fetch(7)').run(
        externalFunctions: {
          'fetch': (args, _) async {
            calls++;
            await Future<void>.delayed(Duration.zero);

            return (args[0]! as int) + 1;
          },
        },
      );

      expect(r.error, isNull);
      expect(r.value.dartValue, 8);
      expect(calls, 1);
    });

    // matrix-cell: (sync Dart) × (async Python local coro)
    test('cell 3: sync handler + Python local coroutine', () async {
      var calls = 0;
      final r =
          await Monty('''
async def doubled(n):
    return fetch(n) * 2
await doubled(3)
''').run(
            externalFunctions: {
              'fetch': (args, _) {
                calls++;

                return Future.value(args[0]);
              },
            },
          );

      expect(r.error, isNull);
      expect(r.value.dartValue, 6);
      expect(calls, 1);
    });

    // matrix-cell: (async Dart) × (async Python local coro)
    test('cell 4: async handler + Python local coroutine', () async {
      var calls = 0;
      final r =
          await Monty('''
async def doubled(n):
    return fetch(n) * 2
await doubled(3)
''').run(
            externalFunctions: {
              'fetch': (args, _) async {
                calls++;
                await Future<void>.delayed(Duration.zero);

                return args[0];
              },
            },
          );

      expect(r.error, isNull);
      expect(r.value.dartValue, 6);
      expect(calls, 1);
    });

    // matrix-cell: (async Dart) × (Python `await ext()`) — register the
    // callback in externalAsyncFunctions so _driveLoop uses resumeAsFuture.
    test(
      'cell 5a: externalAsyncFunctions wires Python `await fetch(x)`',
      () async {
        var calls = 0;
        final r = await Monty('await fetch("token")').run(
          externalAsyncFunctions: {
            'fetch': (args, _) async {
              calls++;
              await Future<void>.delayed(Duration.zero);

              return 'value-for-${args[0]}';
            },
          },
        );

        expect(r.error, isNull);
        expect(r.value.dartValue, 'value-for-token');
        expect(calls, 1);
      },
    );

    test(
      'cell 5b: externalAsyncFunctions + asyncio.gather over externals',
      () async {
        final fired = <int>[];
        final r =
            await Monty('''
import asyncio
results = await asyncio.gather(fetch(1), fetch(2), fetch(3))
results
''').run(
              externalAsyncFunctions: {
                'fetch': (args, _) async {
                  final n = args[0]! as int;
                  fired.add(n);
                  await Future<void>.delayed(Duration.zero);

                  return n * 10;
                },
              },
            );

        expect(r.error, isNull);
        expect(r.value.dartValue, [10, 20, 30]);
        expect(fired.toSet(), {1, 2, 3});
      },
    );

    // Back-compat: handler in externalFunctions (sync) → Python `await ext()`
    // still raises TypeError.
    test(
      'externalFunctions (sync): Python `await ext()` still raises TypeError',
      () async {
        final r = await Monty('await fetch(1)').run(
          externalFunctions: {'fetch': (args, _) => Future.value(args[0])},
        );

        expect(r.error, isNotNull);
        expect(r.error?.excType, equals('TypeError'));
      },
    );

    // externalAsyncFunctions + inputs interplay — confirm the two parameters
    // compose correctly.
    test(
      'externalAsyncFunctions + inputs: inputs visible inside awaited external',
      () async {
        final r =
            await Monty('''
result = await fetch(seed)
result
''').run(
              inputs: {'seed': 'alice'},
              externalAsyncFunctions: {
                'fetch': (args, _) async {
                  await Future<void>.delayed(Duration.zero);

                  return 'hello, ${args[0]}';
                },
              },
            );

        expect(r.error, isNull);
        expect(r.value.dartValue, 'hello, alice');
      },
    );
  });
}
