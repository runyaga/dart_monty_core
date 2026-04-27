// Integration test: MontyRepl.feed re-syncs ext_fn_names on every call.
//
// Before this fix, MontyRepl.feed only called setExtFns on the iterative
// path. The Rust handle's persistent ext_fn_names HashSet then leaked
// names from earlier feeds into later feeds, surfacing as a confusing
// "No handler registered for: <name>" error instead of a clean Python
// NameError. The fix moves setExtFns to the top of feed() so it runs on
// every invocation, including the fast path and including with [] when
// externals is empty.
//
// Run: dart test test/integration/ffi_repl_extfns_lifecycle_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('MontyRepl externals lifecycle', () {
    test(
      'name registered in feed N is gone in feed N+1 with empty externals',
      () async {
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        // Feed 1: register `fetch`, call it.
        await repl.feed(
          'x = fetch(1)',
          externals: {'fetch': (args) async => (args['_0']! as int) * 10},
        );

        // Feed 2: no externals. The leftover `fetch` name must NOT be
        // resolvable — Python should raise NameError on the fast path.
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
          externals: {'fetch': (args) async => args['_0']},
        );

        // Fast-path feed (no externals, no osHandler) sandwiched in
        // between. The handle's ext_fn_names must be cleared before
        // this feed runs, so a subsequent iterative feed without
        // `fetch` raises NameError.
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
          externals: {'a': (args) async => (args['_0']! as int) + 1},
        );

        // Feed 2: register `b` instead. `a` must no longer resolve when
        // referenced again.
        await repl.feed(
          'r = b(5)',
          externals: {'b': (args) async => (args['_0']! as int) * 2},
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
