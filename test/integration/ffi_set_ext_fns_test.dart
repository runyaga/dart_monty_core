// ReplBindings.setExtFns — the registration itself, on a real backend.
//
// `setExtFns` was one of the six entry points tool/check_api_exercised.sh
// flagged in 1e4a875. It has two callers inside lib/, so it runs whenever
// MontyRepl.feedStart does — and test/integration/wasm_setextfns_test.dart is
// a regression test for it having been FIRE-AND-FORGET on WASM. But that file
// names it only in comments; nothing drove the method itself.
//
// WHAT IT ACTUALLY CONTROLS, measured rather than assumed. The doc comment
// says "for name resolution" and means it literally:
//
//   source              registered            unregistered
//   ------------------  --------------------  ----------------------------
//   fetch_thing         complete, and the     error: name 'fetch_thing'
//                       value is a function    is not defined
//                       object
//   x = fetch_thing     complete               same NameError
//   fetch_thing(1)      pending                PENDING TOO
//
// THE CALL FORM SUSPENDS EITHER WAY. The engine asks the host about any
// unknown call regardless of registration, so `feedStart('fetch_thing(1)')`
// yielding 'pending' proves NOTHING about setExtFns. The first version of
// this file asserted exactly that and passed its positive case while its
// control failed — the test would have gone green against a setExtFns that
// did nothing at all.
//
// So every case below turns on the NAME form, which is the one that changes.
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/src/ffi/native_bindings_ffi.dart';
import 'package:dart_monty_core/src/repl/ffi_repl_bindings.dart';
import 'package:test/test.dart';

Future<FfiReplBindings> _repl() async {
  final r = FfiReplBindings(bindings: const NativeBindingsFfi());
  await r.create();

  return r;
}

void main() {
  group('ReplBindings.setExtFns on a real backend (FFI)', () {
    test('a registered name RESOLVES, to a function object', () async {
      final repl = await _repl();
      addTearDown(repl.dispose);

      await repl.setExtFns(['fetch_thing']);
      final progress = await repl.feedStart('fetch_thing');

      expect(progress.state, 'complete');
      expect(progress.error, isNull);
      // The engine built a callable for it, which it can only do if the
      // registration reached the interpreter.
      expect(progress.value, isA<Map<String, dynamic>>());
      expect(
        (progress.value! as Map<String, dynamic>)['__type'],
        'function',
      );
    });

    test('an UNregistered name raises NameError — identical source', () async {
      final repl = await _repl();
      addTearDown(repl.dispose);

      // No setExtFns call. This control is what makes the case above
      // evidence: same source, different outcome, one difference.
      final progress = await repl.feedStart('fetch_thing');

      expect(progress.state, 'error');
      expect(progress.error, contains("name 'fetch_thing' is not defined"));
    });

    test(
      'the CALL form suspends whether or not the name is registered',
      () async {
        // Pinned deliberately. This is the trap the first draft fell into, and
        // leaving it unasserted invites the next person to write the same
        // broken test.
        final registered = await _repl();
        addTearDown(registered.dispose);
        await registered.setExtFns(['fetch_thing']);
        final withReg = await registered.feedStart('fetch_thing(1)');

        final bare = await _repl();
        addTearDown(bare.dispose);
        final withoutReg = await bare.feedStart('fetch_thing(1)');

        expect(withReg.state, 'pending');
        expect(withoutReg.state, 'pending');
        expect(withReg.functionName, 'fetch_thing');
        expect(withoutReg.functionName, 'fetch_thing');
      },
    );

    test('setExtFns REPLACES the set rather than adding to it', () async {
      final repl = await _repl();
      addTearDown(repl.dispose);

      await repl.setExtFns(['alpha']);
      await repl.setExtFns(['beta']);

      final beta = await repl.feedStart('beta');
      expect(beta.state, 'complete', reason: 'beta is the current set');

      final alpha = await repl.feedStart('alpha');
      expect(
        alpha.state,
        'error',
        reason: 'the second call replaced the first; alpha is gone',
      );
      expect(alpha.error, contains("name 'alpha' is not defined"));
    });

    test(
      'an empty list de-registers a name that was never evaluated',
      () async {
        final repl = await _repl();
        addTearDown(repl.dispose);

        await repl.setExtFns(['gone']);
        await repl.setExtFns(const []);

        final cleared = await repl.feedStart('gone');

        expect(cleared.state, 'error');
        expect(cleared.error, contains("name 'gone' is not defined"));
      },
    );

    test('but a name already EVALUATED survives de-registration', () async {
      // Not a defect, and worth pinning because it looks like one. Evaluating
      // the name binds it into the REPL SESSION's globals; clearing the
      // registration stops future resolution but does not unbind what the
      // session already holds. Measured — the only difference between this
      // case and the one above is the feedStart in the middle:
      //
      //   register -> clear            -> 'gone'  =>  error
      //   register -> evaluate -> clear -> 'gone'  =>  complete
      //
      // This is the same trap _repl_extfns_lifecycle_test_body.dart:28 warns
      // about from the other side (core#130): a NameError here would look
      // like correct de-registration when it was really a failed
      // registration.
      final repl = await _repl();
      addTearDown(repl.dispose);

      await repl.setExtFns(['gone']);
      expect((await repl.feedStart('gone')).state, 'complete');

      await repl.setExtFns(const []);

      expect((await repl.feedStart('gone')).state, 'complete');
    });
  });
}
