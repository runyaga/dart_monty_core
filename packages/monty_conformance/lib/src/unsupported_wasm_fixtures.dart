// Shared skip-sets for the WASM fixture harnesses (wasm_runner.dart,
// wasm_runner_wasm.dart, wasm_fixture_test.dart).

/// Fixtures that never run on the WASM corpus runners, regardless of build:
/// the shared monty wasm32 engine diverges from native here, so it's an
/// upstream concern, not a host-binding gap.
const alwaysUnsupportedWasmFixtures = <String>{
  // Range arithmetic at the i64 boundary. RE-CHECKED 2026-08-03, un-skipped and
  // run on both web backends — the skip is real, but the reason it carried was
  // wrong, so the evidence is recorded here instead of a hypothesis.
  //
  //     FFI (native)   PASSES   (oracle_ffi +361 -> +362)
  //     dart2js        FAILS    "expected no error, got AssertionError"
  //     dart2wasm      FAILS    identically, same reason string
  //
  // The old note guessed "very likely the same JS-boundary precision loss as
  // edge__int_float_mod (core#128)". That is refuted: core#128 is fixed in 0.19
  // and dart2wasm has real 64-bit ints, so a JS-boundary explanation predicts
  // dart2wasm PASSES. It fails identically. What both web backends share is the
  // wasm32 engine, not a Dart number representation — so this is the upstream
  // wasm32 build, as this set's docstring says, and NOT core#128.
  //
  // Note the fixture EXPECTS an OverflowError at lines 99-103 and catches it;
  // that arm is correct behaviour on FFI and is not the failure. Which of the
  // ~278 assertions diverges has not been bisected in-browser yet.
  'range__ops.py',
  // edge__int_float_mod.py was here, blamed on the web backend. It was never
  // the backend: `run('7 % 2.5')` returns {"__type":"float","value":"2.0"} over
  // the bridge, correctly. The harness built its expectation with
  // MontyValue.fromDart(2.0), which is MontyInt(2) on dart2js, so a right
  // answer was checked against a broken yardstick. Fixed in the parser (#142).
  // ---- added with the monty v0.0.19 corpus (531 fixtures, was 482) --------
  // Four names were added to THIS set when the corpus symlink was repointed
  // from v0.0.18 to v0.0.19. None of them is still here: the three
  // `sys.setrecursionlimit` fixtures moved to [setRecursionLimitFixtures]
  // below, because the gate is the cargo feature and not the backend, and
  // dict__eq_self_referential.py was removed outright (see the next note).
  //
  // The reason those three carried is recorded as REFUTED rather than deleted,
  // because it is still repeated elsewhere: it said the blocker was that "our
  // REPL path constructs `NoLimitTracker`" while `recursion_limit_override`
  // lives on `LimitedTracker`. The source says otherwise — BOTH handles use
  // `LimitedTracker` (`native/src/repl_handle.rs:30`, `native/src/handle.rs:19`,
  // and repl_handle.rs:18 records that it "was `NoLimitTracker`"). What is
  // actually unbounded is the DEFAULT: `ResourceLimits::default()` has every
  // field `None`, so a REPL session created without limits behaves as
  // `NoLimitTracker` did (repl_handle.rs:23-25). Same symptom, different cause,
  // and the difference decides the fix — a tracker swap would be wasted work.
  // dict__eq_self_referential.py was here, added 2026-08-02 on the claim that
  // it "fails in the browser panel". Removed 2026-08-03: the claim was stale
  // and nothing re-checked it, because a skipped fixture is a fixture nobody
  // runs. Measured with it un-skipped, both backends, 0 failures:
  //     dart2js    519 -> 520 passed, 12 -> 11 skipped
  //     dart2wasm  519 -> 520 passed, 12 -> 11 skipped
  // That is the second entry in this file whose stated reason did not survive
  // being tested -- see dataclass__basic.py below, where BOTH reasons were
  // wrong. A skip needs a re-check date or a test, not a rationale.
  //
  // Its real subject is still open, and is NOT a web divergence: the fixture's
  // comment says "Monty must not panic", and on FFI `Monty(code).run()` exits
  // 132 (SIGILL) on this input while `MontyFfi().run()` raises RecursionError
  // correctly. The one-line API builds a MontyRepl with NO limits, and an
  // unlimited REPL session is unbounded — not because of the tracker TYPE (see
  // the refuted note above) but because `ResourceLimits::default()` sets no
  // limits at all.
  //
  // It is also not alone. Sweeping all 531 fixtures through a bare
  // `MontyRepl()` on 2026-08-03 found FIVE that kill the host process —
  // list__eq_self_referential.py, recursion__deep_hash.py,
  // recursion__deep_isinstance.py and traceback__recursion_error.py (exit 137,
  // memory) alongside this one. All five pass on a BOUNDED session and all
  // five pass one-shot. Tracked separately; it is a host-process-death bug,
  // not a conformance skip. See the blast-radius note in
  // test/integration/ffi_repl_corpus_test.dart.
  // dataclass__basic.py was here. It is NOT skipped any more -- see FB-10.
  // Both reasons it carried were wrong. It never needed an external the
  // harness withholds, and it never failed its `repr()` assert; repr was
  // correct all along. The two real causes were both in this harness:
  // every host dataclass was built with `typeId: 0`, so `Point` and
  // `MutablePoint` compared equal and `assert point != mut_point` (line 55)
  // failed; and an undeclared method call was answered with `resumeNotFound`,
  // which raises NameError where the fixture requires AttributeError.
  // Fixed in fixture_externals.dart and fixture_dispatch.dart; it now passes
  // end to end on FFI and on both web targets.
};

