// Shared skip-sets for the WASM fixture harnesses (wasm_runner.dart,
// wasm_runner_wasm.dart, wasm_fixture_test.dart).

/// Fixtures that never run on the WASM corpus runners, regardless of build:
/// the shared monty wasm32 engine diverges from native here, so it's an
/// upstream concern, not a host-binding gap.
const alwaysUnsupportedWasmFixtures = {
  // Pure-Python range membership at `2**63` (beyond i64). Passes on native FFI;
  // the same monty wasm32 engine diverges.
  'range__ops.py',
  // `int % float` should yield a float (CPython: `7 % 2.5 == 2.0`). Native FFI
  // returns MontyFloat(2.0); the monty wasm32 engine returns MontyInt(2) — an
  // upstream wasm number-coercion divergence. `edge__float_int_mod` (the
  // reverse operand order) is unaffected and still runs.
  'edge__int_float_mod.py',
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
  'recursion__deep_repr.py',
  'recursion__limit_depth.py',
  'json__dumps_recursion.py',
  // Needs an external function (`make_point`) supplied by the harness — the
  // fixture is marked `# call-external`. Same class of gap as core#125: the
  // harness does not provide the capabilities some fixtures require.
  'dataclass__basic.py',
};

/// Fixtures that need monty's synthetic `_test_cm()` context manager, which
/// only exists under the testing-only `test-hooks` cargo feature. They run on
/// the corpus runners ONLY when compiled with `-DMONTY_TEST_HOOKS=true` against
/// a test-hooks WASM binary (see tool/test_cm_wasm.sh) — never in the shipped
/// build. Real `with open(...)` is covered by with__all.py on both backends.
const testHooksWasmFixtures = {
  'with__cm_behaviors.py',
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
