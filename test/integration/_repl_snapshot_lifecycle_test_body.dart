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
    // WHY THIS TEST EXISTS. `ext_fn_names` lives on the Rust HANDLE, not on
    // monty's MontyRepl, so a dump CANNOT carry it: a restored handle starts
    // with an empty set. Rust exposes `restore_with_ext_fns` for that, but the
    // C boundary calls the one-argument `restore`, so every host gets the
    // empty set. Review flagged that as a silent footgun, and it is right
    // about the Rust/C layer.
    //
    // It is NOT reachable through this Dart API, and the reason is worth
    // pinning rather than trusting:
    //   1. restore() yields an Idle handle;
    //   2. resume() cannot be called on an Idle handle;
    //   3. so a caller MUST feed first, and every feed calls setExtFns
    //      unconditionally (monty_repl.dart, "Always sync the Rust handle's
    //      ext_fn_names ... including clearing it when empty").
    //
    // That makes the safety ACCIDENTAL — it depends on step 3 staying
    // unconditional. Delete that sync as an "optimisation" and externals go
    // silently unresolved after a restore, with no error. This test makes the
    // invariant load-bearing.
    test('an external function still resolves after a restore', () async {
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feedRun('seed = 7');
      final bytes = await repl.snapshot();

      final restored = MontyRepl();
      addTearDown(restored.dispose);
      await restored.restore(bytes);

      // The state came back...
      final seed = await restored.feedRun('seed');
      expect(seed.error, isNull);
      expect(seed.value, isA<MontyInt>());
      expect((seed.value as MontyInt).value, 7);

      // ...AND an external registered only on the restored session resolves.
      final r = await restored.feedRun(
        'tool(seed)',
        externalFunctions: {
          // List-pattern, not an index. `[0]`, `.first` and `firstOrNull!`
          // are all unchecked throws as far as DCM is concerned, and a helper
          // that throws on an unexpected arg list reports a confusing failure
          // instead of the one under test. The pattern states the shape it
          // needs and has a total fallback.
          'tool': (args, _) => switch (args) {
            [final int n, ...] => Future.value(n * 6),
            _ => Future.value(0),
          },
        },
      );
      expect(
        r.error,
        isNull,
        reason:
            'an external did not resolve after a restore. The restored handle '
            'starts with an EMPTY ext_fn_names set, so this only works because '
            'every feed re-syncs them. If that sync was removed, this is the '
            'test that says so.',
      );
      expect((r.value as MontyInt).value, 42);
    });

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
        externalFunctions: {
          // Same list-pattern as above. This one predates that change; being
          // older is not a reason to leave an unchecked index in a test
          // helper.
          'double': (args, _) => switch (args) {
            [final int n, ...] => Future.value(n * 2),
            _ => Future.value(0),
          },
        },
      );
      expect(r.error, isNull);

      final bytes = await repl.snapshot();
      expect(bytes, isNotEmpty);
    });
  });
}
