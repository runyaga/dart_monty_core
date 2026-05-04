// Shared test body for the Layer 2 (`MontyRepl.feedRun`) async/sync matrix.
//
// Exercises the four orthogonal cells of
// (Dart-handler-shape) × (Python-call-shape) plus the formerly-broken cell
// (Python `await ext()` against a Dart external).
// Each test asserts both the Dart-side return value AND the dispatch shape
// (callback fire count) so a regression in either dimension trips the test.
//
// Both `ffi_feedrun_async_matrix_test.dart` and
// `wasm_feedrun_async_matrix_test.dart` call [runFeedRunAsyncMatrixTests].

import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runFeedRunAsyncMatrixTests() {
  group('MontyRepl.feedRun async/sync matrix', () {
    late MontyRepl repl;

    setUp(() => repl = MontyRepl());
    tearDown(() async => repl.dispose());

    // matrix-cell: (sync Dart) × (sync Python)
    test('cell 1: sync handler + bare Python call', () async {
      var calls = 0;
      final r = await repl.feedRun(
        'fetch(7)',
        externalFunctions: {
          'fetch': (args) {
            calls++;

            // Synchronous-style: return a pre-resolved Future.
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
      final r = await repl.feedRun(
        'fetch(7)',
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

    // matrix-cell: (sync Dart) × (async Python local coro, no Dart await)
    test('cell 3: sync handler + Python local coroutine', () async {
      var calls = 0;
      final r = await repl.feedRun(
        '''
async def doubled(n):
    return fetch(n) * 2
await doubled(3)
''',
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

    // matrix-cell: (async Dart) × (async Python local coro, no Dart await)
    test('cell 4: async handler + Python local coroutine', () async {
      var calls = 0;
      final r = await repl.feedRun(
        '''
async def doubled(n):
    return fetch(n) * 2
await doubled(3)
''',
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

    // matrix-cell: (async Dart) × (Python `await ext()`) — register the
    // callback in externalAsyncFunctions so _driveLoop uses resumeAsFuture.
    test(
      'cell 5a: externalAsyncFunctions wires Python `await fetch(x)`',
      () async {
        var calls = 0;
        final r = await repl.feedRun(
          'await fetch("token")',
          externalAsyncFunctions: {
            'fetch': (args) async {
              calls++;
              await Future<void>.delayed(Duration.zero);

              return 'value-for-${args['_0']}';
            },
          },
        );

        expect(r.error, isNull);
        expect(r.value.dartValue, 'value-for-token');
        expect(calls, 1);
      },
    );

    // matrix-cell: same as 5a, but `asyncio.gather` to confirm concurrent
    // dispatch (all callbacks fire before the first MontyResolveFutures).
    test(
      'cell 5b: externalAsyncFunctions + asyncio.gather over externals',
      () async {
        final fired = <int>[];
        final r = await repl.feedRun(
          '''
import asyncio
results = await asyncio.gather(fetch(1), fetch(2), fetch(3))
results
''',
          externalAsyncFunctions: {
            'fetch': (args) async {
              final n = args['_0']! as int;
              fired.add(n);
              await Future<void>.delayed(Duration.zero);

              return n * 10;
            },
          },
        );

        expect(r.error, isNull);
        expect(r.value.dartValue, [10, 20, 30]);
        // All three dispatched (in some order) before gather yielded — that's
        // the whole point of async dispatch.
        expect(fired.toSet(), {1, 2, 3});
        expect(fired, hasLength(3));
      },
    );

    // Back-compat: handler in externalFunctions (sync dispatch) → Python
    // `await ext()` still raises TypeError.
    test(
      'externalFunctions (sync): Python `await ext()` still raises TypeError',
      () async {
        final r = await repl.feedRun(
          'await fetch(1)',
          externalFunctions: {
            'fetch': (args) => Future.value(args['_0']),
          },
        );

        expect(r.error, isNotNull);
        expect(r.error?.excType, equals('TypeError'));
      },
    );
  });
}
