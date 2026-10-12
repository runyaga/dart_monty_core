/// Fixtures the strict adjudicator (S7) exposed as failing, by cause.
///
/// Every entry PASSED before 2026-10-11 only because `# Raise=` and TRACEBACK
/// expectations were matched on the exception TYPE. Each is a binding defect
/// with its cause named; none is fixed here (S7 is instrument-only).
///
/// These are EXPECTED FAILURES, not skips: harnesses run each listed fixture
/// and require that it still fails, so a fix turns the entry stale and red.
/// The shell harnesses declare the same fixtures in
/// tool/wasm-corpus-expected-failures.txt and
/// tool/ffi-corpus-expected-failures.txt; ffi_fixture_corpus_test.dart checks
/// that the two declarations agree.
library;

/// A compile-time exception reaches Dart as TEXT on the one-shot path:
/// `monty_create` writes `exc.summary()` into `out_error`
/// (native/src/lib.rs:127), so the message keeps its `<Type>: ` prefix and
/// every traceback frame is dropped. All backends; the REPL handle reports the
/// same fixtures correctly.
const oneShotCompileErrorDefects = <String>{
  'fstring__error_invalid_spec.py',
  'fstring__error_invalid_spec_str.py',
  'function__err_duplicate_param.py',
  'global__error_assigned_before.py',
  'import__future_unknown_feature.py',
  'import__relative_error.py',
  'import__relative_future_error.py',
  'import__relative_no_module_error.py',
  'import__star_error.py',
  'loop__break_in_function_error.py',
  'loop__break_in_if_error.py',
  'loop__break_outside_error.py',
  'loop__continue_in_function_error.py',
  'loop__continue_in_if_error.py',
  'loop__continue_outside_error.py',
  'nonlocal__error_module_level.py',
  'parse_error__complex.py',
  'traceback__nonlocal_module_scope.py',
};

/// WEB ONLY: a message-less exception (upstream message None) is encoded as
/// `""` (native/src/error.rs:70), and the worker's `err.message || String(err)`
/// (js/src/worker_src.js:71) turns the empty string into `[object Object]`.
const webEmptyMessageDefects = <String>{
  'assert__fail.py',
  'builtin__next_stop_iteration.py',
  'execute_raise__error_no_args.py',
  'execute_raise__error_type.py',
  'execute_raise__raise_type_direct.py',
  'execute_raise__raise_type_via_var.py',
};
