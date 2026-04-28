// Run with dart2js:  dart test test/integration/wasm_repl_extfns_lifecycle_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_repl_extfns_lifecycle_test.dart -p chrome --compiler dart2wasm --run-skipped
//
// WASM twin of ffi_repl_extfns_lifecycle_test.dart. The fix lives in
// MontyRepl.feed (Dart), but the symptom surfaces through the Rust
// handle's ext_fn_names HashSet which is identical FFI/WASM. Pin the
// behavior on both backends.
@Tags(['integration', 'wasm'])
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

        await repl.feed(
          'x = fetch(1)',
          externals: {'fetch': (args) async => (args['_0']! as int) * 10},
        );

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

        await repl.feed(
          'x = fetch(7)',
          externals: {'fetch': (args) async => args['_0']},
        );

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

        await repl.feed(
          'r = a(5)',
          externals: {'a': (args) async => (args['_0']! as int) + 1},
        );

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
