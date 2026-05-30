// Shared skip-set for the WASM fixture harnesses (wasm_runner.dart,
// wasm_runner_wasm.dart, wasm_fixture_test.dart).
//
// These v0.0.18 corpus fixtures exercise interpreter features not yet wired
// into the WASM binding. They are skipped (not failed) until support lands;
// tracked in the CHANGELOG. Remove entries as each gap is closed.

const Set<String> unsupportedWasmFixtures = {
  // Exhaustive `open()` fixtures: pass on FFI, but the corpus runner still
  // diverges on binary-buffer / seek edge cases (open__fs) and Windows
  // text-encoding specifics (open__fs_windows). Core file I/O is covered by
  // with__all.py (un-skipped) and wasm_open_test.dart.
  'open__fs.py',
  'open__fs_windows.py',
  // Context-manager behaviors driven by the synthetic `_test_cm()` hook, which
  // only exists when the native crate is built with the `test-hooks` cargo
  // feature (not enabled in the shipped build) — fixtures NameError otherwise.
  'with__cm_behaviors.py',
  'with__cm_context_expr_raises_traceback.py',
  'with__cm_enter_raises_traceback.py',
  'with__cm_exit_raises_normal_exit_traceback.py',
  'with__cm_nested_body_raises_traceback.py',
  'with__cm_traceback.py',
  // Cyclic containers: FFI produces the correct cyclic value; only the WASM
  // fixture comparison mismatches the `[[...]]` cycle repr.
  'pyobject__cycle_dict_self.py',
  'pyobject__cycle_list_dict.py',
  'pyobject__cycle_list_self.py',
  'pyobject__cycle_multiple_refs.py',
  // dart2js divergence on `2**63`-scale range membership (big-int boundary).
  'range__ops.py',
};
