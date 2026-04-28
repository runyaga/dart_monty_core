// Run with dart2js:  dart test test/integration/wasm_repl_snapshot_lifecycle_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_repl_snapshot_lifecycle_test.dart -p chrome --compiler dart2wasm --run-skipped
//
// WASM twin of ffi_repl_snapshot_lifecycle_test.dart. Pending-state
// tracking lives in MontyRepl (Dart), so the StateError contract is
// identical FFI/WASM. Pin the behavior on both backends.
@Tags(['integration', 'wasm'])
library;

import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('MontyRepl snapshot/restore lifecycle', () {
    test('snapshot throws StateError when paused mid-execution', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      final progress = await repl.feedStart(
        'tool()',
        externalFunctions: ['tool'],
      );
      expect(progress, isA<MontyPending>());

      expect(
        repl.snapshot,
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('mid-execution'),
          ),
        ),
      );
    });

    test('snapshot succeeds after resume completes the paused call', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feedStart('tool()', externalFunctions: ['tool']);
      final completed = await repl.resume(42);
      expect(completed, isA<MontyComplete>());

      final bytes = await repl.snapshot();
      expect(bytes, isA<Uint8List>());
      expect(bytes, isNotEmpty);
    });

    test('restore throws StateError when paused mid-execution', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feed('x = 1');
      final bytes = await repl.snapshot();

      await repl.feedStart('tool()', externalFunctions: ['tool']);
      expect(
        () => repl.restore(bytes),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('mid-execution'),
          ),
        ),
      );
    });

    test('snapshot is allowed after a fast-path feed', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feed('x = 7');
      final bytes = await repl.snapshot();
      expect(bytes, isNotEmpty);
    });

    test('snapshot is allowed after an iterative feed completes', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      final r = await repl.feed(
        'r = double(21)',
        externals: {'double': (args) async => (args['_0']! as int) * 2},
      );
      expect(r.error, isNull);

      final bytes = await repl.snapshot();
      expect(bytes, isNotEmpty);
    });
  });
}
