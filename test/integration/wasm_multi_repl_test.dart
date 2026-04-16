// WASM integration tests — MontySession multi-turn REPL state persistence.
//
// Verifies that variable state survives across sequential run() calls when
// using the WASM backend (MontyWasm) in a real browser environment.
//
// dart2js:   dart test test/integration/wasm_multi_repl_test.dart -p chrome --run-skipped
// dart2wasm: dart test test/integration/wasm_multi_repl_test.dart -p chrome --compiler dart2wasm --run-skipped
//
// dart2js vs dart2wasm note:
//   dart2js compiles Dart to JS Numbers — `is int` returns true for whole
//   numbers stored as JS Number.  dart2wasm uses strict Wasm i64/f64 — `is int`
//   and `is double` are never confused.  All assertions in this file use only
//   small integer values and plain strings to stay safe under both compilers.
@Tags(['integration', 'wasm'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('MontySession multi-turn REPL (WASM)', () {
    test(
      'variable defined in first run() is visible in second run()',
      () async {
        final platform = createPlatformMonty();
        final session = MontySession(platform: platform);
        addTearDown(() async {
          session.dispose();
          await platform.dispose();
        });

        await session.run('x = 7');
        final result = await session.run('x');

        expect(result.value, equals(const MontyInt(7)));
      },
    );

    test('variable updated across multiple run() calls', () async {
      final platform = createPlatformMonty();
      final session = MontySession(platform: platform);
      addTearDown(() async {
        session.dispose();
        await platform.dispose();
      });

      await session.run('counter = 0');
      await session.run('counter = counter + 1');
      await session.run('counter = counter + 1');
      final result = await session.run('counter');

      expect(result.value, equals(const MontyInt(2)));
    });

    test('two independent sessions do not share state', () async {
      final platform1 = createPlatformMonty();
      final session1 = MontySession(platform: platform1);
      final platform2 = createPlatformMonty();
      final session2 = MontySession(platform: platform2);
      addTearDown(() async {
        session1.dispose();
        await platform1.dispose();
        session2.dispose();
        await platform2.dispose();
      });

      await session1.run('x = 3');
      await session2.run('x = 9');

      final r1 = await session1.run('x');
      final r2 = await session2.run('x');

      expect(r1.value, equals(const MontyInt(3)));
      expect(r2.value, equals(const MontyInt(9)));
    });

    test('string variable persists across turns', () async {
      final platform = createPlatformMonty();
      final session = MontySession(platform: platform);
      addTearDown(() async {
        session.dispose();
        await platform.dispose();
      });

      await session.run('name = "dart"');
      final result = await session.run('name');

      expect(result.value, equals(const MontyString('dart')));
    });

    test('multiple variables all persist', () async {
      final platform = createPlatformMonty();
      final session = MontySession(platform: platform);
      addTearDown(() async {
        session.dispose();
        await platform.dispose();
      });

      await session.run('a = 1\nb = 2\nc = 3');
      final ra = await session.run('a');
      final rb = await session.run('b');
      final rc = await session.run('c');

      expect(ra.value, equals(const MontyInt(1)));
      expect(rb.value, equals(const MontyInt(2)));
      expect(rc.value, equals(const MontyInt(3)));
    });

    test('clearState() resets all persisted variables', () async {
      final platform = createPlatformMonty();
      final session = MontySession(platform: platform);
      addTearDown(() async {
        session.dispose();
        await platform.dispose();
      });

      await session.run('x = 42');
      expect(session.state, contains('x'));

      session.clearState();
      expect(session.state, isEmpty);
    });

    test('inputs are injected but not persisted', () async {
      final platform = createPlatformMonty();
      final session = MontySession(platform: platform);
      addTearDown(() async {
        session.dispose();
        await platform.dispose();
      });

      // Run with an input — it should be visible during that call.
      final r1 = await session.run(
        'injected',
        inputs: {'injected': 5},
      );
      expect(r1.value, equals(const MontyInt(5)));

      // After the call, the input must NOT be in persisted state.
      expect(session.state.containsKey('injected'), isFalse);
    });
  });
}
