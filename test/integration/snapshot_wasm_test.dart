// WASM integration tests — MontySession.snapshot/restore and Monty.compile/runPrecompiled.
//
// Verifies round-trip fidelity for session snapshots and that pre-compiled
// bytecode executes correctly on the WASM backend (MontyWasm) in a real
// browser.
//
// dart2js:   dart test test/integration/snapshot_wasm_test.dart -p chrome --run-skipped
// dart2wasm: dart test test/integration/snapshot_wasm_test.dart -p chrome --compiler dart2wasm --run-skipped
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
  group('MontySession.snapshot / restore (WASM)', () {
    test('snapshot of empty session produces non-empty bytes', () async {
      final platform = createPlatformMonty();
      final session = MontySession(platform: platform);
      addTearDown(() async {
        session.dispose();
        await platform.dispose();
      });

      final bytes = session.snapshot();
      expect(bytes, isNotEmpty);
    });

    test(
      'round-trip: variable defined via run() survives snapshot/restore',
      () async {
        final platform1 = createPlatformMonty();
        final session1 = MontySession(platform: platform1);
        addTearDown(() async {
          session1.dispose();
          await platform1.dispose();
        });

        await session1.run('x = 5');
        final bytes = session1.snapshot();

        // Restore into a fresh session backed by a new platform instance.
        final platform2 = createPlatformMonty();
        final session2 = MontySession(platform: platform2)..restore(bytes);
        addTearDown(() async {
          session2.dispose();
          await platform2.dispose();
        });

        // The restored session should expose x in state.
        expect(session2.state['x'], equals(5));

        // And x must be visible to subsequent run() calls.
        final result = await session2.run('x');
        expect(result.value, equals(const MontyInt(5)));
      },
    );

    test('round-trip: multiple variables all restored', () async {
      final platform1 = createPlatformMonty();
      final session1 = MontySession(platform: platform1);
      addTearDown(() async {
        session1.dispose();
        await platform1.dispose();
      });

      await session1.run('a = 1\nb = 2\nlabel = "ok"');
      final bytes = session1.snapshot();

      final platform2 = createPlatformMonty();
      final session2 = MontySession(platform: platform2)..restore(bytes);
      addTearDown(() async {
        session2.dispose();
        await platform2.dispose();
      });

      expect(session2.state['a'], equals(1));
      expect(session2.state['b'], equals(2));
      expect(session2.state['label'], equals('ok'));
    });

    test('restore replaces existing state in target session', () async {
      final platform = createPlatformMonty();
      final session = MontySession(platform: platform);
      addTearDown(() async {
        session.dispose();
        await platform.dispose();
      });

      await session.run('x = 1');
      final snap1 = session.snapshot();

      await session.run('x = 99');
      expect(session.state['x'], equals(99));

      // Restore back to snap1 — x must return to 1.
      session.restore(snap1);
      expect(session.state['x'], equals(1));
    });

    test('Monty.snapshot / restore round-trip', () async {
      final platform1 = createPlatformMonty();
      final monty1 = Monty.withPlatform(platform1);
      addTearDown(monty1.dispose);

      await monty1.run('answer = 6');
      final bytes = monty1.snapshot();

      final platform2 = createPlatformMonty();
      final monty2 = Monty.withPlatform(platform2)..restore(bytes);
      addTearDown(monty2.dispose);

      expect(monty2.state['answer'], equals(6));
      final result = await monty2.run('answer');
      expect(result.value, equals(const MontyInt(6)));
    });
  });

  group('Monty.compile / runPrecompiled (WASM)', () {
    test('compile() returns non-empty bytes', () async {
      final binary = await Monty.compile('1 + 1');
      expect(binary, isNotEmpty);
    });

    test('runPrecompiled() produces correct result', () async {
      final binary = await Monty.compile('3 + 4');

      final platform = createPlatformMonty();
      final session = MontySession(platform: platform);
      addTearDown(() async {
        session.dispose();
        await platform.dispose();
      });

      final result = await session.runPrecompiled(binary);
      expect(result.value, equals(const MontyInt(7)));
    });

    test('same compiled bytes run correctly twice', () async {
      final binary = await Monty.compile('2 + 3');

      final platform = createPlatformMonty();
      final session = MontySession(platform: platform);
      addTearDown(() async {
        session.dispose();
        await platform.dispose();
      });

      final r1 = await session.runPrecompiled(binary);
      final r2 = await session.runPrecompiled(binary);

      expect(r1.value, equals(const MontyInt(5)));
      expect(r2.value, equals(const MontyInt(5)));
    });

    test('SyntaxError in compile() throws MontySyntaxError', () async {
      await expectLater(
        Monty.compile('def'),
        throwsA(isA<MontySyntaxError>()),
      );
    });

    test('string result from runPrecompiled()', () async {
      final binary = await Monty.compile('"hello"');

      final platform = createPlatformMonty();
      final session = MontySession(platform: platform);
      addTearDown(() async {
        session.dispose();
        await platform.dispose();
      });

      final result = await session.runPrecompiled(binary);
      expect(result.value, equals(const MontyString('hello')));
    });
  });
}