/// Fixtures that call `sys.setrecursionlimit` themselves.
///
/// `sys.setrecursionlimit` exists only under the testing-only `test-hooks`
/// cargo feature (monty/src/modules/sys.rs:86). Nothing else is required of the
/// host — each of these calls it at the top of the file, and without the
/// feature the call raises
/// `AttributeError: module 'sys' has no attribute 'setrecursionlimit'`.
///
/// **The gate is the CARGO FEATURE, not the backend.** These are a subset of
/// [testHooksWasmFixtures], which is named for the web because that is where
/// they were first skipped, but they fail identically on native FFI — measured
/// 2026-08-02 by running the corpus through the REPL handle against the
/// fixtures' own `# Return=` / `# Raise=` directives
/// (test/integration/ffi_repl_corpus_test.dart). It is invisible to
/// `oracle_ffi_test.dart` only because that harness is DIFFERENTIAL: the oracle
/// binary is built without the feature too, so both sides raise the same
/// AttributeError and agree.
///
/// So any harness asserting against the STATIC directives — on either backend —
/// must skip these unless it was built with `--features test-hooks`.
///
/// They used to sit in [alwaysUnsupportedWasmFixtures] — never run ANYWHERE —
/// on a recorded reason that was half false: it said our REPL path constructs
/// `NoLimitTracker` so the limit could not be lowered. Verified 2026-08-02:
/// both handles construct `LimitedTracker` (native/src/repl_handle.rs:30,
/// native/src/handle.rs:19). That ValueError is unreachable. Only the cargo
/// feature was ever the blocker, and `tool/test_cm_wasm.sh` supplies it.
///
/// They stay skipped in the SHIPPED demo, which is correct: enabling
/// test-hooks there would ship `sys.setrecursionlimit` into the sandbox
/// (native/Cargo.toml:37 — "NEVER enabled in shipped builds").
const setRecursionLimitFixtures = {
  'recursion__deep_repr.py',
  'recursion__limit_depth.py',
  'json__dumps_recursion.py',
};

