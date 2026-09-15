// Repro: dart_monty_core#32 — host function global binding clobbered to
// int after repeat list-comprehension calls on a persistent MontyRepl.
//
// Side-loadable companion: test/fixtures/repros/issue_32_listcomp_global_clobber.py
//   $ python3 test/fixtures/repros/issue_32_listcomp_global_clobber.py
//   function     # reference behavior
//
// This test replays the same feed sequence on `MontyRepl` (FFI backend) with
// `sync_fn` registered as an external and asserts the reference behavior
// (`type(sync_fn).__name__ == 'function'`, `sync_fn()` still callable). The
// bug was fixed in monty 0.18; this was previously an xfail() and is now a
// straight regression test.
//
// Run:
//   dart test test/integration/repros/issue_32_listcomp_global_clobber_ffi_test.dart \
//     -p vm --run-skipped --tags=ffi --reporter=expanded
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('issue #32 — list-comp external survives repeat feedRun calls', () {
    Map<String, MontyCallback> externals() => {
      'sync_fn': (_, _) async => 'sync_ok',
    };

    test(
      'type(sync_fn).__name__ stays "function" after two list-comp feeds',
      () async {
        // ONE map per test, not per feed. Traced before hoisting: feedRun reads
        // `.keys` and looks names up in _driveLoop; it never assigns the map to
        // a field, mutates it, or compares identity. So map identity cannot
        // reach the interpreter, and sharing one across the feeds in a single
        // test cannot mask the cross-feed contamination this file exists to
        // catch. Kept per-TEST so the tests stay independent of each other.
        final fns = externals();
        final repl = MontyRepl();
        try {
          // FEED 1: first list-comp call.
          await repl.feedRun(
            'results = [sync_fn() for _ in range(10)]',
            externalFunctions: fns,
          );
          // FEED 2: second list-comp call — previously clobbered the global
          // `sync_fn` to int (issue #32); fixed in monty 0.18.
          await repl.feedRun(
            'results = [sync_fn() for _ in range(5)]',
            externalFunctions: fns,
          );
          // FEED 3: probe — sync_fn is still a function.
          final probe = await repl.feedRun(
            'type(sync_fn).__name__',
            externalFunctions: fns,
          );

          expect(
            probe.value,
            isA<MontyString>().having((s) => s.value, 'value', 'function'),
            reason:
                'sync_fn should remain a callable after repeated list-comp '
                'invocations across feedRun calls.',
          );
        } finally {
          await repl.dispose();
        }
      },
    );

    test('sync_fn() remains callable after two list-comp feeds', () async {
      // Per-test map; see the note in the test above.
      final fns = externals();
      final repl = MontyRepl();
      try {
        await repl.feedRun(
          'results = [sync_fn() for _ in range(10)]',
          externalFunctions: fns,
        );
        await repl.feedRun(
          'results = [sync_fn() for _ in range(5)]',
          externalFunctions: fns,
        );

        // Previously raised `TypeError: 'int' object is not callable` once the
        // global was clobbered (issue #32); fixed in monty 0.18.
        final after = await repl.feedRun(
          'sync_fn()',
          externalFunctions: fns,
        );
        expect(
          after.error,
          isNull,
          reason: 'sync_fn should still be callable.',
        );
        expect(
          after.value,
          isA<MontyString>().having((s) => s.value, 'value', 'sync_ok'),
        );
      } finally {
        await repl.dispose();
      }
    });
  });
}
