// Shared test body for ffi_repl_extfns_lifecycle_test.dart and
// wasm_repl_extfns_lifecycle_test.dart.
//
// Pins the fix that makes MontyRepl.feed re-sync ext_fn_names on every
// call so leaked names from earlier feeds raise a clean Python NameError
// instead of "no handler registered". The bug surfaces through the Rust
// handle, which is identical FFI/WASM, so both backends share these
// scenarios.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runReplExtFnsLifecycleTests() {
  group('MontyRepl externals lifecycle', () {
    test(
      'name registered in feed N is gone in feed N+1 with empty externals',
      () async {
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        // Feed 1: register `fetch`, call it.
        await repl.feed(
          'x = fetch(1)',
          externalFunctions: {
            'fetch': (args) async => (args['_0']! as int) * 10,
          },
        );

        // Feed 2: no externalFunctions. The leftover `fetch` name must
        // NOT be resolvable — Python should raise NameError on the fast
        // path.
        await expectLater(
          repl.feed('y = fetch(2)'),
          throwsA(
            isA<MontyScriptError>().having(
              (e) => e.excType,
              'excType',
              'NameError',
            ),
          ),
        );
      },
    );

    test(
      'fast-path feed clears externals from a prior iterative feed',
      () async {
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        // Iterative path: register `fetch`.
        await repl.feed(
          'x = fetch(7)',
          externalFunctions: {'fetch': (args) async => args['_0']},
        );

        // Fast-path feed (no externalFunctions, no osHandler) sandwiched
        // in between. The handle's ext_fn_names must be cleared before
        // this feed runs, so a subsequent iterative feed without `fetch`
        // raises NameError.
        await repl.feed('y = x + 1');

        await expectLater(
          repl.feed('z = fetch(99)'),
          throwsA(
            isA<MontyScriptError>().having(
              (e) => e.excType,
              'excType',
              'NameError',
            ),
          ),
        );
      },
    );

    test(
      'replacing externals between feeds invalidates the old name',
      () async {
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        // Feed 1: register `a`.
        await repl.feed(
          'r = a(5)',
          externalFunctions: {'a': (args) async => (args['_0']! as int) + 1},
        );

        // Feed 2: register `b` instead. `a` must no longer resolve when
        // referenced again.
        await repl.feed(
          'r = b(5)',
          externalFunctions: {'b': (args) async => (args['_0']! as int) * 2},
        );

        await expectLater(
          repl.feed('r = a(5)'),
          throwsA(
            isA<MontyScriptError>().having(
              (e) => e.excType,
              'excType',
              'NameError',
            ),
          ),
        );
      },
    );
  });
}
