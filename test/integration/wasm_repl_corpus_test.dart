// The WASM half of `test/integration/ffi_repl_corpus_test.dart` — and the
// reason it cannot exist yet.
//
// This repo's standing rule is that a feature needs BOTH runners: a
// `ffi_*_test.dart` with no `wasm_*_test.dart` pair has shipped twice with the
// web side covered by nothing (see AGENTS.md, "Test layout", and the UNLISTED
// guard in tool/test_wasm_unit.sh). The REPL corpus runner is FFI-only, so this
// file has to say why, and it has to say it in a way that stops being true on
// its own.
//
// THE BLOCKER: core#140. `WasmReplBindings.create` throws on ANY `limitsJson`
// (lib/src/repl/wasm_repl_bindings.dart), so a REPL SESSION on the web cannot
// carry resource limits. The FFI runner depends on exactly that: it constructs
// `MontyRepl(limits: …)` to put the REPL session on the same footing as the
// one-shot handle, because a bare `MontyRepl()` is UNBOUNDED while every
// one-shot run is bounded at 256 MB / depth 1000. Without limits the corpus's
// recursion fixtures cannot produce their declared `RecursionError`, and a
// difference in RESULT would be attributable to a difference in
// CONFIGURATION — which is the one thing that runner exists to rule out.
//
// So this is a TRIPWIRE, not a placeholder. It asserts the blocker is still
// there. When core#140 lands, this test goes RED, and the fix is not to delete
// it — it is to build the real WASM corpus runner beside the FFI one.
//
// Run with dart2js:  dart test test/integration/wasm_repl_corpus_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_repl_corpus_test.dart -p chrome --compiler dart2wasm --run-skipped
@Tags(['integration', 'wasm'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('wasm_repl_corpus', () {
    test(
      'session limits still throw on the web — core#140 blocks this suite',
      () async {
        final repl = MontyRepl(
          limits: const MontyLimits(
            memoryBytes: 256 * 1024 * 1024,
            stackDepth: 1000,
          ),
        );
        addTearDown(repl.dispose);

        await expectLater(
          repl.feedRun('x = 1'),
          throwsA(
            isA<UnsupportedError>().having(
              (e) => e.message,
              'message',
              contains('core#140'),
            ),
          ),
          reason:
              'core#140 appears to be FIXED. Do not delete this test — port '
              'test/integration/ffi_repl_corpus_test.dart to the web: give it '
              'the same MontyRepl(limits: …) session, run it through '
              'tool/test_wasm_unit.sh, and keep its knownReplDivergentFixtures '
              'list separate, because the web engine has its own divergences '
              '(see unsupportedWasmFixtures).',
        );
      },
    );

    test(
      'a bare MontyRepl() DOES work on the web — the gap is limits only',
      () async {
        // Bounds the claim above. The web REPL is not broken; it is unbounded.
        // Without this, "core#140 blocks the corpus runner" could be read as
        // "the web REPL does not run", which would be false and would send the
        // next reader looking in the wrong place.
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        expect((await repl.feedRun('1 + 1')).value, const MontyInt(2));
      },
    );
  });
}
