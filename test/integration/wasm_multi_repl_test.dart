// Run with dart2js:  dart test test/integration/wasm_multi_repl_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_multi_repl_test.dart -p chrome --compiler dart2wasm --run-skipped
@Tags(['integration', 'wasm'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('wasm_multi_repl', () {
    test('two concurrent REPLs have independent state', () async {
      final repl1 = MontyRepl();
      final repl2 = MontyRepl();
      addTearDown(repl1.dispose);
      addTearDown(repl2.dispose);

      await repl1.feed('x = 10');
      await repl2.feed('x = 99');

      expect((await repl1.feed('x')).value, const MontyInt(10));
      expect((await repl2.feed('x')).value, const MontyInt(99));
    });

    test('disposing one REPL does not affect the other', () async {
      final repl1 = MontyRepl();
      final repl2 = MontyRepl();
      addTearDown(repl2.dispose);

      await repl1.feed('msg = "repl1"');
      await repl2.feed('msg = "repl2"');
      await repl1.dispose();

      expect((await repl2.feed('msg')).value, const MontyString('repl2'));
    });

    test('three concurrent REPLs remain isolated', () async {
      final repls = [MontyRepl(), MontyRepl(), MontyRepl()];
      addTearDown(() async {
        for (final r in repls) {
          await r.dispose();
        }
      });

      for (var i = 0; i < repls.length; i++) {
        await repls[i].feed('n = $i');
      }
      for (var i = 0; i < repls.length; i++) {
        expect((await repls[i].feed('n')).value, MontyInt(i));
      }
    });

    test(
      'creating second REPL does not corrupt or panic first (regression)',
      () async {
        final repl1 = MontyRepl();
        await repl1.feed('result = 2 + 2');

        // This used to free repl1's handle → WASM panic on next repl1
        // operation.
        final repl2 = MontyRepl();
        addTearDown(repl1.dispose);
        addTearDown(repl2.dispose);

        expect((await repl1.feed('result')).value, const MontyInt(4));
      },
    );
  });
}
