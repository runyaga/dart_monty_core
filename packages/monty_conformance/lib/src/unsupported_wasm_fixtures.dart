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
  // These four arrived when the corpus symlink was repointed from v0.0.18 to
  // v0.0.19. All four fail IDENTICALLY on the 0.18 reference oracle and on
  // 0.19, so none is a 0.19 regression — they are pre-existing harness gaps
  // that the larger corpus made visible.
  //
  // Three need `sys.setrecursionlimit`, which is gated behind the
  // `test-hooks` cargo feature AND requires a tracker exposing a settable
  // recursion limit. Under a test-hooks build they get as far as
  //   ValueError: sys.setrecursionlimit: this runtime does not expose a
  //               settable recursion limit
  // because our REPL path constructs `NoLimitTracker`;
  // `recursion_limit_override`
  // lives on `LimitedTracker`. Unblocked by core#124 (FB-1), not by anything in
  // the 0.19 upgrade.
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
  // correctly. The one-line API builds a MontyRepl, and the REPL path uses
  // NoLimitTracker. Tracked separately; it is a host-process-death bug, not a
  // conformance skip.
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
/// and it only had a `dart compile js` path, so "runs on the corpus runners"
/// was true of one of the two. Both are gate steps now (`corpus_cm_js`,
/// `corpus_cm_w`).
const testHooksWasmFixtures = {
  // Gated ONLY by the `test-hooks` cargo feature, which is what supplies
  // `sys.setrecursionlimit` (monty/src/modules/sys.rs:86). Each of these calls
  // it themselves at the top of the file; nothing else is required of the host.
  //
  // They used to sit in [alwaysUnsupportedWasmFixtures] — never run ANYWHERE —
  // on a recorded reason that was half false: it said our REPL path constructs
  // `NoLimitTracker` so the limit could not be lowered. Verified 2026-08-02:
  // both handles construct `LimitedTracker` (native/src/repl_handle.rs:30,
  // native/src/handle.rs:19), and the corpus never uses the REPL at all — it
  // runs one-shot through handle.rs. That ValueError is unreachable. Only the
  // cargo feature was ever the blocker, and `tool/test_cm_wasm.sh` supplies it.
  //
  // They stay skipped in the SHIPPED demo, which is correct: enabling
  // test-hooks there would ship `sys.setrecursionlimit` into the sandbox
  // (native/Cargo.toml:37 — "NEVER enabled in shipped builds").
  'recursion__deep_repr.py',
  'recursion__limit_depth.py',
  'json__dumps_recursion.py',
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

/// Union of both — fixtures skipped under a normal (no-test-hooks) WASM build.
const Set<String> unsupportedWasmFixtures = {
  ...alwaysUnsupportedWasmFixtures,
  ...testHooksWasmFixtures,
};

/// Call-external fixtures that fail on EVERY backend, with the reason.
///
/// Separate from [unsupportedWasmFixtures] because that set means "the web
/// diverges here"; this one means "we are wrong everywhere and know it".
/// Conflating them is how `dataclass__basic.py` sat behind a stale
/// web-only skip while nothing ran it on FFI either.
const Map<String, String> knownBrokenExtFixtures = {};
