// Shared test body for ffi_repl_preamble_test.dart and
// wasm_repl_preamble_test.dart.
//
// `MontyRepl(preamble:)` is public and documented ("Python code fed into the
// REPL before any user calls") and no test exercised it. The expected values
// are plain Python semantics, not read back from this package.

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void runReplPreambleTests() {
  group('MontyRepl preamble', () {
    test(
      'definitions from the preamble are visible to the first feed',
      () async {
        final repl = MontyRepl(
          preamble: 'def double(n):\n    return n * 2\n\nbase = 20\n',
        );
        addTearDown(repl.dispose);

        final r = await repl.feedRun('double(base) + 2');
        expect(
          r.error,
          isNull,
          reason: 'NameError means the preamble never ran',
        );
        expect(r.value, MontyValue.fromDart(42));
      },
    );

    test('the preamble runs once, not before every feed', () async {
      final repl = MontyRepl(preamble: 'n = 0\n');
      addTearDown(repl.dispose);

      for (var feed = 0; feed < 2; feed++) {
        await repl.feedRun('n += 1');
      }
      final r = await repl.feedRun('n');
      expect(
        r.value,
        MontyValue.fromDart(2),
        reason: 'a preamble re-run per feed would reset n to 0',
      );
    });
  });
}
