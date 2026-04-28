// Shared test body for ffi_repl_snapshot_lifecycle_test.dart and
// wasm_repl_snapshot_lifecycle_test.dart.
//
// Pending-state tracking lives in MontyRepl (Dart), so the StateError
// contract is identical FFI/WASM. Both backends share these scenarios.

import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runReplSnapshotLifecycleTests() {
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

      // Capture clean snapshot bytes for restore.
      await repl.feedRun('x = 1');
      final bytes = await repl.snapshot();

      // Pause execution and attempt restore.
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

      // Fast path (no externalFunctions, no osHandler).
      await repl.feedRun('x = 7');
      final bytes = await repl.snapshot();
      expect(bytes, isNotEmpty);
    });

    test('snapshot is allowed after an iterative feed completes', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      // Iterative path that completes naturally — externalFunctions
      // dispatched.
      final r = await repl.feedRun(
        'r = double(21)',
        externalFunctions: {'double': (args) async => (args['_0']! as int) * 2},
      );
      expect(r.error, isNull);

      final bytes = await repl.snapshot();
      expect(bytes, isNotEmpty);
    });
  });
}