/// Fixtures that need monty's synthetic `_test_cm()` context manager, which
/// only exists under the testing-only `test-hooks` cargo feature. They run on
/// the corpus runners ONLY when compiled with `-DMONTY_TEST_HOOKS=true` against
/// a test-hooks WASM binary (see tool/test_cm_wasm.sh) — never in the shipped
/// build. Real `with open(...)` is covered by with__all.py on both backends.
///
/// MEASURED 2026-08-03 on BOTH web compilers, all eight passing:
///
///     test-hooks off   520 passed / 11 skipped   (tool/test_wasm.sh)
///     test-hooks on    528 passed /  3 skipped   (tool/test_cm_wasm.sh)
///
/// dart2js and dart2wasm agree exactly. Worth recording because until
/// `tool/test_cm_wasm.sh --dart2wasm` existed these eight had never executed on
/// dart2wasm anywhere — that script was the only harness that could run them
/// and it had only a `dart compile js` path, so "runs on the corpus runners"
/// was true of one of the two. Both are gate steps now (`corpus_cm_js`,
/// `corpus_cm_w`).
///
/// Split from [setRecursionLimitFixtures] because the two need DIFFERENT things
/// from the same cargo feature, and only one of them fails on native as well.
const testCmFixtures = {
  // with__cm_behaviors.py was here and DOES NOT EXIST UPSTREAM — the 0.19
  // corpus has 531 fixtures and that is not one of them. A dead skip entry is
  // not inert: ffi_with_cm_test.dart drove the same hardcoded list and crashed
  // on `fixtureCorpus[name]!` for the missing key, which is B3, and is why CI
  // excludes that file (ci.yaml:439).
  'with__cm_context_expr_raises_traceback.py',
  'with__cm_enter_raises_traceback.py',
  'with__cm_exit_raises_normal_exit_traceback.py',
  'with__cm_nested_body_raises_traceback.py',
  'with__cm_traceback.py',
};

/// Everything gated behind the `test-hooks` cargo feature on the WASM runners.
///
/// Composed of the two finer sets above, and the split is not cosmetic:
/// measured on 2026-08-03, `testCmFixtures` PASS on web with no test-hooks
/// build, while `setRecursionLimitFixtures` genuinely need it. Naming them
/// apart is what makes that difference sayable.
const Set<String> testHooksWasmFixtures = {
  ...setRecursionLimitFixtures,
  ...testCmFixtures,
};

// The `unsupportedWasmFixtures` UNION was here and is DELETED.
//
// It merged two claims that need different handling, and the merge produced
// wrong answers rather than merely vague ones:
//
//   alwaysUnsupportedWasmFixtures  "diverges on web"  -> falsifiable: RUN it
//   testHooksWasmFixtures          "needs an unshipped cargo feature"
//                                                     -> not falsifiable by
//                                                        running it at all
//
// Measured: with the union driving the expectation, the five with__cm_*
// fixtures reported as STALE web divergences, because they pass on web with no
// test-hooks build. They are not divergences and never were — the union just
// could not say so. Consumers now name the set they mean.

/// Call-external fixtures that fail on EVERY backend, with the reason.
///
/// Separate from [alwaysUnsupportedWasmFixtures] because that set means "the
/// web diverges here"; this one means "we are wrong everywhere and know it".
/// Conflating them is how `dataclass__basic.py` sat behind a stale
/// web-only skip while nothing ran it on FFI either.
const Map<String, String> knownBrokenExtFixtures = {
  // monty v0.0.23 regression: dataclass attribute errors are not surfaced as
  // exceptions through the external-function dispatch path.
  // Observed in dart_monty_core gate (oracle_ffi_ext_test.dart):
  // excType is null.
  'dataclass__call_field_error.py':
      'monty v0.0.23: calling a dataclass field does not raise '
      'TypeError (excType is null)',
  'dataclass__get_missing_attr_error.py':
      'monty v0.0.23: missing dataclass attribute does not raise '
      'AttributeError (excType is null)',
};
