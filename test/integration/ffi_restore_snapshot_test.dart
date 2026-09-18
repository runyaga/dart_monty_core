// The snapshot/restore pair on the ONE-SHOT handle — DECLARED DEFECT, core#152.
//
// test/integration/ffi_compile_precompiled_test.dart already pins this defect
// at the top of the stack, through `Monty.compile()` and
// `Monty.runPrecompiled()`. It never names the MontyCoreBindings entry points
// underneath, which is why `restoreSnapshot` and `startPrecompiled` were
// reported unexercised by tool/check_api_exercised.sh once its source list
// became the public export closure (1e4a875).
//
// This file drives them at their own layer, on a real backend, and pins the
// REFUSAL rather than pretending the feature works. That is the honest state:
//
//   native/src/handle.rs:558  snapshot() -> Err(...)  unconditionally
//   native/src/handle.rs:570  restore()  -> Err(...)  unconditionally
//
// and the reason is structural, not a missing API — monty's `SessionRef` has
// no variant for an un-started `MontyRun`, and this handle destructures
// `RunProgress` into its parts, so it cannot supply `SessionRef::Running`
// either. Supporting it means keeping whole `RunProgress` instead of its
// parts, which is a change to the state machine.
//
// WHY BOTH HALVES GET THEIR OWN CASE: fixing one leaves the pair unusable, and
// a test that only covered the producer would go green on a half-fix. The
// consumer half is reached through a REPL-produced snapshot precisely so that
// "there were no valid bytes to restore" cannot be mistaken for the cause.
//
// WHEN THIS IS FIXED THESE TESTS FAIL, which is intended: the fix must come
// with a decision recorded in core#152, and these cases are where the new
// behaviour gets asserted.
@Tags(['integration', 'ffi'])
library;

import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/ffi_core_bindings.dart';
import 'package:dart_monty_core/src/ffi/native_bindings_ffi.dart';
import 'package:test/test.dart';

FfiCoreBindings _core() => FfiCoreBindings(bindings: const NativeBindingsFfi());

void main() {
  group('MontyCoreBindings snapshot/restore on the one-shot handle (FFI)', () {
    test('snapshot() refuses, and says why', () async {
      final core = _core();
      await core.init();
      await core.start('mystery_value + 1');

      // Paused mid-execution is the most favourable case for a snapshot, and
      // it still refuses — so the refusal is structural, not a matter of
      // catching the handle at the wrong moment.
      await expectLater(
        core.snapshot(),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            allOf(
              contains('snapshot is not supported on the one-shot handle'),
              contains('SessionRef'),
              contains('Use MontyRepl'),
            ),
          ),
        ),
      );
    });

    test(
      'restoreSnapshot() refuses VALID bytes from a real REPL snapshot',
      () async {
        // Produce genuinely valid snapshot bytes first. MontyRepl CAN snapshot
        // (SessionRef::Idle), so this is not "the bytes were bad".
        final repl = MontyRepl();
        addTearDown(repl.dispose);
        await repl.feedRun('seed = 7');
        final bytes = await repl.snapshot();
        expect(bytes, isNotEmpty);

        final core = _core();

        await expectLater(
          core.restoreSnapshot(bytes),
          throwsA(
            isA<Object>().having(
              (e) => e.toString(),
              'message',
              allOf(
                contains('restore is not supported on the one-shot handle'),
                contains('MontyRepl::restore'),
              ),
            ),
          ),
        );
      },
    );

    test('startPrecompiled() is unusable because restore is', () async {
      // compileCode() feeds startPrecompiled(). Both ends sit on the same
      // broken pair, so this asserts the reachable end: whatever bytes are
      // supplied, the restore underneath refuses.
      final core = _core();

      // The error it raises is the RESTORE one, which is what makes the
      // causal claim in this test's name a measurement rather than a guess.
      await expectLater(
        core.startPrecompiled(Uint8List.fromList([0, 1, 2, 3])),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'message',
            contains('restore is not supported on the one-shot handle'),
          ),
        ),
      );
    });

    test('the REPL path, by contrast, round-trips its own snapshot', () async {
      // The control. Without this, the three refusals above could be read as
      // "snapshots do not work in this engine" rather than "they do not work
      // on THIS handle", which is the whole content of core#152.
      final repl = MontyRepl();
      addTearDown(repl.dispose);
      await repl.feedRun('seed = 7');
      final bytes = await repl.snapshot();

      final restored = MontyRepl();
      addTearDown(restored.dispose);
      await restored.restore(bytes);

      final seed = await restored.feedRun('seed');
      expect(seed.error, isNull);
      expect(seed.value, const MontyInt(7));
    });
  });
}
