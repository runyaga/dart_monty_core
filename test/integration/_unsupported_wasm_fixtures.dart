// Shared skip-set for the WASM fixture harnesses (wasm_runner.dart,
// wasm_runner_wasm.dart, wasm_fixture_test.dart).
//
// These corpus fixtures depend on capabilities outside the host binding's
// reach. They are skipped (not failed); tracked in the CHANGELOG. Remove
// entries if/when the underlying capability lands.

const Set<String> unsupportedWasmFixtures = {
  // Synthetic context-manager (`_test_cm()`): only exists under monty's
  // testing-only `test-hooks` cargo feature, never in the shipped binary the
  // WASM runners use. These have dedicated FFI conformance via a marker-gated
  // test-hooks build — `bash tool/test_cm.sh` (ffi_with_cm_test.dart). A WASM
  // equivalent would need a separate staged test-hooks wasm. Real
  // `with open(...)` is covered by with__all.py on both backends.
  'with__cm_behaviors.py',
  'with__cm_context_expr_raises_traceback.py',
  'with__cm_enter_raises_traceback.py',
  'with__cm_exit_raises_normal_exit_traceback.py',
  'with__cm_nested_body_raises_traceback.py',
  'with__cm_traceback.py',
  // Pure-Python range membership at `2**63` (beyond i64). The same monty
  // engine runs on both backends, so this is an upstream wasm32 big-int
  // divergence (passes on native FFI), not a host-binding gap.
  'range__ops.py',
};
