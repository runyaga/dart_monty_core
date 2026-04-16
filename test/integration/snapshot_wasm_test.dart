// Integration smoke tests: compile/runPrecompiled and snapshot/restore on
// the WASM backend.
//
// Run with dart2js:
//   dart test test/integration/snapshot_wasm_test.dart -p chrome --tags=wasm
// Run with dart2wasm:
//   dart test test/integration/snapshot_wasm_test.dart -p chrome \
//     --compiler dart2wasm --tags=wasm
//
// Number-type note: dart2js encodes JSON integers as JS Number (satisfies
// `is int`); dart2wasm has true 64-bit int/double separation. Tests use only
// small integers and strings — unambiguous in both compilation modes.
@Tags(['integration', 'wasm'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('E — WASM compile + snapshot smoke tests', () {
    test('E1: Monty.compile returns non-empty bytes', () async {
      final binary = await Monty.compile('2 + 2');
      expect(binary, isNotEmpty);
    });

    test('E2: compile + runPrecompiled returns correct value', () async {
      final binary = await Monty.compile('1 + 1');

      final m = Monty();
      addTearDown(m.dispose);

      final r = await m.runPrecompiled(binary);
      expect(r.value, equals(const MontyInt(2)));
    });

    test('E3: MontySession snapshot/restore preserves state', () async {
      final m1 = Monty();
      addTearDown(m1.dispose);
      await m1.run('x = 7');
      final snap = m1.snapshot();

      final m2 = Monty()..restore(snap);
      addTearDown(m2.dispose);

      final r = await m2.run('x');
      expect(r.value, equals(const MontyInt(7)));
    });
  });
}
