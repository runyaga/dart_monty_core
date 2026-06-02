# Changelog

## 0.18.1

### Added

- **`open()` / file I/O.** `memoryMountedOsHandler` now services the `Open`
  OS-call (existence-check for `r`/`rb`, truncate-create for `w`/`wb`,
  create-preserving for `a`/`ab`) and the `append_text`/`append_bytes`
  calls the interpreter emits. Python can `open()` files, read/write/append,
  and use `with open(...) as f:` against an in-memory mount. A new
  **`MontyFileHandle`** `MontyValue` represents the returned file object.
- **`resolveOpenCall(...)`** — the store-agnostic `open()` primitive that owns
  the mode→effect mapping (existence-check / truncate / create → file handle,
  with typed errors). `memoryMountedOsHandler` delegates to it, and any
  `OsCallHandler` (e.g. a `package:file`-backed one) can support `open()` by
  supplying its `exists`/`truncate`/`createIfMissing` primitives.
- **Typed OS exceptions.** OS-handler errors are now delivered to Python as
  their real class — `except FileNotFoundError:` / `PermissionError:` etc.
  work. Previously every `OsCallException` surfaced as `RuntimeError`
  (REPL/run path). New FFI + WASM resume entry points:
  `monty_repl_resume_with_exception` and `DartMontyBridge.replResumeWithException`.

### Fixed

- `memoryMountedOsHandler`'s `Path.read_bytes` now returns a typed bytes value
  instead of a bare list, so binary `open(..., 'rb').read()` buffers correctly.

### Changed

- **Snapshot bytecode format (monty 0.18, breaking).** The upgrade changed
  monty's instruction encoding: the `monty_snapshot` byte stream for `"2 + 2"`
  shrank from 74 to 60 bytes. Snapshots are NOT portable across the 0.17 → 0.18
  upgrade — consumers persisting snapshots across versions must regenerate
  them. Pinned by `snapshot_format_pinning` in `native/tests/integration.rs`.

### Known limitations

- `with__cm_*` use monty's synthetic `_test_cm()`, which only exists under the
  testing-only `test-hooks` cargo feature (never shipped). They have dedicated
  conformance on both backends via opt-in test-hooks builds that never touch
  the shipped binaries: `bash tool/test_cm.sh` (FFI — marker-gated oracle +
  dylib) and `bash tool/test_cm_wasm.sh` (WASM — a staged test-hooks `.wasm`
  with the corpus runner compiled `-DMONTY_TEST_HOOKS=true`). The default
  suites skip them. Real `with open(...)` is covered by `with__all`.
- `range__ops` exercises `2**63` range membership where the shared monty
  wasm32 engine diverges from native; skipped on the WASM runners only.
- `edge__int_float_mod` (`int % float`) should yield a float; native FFI
  returns `2.0` but the monty wasm32 engine returns `2` (an upstream wasm
  number-coercion divergence). Skipped on the WASM runners only; the reverse
  `edge__float_int_mod` is unaffected.
- `open__fs` / `open__fs_windows` and `pyobject__cycle_*` pass on both backends.

## 0.18.0

Tracks upstream [`monty` v0.0.18](https://github.com/pydantic/monty/releases/tag/v0.0.18).

### Changed

- **Upgraded the embedded interpreter to `monty` v0.0.18.** Headline upstream
  additions: an `open()` builtin with buffered file I/O and `with` /
  context-manager support, plus a large batch of garbage-collector,
  exception-safety, and performance fixes.
- **`resolveFutures` per-call errors are now catchable in Python.** An `errors`
  entry on `resolveFutures` is raised as a `RuntimeError` at the `await` point,
  so a wrapping `try/except RuntimeError` catches it normally. Previously this
  short-circuited past Python's exception handling and terminated the script
  with `MontyScriptError`. Scripts that relied on the old script-terminating
  behavior (without a `try/except`) still surface a terminal error.

### Build

- **Building from source now requires Rust 1.95+** (upstream `monty` v0.0.18
  raised its MSRV). Run `rustup update stable`.

### Known limitations

Some v0.0.18 interpreter features are not yet surfaced through this binding.
Their corpus fixtures are skipped in the WASM runners (and pass the oracle
suite only because FFI and the oracle binary agree on the same gap):

- **`open()` / file I/O** — the new `Open` OS-call is not yet dispatched through
  the Dart OS handler + WASM VFS (`open__fs`, `open__fs_windows`, `with__all`).
- **`with` context-manager edge cases** driven by the `test-hooks`-only
  `_test_cm()` synthetic CM (`with__cm_*`) — not built into the shipped crate.
- **Cyclic-container result comparison** in the WASM fixture runner
  (`pyobject__cycle_*`); FFI returns the correct cyclic value.
- **`range__ops`** — dart2js divergence on `2**63`-scale range membership.

### Internal

- Adapted the native shim to v0.0.18's restructured `OsCall` (`function` /
  `args` / `kwargs` fields replaced by a typed `function_call` projected via
  `take_function_call().to_args()`) and added a JSON mapping for the new
  `MontyObject::FileHandle` variant. The new file-handle value currently
  decodes on the Dart side as a generic `MontyDict` (`__type: "filehandle"`);
  a dedicated `MontyValue` subtype is a follow-up.

## 0.17.1

### Breaking

- **`MontyCallback` is now `(List<Object?> args, Map<String, Object?>? kwargs)`.**
  Positional args by index (`args[0]`…); keyword args in `kwargs`. Old single-map
  form (`args['_0']`) no longer compiles.
- **`.arguments` renamed to `.args`** on `MontyPending`, `MontyOsCall`,
  `CoreProgressResult`, and `WasmProgressResult`.
- **`useFutures` removed** from `feedRun`/`feedStart`/`Monty.run`. Use
  `externalAsyncFunctions` instead.

### Added

- **`inputs:`** on `Monty.run`/`feedRun`/`feedStart` — inject Dart values as
  Python variables for one execution.
- **`externalAsyncFunctions`** — callbacks dispatched via `resumeAsFuture`;
  Python can `await` them and `asyncio.gather` runs them concurrently.
- **`MontyInternalError`** — new `MontyError` subtype for interpreter-internal
  failures.
- **`MontyNone` literal** — `feedRun('None')` now returns `MontyNone`.

## 0.17.0

Re-cut release: align versioning with `dart_monty`. Supersedes the
retracted `0.0.17` (which omitted `native/src/bin/oracle.rs` from
the published archive, breaking the build hook for consumers).

## 0.0.17

Initial release.
