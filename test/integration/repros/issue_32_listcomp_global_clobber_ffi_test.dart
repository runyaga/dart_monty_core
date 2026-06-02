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
        final repl = MontyRepl();
        try {
          // FEED 1: first list-comp call.
          await repl.feedRun(
            'results = [sync_fn() for _ in range(10)]',
            externalFunctions: externals(),
          );
          // FEED 2: second list-comp call — previously clobbered the global
          // `sync_fn` to int (issue #32); fixed in monty 0.18.
          await repl.feedRun(
            'results = [sync_fn() for _ in range(5)]',
            externalFunctions: externals(),
          );
          // FEED 3: probe — sync_fn is still a function.
          final probe = await repl.feedRun(
            'type(sync_fn).__name__',
            externalFunctions: externals(),
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
      final repl = MontyRepl();
      try {
        await repl.feedRun(
          'results = [sync_fn() for _ in range(10)]',
          externalFunctions: externals(),
        );
        await repl.feedRun(
          'results = [sync_fn() for _ in range(5)]',
          externalFunctions: externals(),
        );

        // Previously raised `TypeError: 'int' object is not callable` once the
        // global was clobbered (issue #32); fixed in monty 0.18.
        final after = await repl.feedRun(
          'sync_fn()',
          externalFunctions: externals(),
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
