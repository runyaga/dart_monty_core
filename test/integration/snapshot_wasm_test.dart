// Run with dart2js:  dart test test/integration/snapshot_wasm_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/snapshot_wasm_test.dart -p chrome --compiler dart2wasm --run-skipped
@Tags(['integration', 'wasm'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('snapshot_wasm', () {
    test('snapshot of empty session is non-empty', () async {
      final m = Monty();
      addTearDown(m.dispose);
      expect(await m.snapshot(), isNotEmpty);
    });

    test('int variable survives round-trip', () async {
      final m = Monty();
      addTearDown(m.dispose);
      await m.run('answer = 42');
      final snap = await m.snapshot();
      final m2 = Monty()..restore(snap);
      addTearDown(m2.dispose);
      expect((await m2.run('answer')).value, const MontyInt(42));
    });

    test('compile + runPrecompiled returns correct result (static)', () async {
      final binary = await Monty.compile('1 + 1');
      expect(binary, isNotEmpty);
      expect((await Monty.runPrecompiled(binary)).value, const MontyInt(2));
    });
  });
}
