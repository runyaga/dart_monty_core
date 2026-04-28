// Repro: dart_monty_core#32 — host function global binding clobbered to
// int after repeat list-comprehension calls on a persistent MontyRepl.
//
// Side-loadable companion: test/fixtures/repros/issue_32_listcomp_global_clobber.py
//   $ python3 test/fixtures/repros/issue_32_listcomp_global_clobber.py
//   function     # reference behavior
//
// This test replays the same feed sequence on `MontyRepl` (FFI backend) with
// `sync_fn` registered as an external. The body asserts the *expected
// reference behavior* (`type(sync_fn).__name__ == 'function'`) wrapped in
// xfail() — so today the test passes precisely because the inner assertion
// fails (the bug reproduces). When the bug is fixed and the inner assertion
// starts passing, xfail() raises and CI flags the test for promotion.
//
// Run:
//   dart test test/integration/repros/issue_32_listcomp_global_clobber_ffi_test.dart \
//     -p vm --run-skipped --tags=ffi --reporter=expanded
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

import '_xfail.dart';

void main() {
  group('issue #32 — list-comp external survives repeat feedRun calls', () {
    Map<String, MontyCallback> externals() => {
      'sync_fn': (_) async => 'sync_ok',
    };

    test(
      'type(sync_fn).__name__ stays "function" after two list-comp feeds',
      () async {
        await xfail('#32', () async {
          final repl = MontyRepl();
          try {
            // FEED 1: first list-comp call — establishes the bug condition.
            await repl.feedRun(
              'results = [sync_fn() for _ in range(10)]',
              externalFunctions: externals(),
            );
            // FEED 2: second list-comp call — bug triggers on the actual
            // (broken) backend; the global `sync_fn` gets clobbered to int.
            await repl.feedRun(
              'results = [sync_fn() for _ in range(5)]',
              externalFunctions: externals(),
            );
            // FEED 3: probe.
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
        });
      },
    );

    test('sync_fn() remains callable after two list-comp feeds', () async {
      await xfail('#32', () async {
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

          // After the bug fires, this raises:
          //   TypeError: 'int' object is not callable
          final after = await repl.feedRun(
            'sync_fn()',
            externalFunctions: externals(),
          );
          expect(
            after.error,
            isNull,
            reason:
                'sync_fn should still be callable. Currently observed: '
                "TypeError: 'int' object is not callable.",
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
  });
}
