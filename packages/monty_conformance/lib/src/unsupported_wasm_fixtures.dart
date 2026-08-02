// Shared skip-sets for the WASM fixture harnesses (wasm_runner.dart,
// wasm_runner_wasm.dart, wasm_fixture_test.dart).

/// Fixtures that never run on the WASM corpus runners, regardless of build:
/// the shared monty wasm32 engine diverges from native here, so it's an
/// upstream concern, not a host-binding gap.
const alwaysUnsupportedWasmFixtures = {
  // Pure-Python range membership at `2**63` (beyond i64). Passes on native FFI;
  // diverges on the web backend — very likely the same JS-boundary precision
  // loss
  // as edge__int_float_mod below (core#128), not an engine difference. Re-check
  // when that is fixed; this may simply start passing.
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
  'recursion__deep_repr.py',
  'recursion__limit_depth.py',
  'json__dumps_recursion.py',
  // Same family, added 2026-08-02. Two self-referential dicts compared for
  // equality must raise RecursionError rather than panic. Measured: PASSES on
  // FFI (ok, no exception), fails in the browser panel. Recursion depth is a
  // property of the host stack, and the web worker's differs -- it is the
  // recursion-limit gap (core#124), not a new defect.
  'dict__eq_self_referential.py',
  // Also listed in [knownBrokenExtFixtures] — it fails on FFI too, so the WASM
  // list alone is not enough.
  // CORRECTED 2026-08-02. The old reason -- "needs an external (`make_point`)
  // the harness does not supply" -- went stale the moment the shared ext-fn
  // table landed: it DOES supply make_point. Unskipping it revealed the real
  // behaviour, which is worse than a missing harness capability: with a
  // correctly-built frozen MontyDataclass returned from the host, the fixture's
  // own `assert repr(point) == 'Point(x=1, y=2)'` fails on FFI with
  // AssertionError. Measured, not inferred. Root cause not yet found -- see
  // FB-10 -- so it stays skipped, but now for the reason that is true.
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

/// Call-external fixtures that fail on EVERY backend, with the reason.
///
/// Separate from [unsupportedWasmFixtures] because that set means "the web
/// diverges here"; this one means "we are wrong everywhere and know it".
/// Conflating them is how `dataclass__basic.py` sat behind a stale
/// web-only skip while nothing ran it on FFI either.
const Map<String, String> knownBrokenExtFixtures = {
  'pathlib__os.py':
      "FB-11: Path('/nonexistent').exists() should be False, but "
      'memoryMountedOsHandler raises "Path is outside any mount" for anything '
      'it does not mount. A query about a path is not an access of it.',
  'pathlib__os_read_error.py': 'FB-11, same cause as pathlib__os.py.',
  'datetime__core.py':
      'The frozen clock the harness supplies (2024-01-15 10:30) does not match '
      'every value this fixture asserts. Needs the exact upstream values, not '
      'a plausible-looking date.',
  'dataclass__basic.py':
      "FB-10: a host-supplied frozen MontyDataclass fails the fixture's own "
      "`repr(point) == 'Point(x=1, y=2)'` assertion on FFI. Measured; root "
      'cause not yet found.',
};
