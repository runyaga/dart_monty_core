// Conformance for the `with__cm_*` fixtures, which exercise the `with`
// machinery via monty's synthetic `_test_cm()` context manager.
//
// `_test_cm()` only exists when the native crate is built with the
// `test-hooks` cargo feature, so this test is NOT part of the normal suite.
// Run it via the dedicated builder, which compiles the oracle binary AND the
// FFI dylib with `--features test-hooks`:
//
//   bash tool/test_cm.sh
//
// It compares the test-hooks oracle against the test-hooks FFI dylib (the same
// contract as oracle_ffi_test) and asserts `_test_cm` actually resolved — i.e.
// neither side raised `NameError`, proving test-hooks is active. Without the
// dedicated build both sides NameError and the assertions below fail, which is
// the intended guard against running this with a stock build.
@Tags(['integration', 'ffi', 'test-hooks'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:monty_conformance/monty_conformance.dart';
import 'package:test/test.dart';

import '_oracle_runner.dart';

// with__cm_behaviors.py is deliberately absent: it does not exist in the 0.19
// corpus. `fixtureCorpus[name]!` on a missing key is a null-check crash, which
// is what made this file red all session (B3).
const _fixtureNames = [
  'with__cm_context_expr_raises_traceback.py',
  'with__cm_enter_raises_traceback.py',
  'with__cm_exit_raises_normal_exit_traceback.py',
  'with__cm_nested_body_raises_traceback.py',
  'with__cm_traceback.py',
];

void main() {
  // NOT '(test-hooks)' any more. The name outlived the requirement, and a
  // test named for a build it does not need is how this suite got excluded
  // from CI and tool/gate.sh in the first place — for five tests that pass on
  // a stock build.
  group('with__cm', () {
    for (final name in _fixtureNames) {
      test(name, () async {
        final code = fixtureCorpus[name]!;

        final oracleResult = MontyResult.fromJson(
          Map.from(await runOracle(code)),
        );

        final platform = MontyFfi();
        MontyResult? ffiResult;
        String? ffiExcType;
        try {
          ffiResult = await platform.run(code, scriptName: name);
          ffiExcType = ffiResult.error?.excType;
        } on MontyScriptError catch (e) {
          ffiExcType = e.excType;
        } finally {
          await platform.dispose();
        }

        // TWO `isNot('NameError')` guards stood here and are GONE. They
        // checked that `_test_cm` had resolved on both sides, because a
        // NameError meant the binary lacked --features test-hooks.
        //
        // `_test_cm` does not exist in monty v0.0.23 — `grep -rn "_test_cm"
        // crates/monty/src/` at the pinned rev 302e0f2 returns 0 hits, and
        // these fixtures use an ordinary Python `class CM:`. So nothing can
        // raise that NameError any more and neither guard could ever fail
        // again: a guard that cannot fail is not a guard, it is decoration
        // that reads like one. Their `reason` strings were worse than useless
        // — they told a reader to run tool/test_cm.sh, which touches
        // native/.test-hooks and rebuilds the dylib with a feature that is
        // NEVER shipped.
        //
        // The differential below is the real contract and is untouched.

        // Oracle and FFI must agree (same conformance contract as oracle_ffi).
        if (oracleResult.error != null) {
          expect(
            ffiExcType,
            equals(oracleResult.error!.excType),
            reason: 'excType mismatch for $name',
          );
        } else {
          expect(
            ffiResult?.error,
            isNull,
            reason: describeFixtureFailure(name, ffiResult?.error),
          );
          expect(
            ffiResult?.value,
            equals(oracleResult.value),
            reason: 'value mismatch for $name',
          );
        }
      });
    }
  });
}
