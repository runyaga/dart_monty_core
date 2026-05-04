// Shared test body for the Layer 3 (`Monty.run`) async/sync matrix.
//
// `Monty.run` wraps `MontyRepl.feedRun` in a one-shot REPL lifecycle. The
// matrix here mirrors the Layer 2 cells but exercises the public one-shot
// surface — proves the wrapper preserves the contract (no leakage,
// no extra serialisation steps, useFutures threads through).
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
          'fetch': (args) {
            calls++;

            return Future.value((args['_0']! as int) + 1);
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
          'fetch': (args) async {
            calls++;
            await Future<void>.delayed(Duration.zero);

            return (args['_0']! as int) + 1;
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
              'fetch': (args) {
                calls++;

                return Future.value(args['_0']);
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
              'fetch': (args) async {
                calls++;
                await Future<void>.delayed(Duration.zero);

                return args['_0'];
              },
            },
          );

      expect(r.error, isNull);
      expect(r.value.dartValue, 6);
      expect(calls, 1);
    });

    // matrix-cell: (async Dart) × (Python `await ext()`) — useFutures: true
    test('cell 5a: useFutures=true wires Python `await fetch(x)`', () async {
      var calls = 0;
      final r = await Monty('await fetch("token")').run(
        externalFunctions: {
          'fetch': (args) async {
            calls++;
            await Future<void>.delayed(Duration.zero);

            return 'value-for-${args['_0']}';
          },
        },
        useFutures: true,
      );

      expect(r.error, isNull);
      expect(r.value.dartValue, 'value-for-token');
      expect(calls, 1);
    });

    test('cell 5b: useFutures=true + asyncio.gather over externals', () async {
      final fired = <int>[];
      final r =
          await Monty('''
import asyncio
results = await asyncio.gather(fetch(1), fetch(2), fetch(3))
results
''').run(
            externalFunctions: {
              'fetch': (args) async {
                final n = args['_0']! as int;
                fired.add(n);
                await Future<void>.delayed(Duration.zero);

                return n * 10;
              },
            },
            useFutures: true,
          );

      expect(r.error, isNull);
      expect(r.value.dartValue, [10, 20, 30]);
      expect(fired.toSet(), {1, 2, 3});
    });

    // Default-off back-compat: Python `await ext()` raises TypeError when
    // useFutures is not opted in.
    test(
      'useFutures=false: Python `await ext()` still raises TypeError',
      () async {
        final r = await Monty('await fetch(1)').run(
          externalFunctions: {'fetch': (args) async => args['_0']},
        );

        expect(r.error, isNotNull);
        expect(r.error?.excType, equals('TypeError'));
      },
    );

    // Inputs + useFutures interplay — the new flag must not break the
    // existing inputs: parameter.
    test(
      'useFutures + inputs: inputs visible inside awaited external script',
      () async {
        final r =
            await Monty('''
result = await fetch(seed)
result
''').run(
              inputs: {'seed': 'alice'},
              externalFunctions: {
                'fetch': (args) async {
                  await Future<void>.delayed(Duration.zero);

                  return 'hello, ${args['_0']}';
                },
              },
              useFutures: true,
            );

        expect(r.error, isNull);
        expect(r.value.dartValue, 'hello, alice');
      },
    );
  });
}
