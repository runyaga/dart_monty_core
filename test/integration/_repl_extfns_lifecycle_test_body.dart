// Shared test body for ffi_repl_extfns_lifecycle_test.dart and
// wasm_repl_extfns_lifecycle_test.dart.
//
// Pins the fix that makes MontyRepl.feedRun re-sync ext_fn_names on
// every call so leaked names from earlier feeds raise a clean Python
// NameError instead of "no handler registered". The bug surfaces
// through the Rust handle, which is identical FFI/WASM, so both
// backends share these scenarios.

import 'package:collection/collection.dart';
import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';
import '../_accessors.dart';

void runReplExtFnsLifecycleTests() {
  group('MontyRepl externals lifecycle', () {
    test(
      'name registered in feed N is gone in feed N+1 with empty externals',
      () async {
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        // Feed 1: register `fetch`, call it.
        //
        // The result is asserted deliberately (core#130). Without this, the
        // test passes even when registration never worked at all: feed 1
        // would error unnoticed and feed 2's NameError would look like
        // correct de-registration. `setExtFns(const [])` passed this test.
        final r1 = await repl.feedRun(
          'x = fetch(1)\nx',
          externalFunctions: {
            'fetch': (args, _) => callbackArg<int>(args, 0) * 10,
          },
        );
        expect(
          r1.error,
          isNull,
          reason:
              'registration itself must succeed before de-registration '
              'can mean anything',
        );
        expect(
          r1.value,
          equals(MontyValue.fromDart(10)),
          reason: 'the registered external must actually have been called',
        );

        // Feed 2: no externalFunctions. The leftover `fetch` name must
        // NOT be resolvable — Python should raise NameError on the
        // fast path.
        final r = await repl.feedRun('y = fetch(2)');
        expect(r.error?.excType, 'NameError');
      },
    );

    test(
      'fast-path feed clears externals from a prior iterative feed',
      () async {
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        // Iterative path: register `fetch`.
        await repl.feedRun(
          'x = fetch(7)',
          externalFunctions: {
            'fetch': (args, _) => Future.value(args.firstOrNull),
          },
        );

        // Fast-path feed (no externalFunctions, no osHandler)
        // sandwiched in between. The handle's ext_fn_names must be
        // cleared before this feed runs, so a subsequent iterative
        // feed without `fetch` raises NameError.
        await repl.feedRun('y = x + 1');

        final r = await repl.feedRun('z = fetch(99)');
        expect(r.error?.excType, 'NameError');
      },
    );

    test(
      'replacing externals between feeds invalidates the old name',
      () async {
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        // Feed 1: register `a`. The result is ASSERTED, not discarded --
        // codex found that dropping it lets the callback fail unnoticed. A
        // failure inside a host callback does not fail the test on its own:
        // monty_repl.dart:554 catches it and hands it to the sandbox as a
        // script error, so the only way it becomes visible is to look at what
        // the feed returned.
        final feed1 = await repl.feedRun(
          'r = a(5)\nr',
          externalFunctions: {
            'a': (args, _) => callbackArg<int>(args, 0) + 1,
          },
        );
        expect(feed1.error, isNull, reason: 'feed 1 must not error');
        expect(feed1.value, const MontyInt(6), reason: 'a(5) is 5 + 1');

        // Feed 2: register `b` instead. `a` must no longer resolve
        // when referenced again. Asserted for the same reason.
        final feed2 = await repl.feedRun(
          'r = b(5)\nr',
          externalFunctions: {
            'b': (args, _) => callbackArg<int>(args, 0) * 2,
          },
        );
        expect(feed2.error, isNull, reason: 'feed 2 must not error');
        expect(feed2.value, const MontyInt(10), reason: 'b(5) is 5 * 2');

        final r = await repl.feedRun('r = a(5)');
        expect(r.error?.excType, 'NameError');
      },
    );
  });
}
