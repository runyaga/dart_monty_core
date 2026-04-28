# Changelog

## Unreleased

### Added

- **`Monty.typeCheck(code, {prefixCode, scriptName})`** — static type
  analysis that returns a `List<MontyTypingError>` (empty when clean).
  Stateless — uses an isolated analysis heap. Wraps upstream
  `monty-type-checking`. New `MontyTypingError` value class exposes
  `code`, `message`, `path`, `line`/`column`, `endLine`/`endColumn`, and
  `url`. WASM bridge gains a `sched_yield` no-op to satisfy salsa-rs's
  WASI imports.
- **`MontyResult.ok` and `MontyResult.excType`** convenience getters.
  `ok` is the positive-form alias of `isError` (`bool get ok => error == null`);
  `excType` is shorthand for `error?.excType`. Read more naturally in test
  harnesses and UI code (`expect(result.ok, isTrue)`, `if (result.excType ==
  'ValueError')`). Closes #38.

### Upgraded

- Rust dependency `monty` bumped from `v0.0.14` → `v0.0.17` (Cargo.toml +
  Cargo.lock). README references updated. Build is source-compatible: `cargo
  check`, `cargo clippy -D warnings`, `cargo test --lib` (188 passed) and
  `dart test` on FFI (67 passed) all green with no shim changes required.

### What changed upstream (monty v0.0.14 → v0.0.17)

**New Python builtins (auto-supported, no FFI plumbing needed):**

- `hasattr(obj, name)` — returns `bool`, never raises (PR #66, v0.0.15)
- `setattr(obj, name, value)` — uses existing `py_set_attr` (PR #67, v0.0.17)
- Chain assignment `a = b = 1` (PR #357, v0.0.15)

**New surface (not yet exposed by dart_monty_core):**

- **`MontyRun::call_function` / `MontySession::call`** — call a defined
  Python function from Rust with native args, instead of building a call
  string and feeding it through the REPL (PR #271, v0.0.15). Candidate for
  a new `MontyRepl.call(name, args)` Dart API; today consumers concatenate
  source.
- **Async `Monty` construction without holding the GIL** (PR #358,
  v0.0.15). dart_monty_core constructs synchronously inside a worker —
  consider whether the async path matters for WASM.
- **`ResourceTracker::gc_interval`** — `LimitedTracker` now honours a
  custom GC interval rather than the hard-coded 100 000 default (PR #371,
  v0.0.17). `MontyLimits` does not surface this; add a knob if consumers
  need it.
- **`monty-js` widened limits to `f64`** (>u32::MAX) (PR #344, v0.0.17).
  Rust `ResourceLimits` types are unchanged; only the JS bridge type
  changed. Verify when we next regenerate WASM bindings.

**Behaviour changes worth tracking:**

- Lone-surrogate input now raises `MontySyntaxError` instead of a raw
  PyO3 `UnicodeEncodeError` (PR #355, v0.0.15).
- Other input-conversion errors are wrapped as `MontyRuntimeError` instead
  of bubbling raw PyO3 errors (PR #356, v0.0.15).
- "Cheap sourcemaps" — per-instruction encoding changed, which shifts
  the postcard wire format used by `MontyRepl.dump` / `restore` (PR
  #354, v0.0.15). **v0.0.14 snapshots cannot be restored on v0.0.17.**
  `PINNED_SNAPSHOT_2_PLUS_2` in `native/tests/integration.rs` updated
  to the new bytes; the dump for `"2 + 2"` shrank from 98 → 74 bytes.
  Consumers persisting snapshots across upgrades must regenerate.
- Empty tuple singleton no longer counts toward the memory limit, so
  `memoryBytes: 0` is now meaningful for allocation-free code (PR #363,
  v0.0.17). Tests that asserted "even trivial code overflows at 0 bytes"
  will start to fail.
- `prefix_code` field renamed to `type_check_stubs` (PR #361, v0.0.16).
  Not used anywhere in `native/` or `lib/` — confirmed via grep.
- Input-safety hardening (PR #360, v0.0.16) — touched `convert.rs`,
  `external.rs`, `monty_cls.rs`, `repl.rs`. No behaviour regressions
  observed in our test corpus.

**Bug fixes (inherited):**

- Partial-future resolution panics in mixed `asyncio.gather()` (PR #251,
  v0.0.15).
- Negating `i64::MIN` no longer panics; slicing algorithms unified into
  `slice.rs` (PR #368, v0.0.17).
- `gc_interval` parameter is no longer silently ignored (PR #371, v0.0.17).

### Gap inventory — follow-up work to consider

| # | Gap | Files | Priority |
|---|-----|-------|----------|
| 1 | Expose `MontyRepl.call(name, args)` Dart API leveraging upstream `MontySession::call` (PR #271) | `lib/src/repl/`, `native/src/repl_handle.rs`, `native/include/dart_monty.h` | Medium |
| 2 | Add `gc_interval` knob on `MontyLimits` (PR #371) | `lib/src/platform/monty_limits.dart`, `native/src/handle.rs` | Low |
| 3 | Add fixture coverage for `hasattr` / `setattr` / chain assignment in our cross-backend corpus | `test/integration/_fixture_corpus.dart` | Low |
| 4 | Document new `MontySyntaxError` path for lone surrogates (PR #355) in error docs | `README.md`, `CHANGELOG.md` (this entry) | Low |

### Added

- **`flutter.assets` pubspec stanza.** Flutter consumers can reference
  `- package: dart_monty_core` under their own `flutter.assets` to have
  the WASM/JS bridge files served at `packages/dart_monty_core/assets/...`
  by Flutter's asset bundler. No manual `cp` step required.
- **`tool/prebuild.sh`** — canonical regeneration script for the three
  web assets (`dart_monty_core_bridge.js`, `dart_monty_core_worker.js`,
  `dart_monty_core_native.wasm`). Byte-level drift-check is deferred
  pending reproducible cross-host WASM builds; CI still exercises
  the assets via the `test-wasm` integration suite.

### Changed

- **Web assets are now committed to git** instead of built at publish
  time and force-staged. Git-dep consumers get a working `pub get`
  without running any build step. See README "Building from source".
- **`MontyException.message` no longer carries the exception-type prefix.**
  The Rust shim was setting `"message": e.summary()`, where upstream's
  `summary()` returns `"ExcType: msg"`. Combined with the separately-
  exposed `excType` field, the natural `${e.excType}: ${e.message}`
  idiom produced doubled output: `SyntaxError: SyntaxError: …`,
  `ZeroDivisionError: ZeroDivisionError: division by zero`, etc.
  `message` now carries just the raw exception message (or empty
  string when upstream reports `None`). Same change applies to the
  oracle binary's JSON output (`native/src/bin/oracle.rs`). The C
  out-error fallback in `lib.rs` and the secondary `Option<String>`
  returned alongside JSON envelopes from `handle.rs`/`repl_handle.rs`
  intentionally still use `summary()` — those paths have no separate
  `excType` field for the consumer to compose with.

### Removed — BREAKING

- **`packages/dart_monty_flutter/` sidecar deleted.** The
  `DartMontyFlutter.ensureInitialized()` shim moves to `dart_monty` as
  `DartMonty.ensureInitialized()`. Flutter consumers update their
  import and call site:

  ```dart
  // before
  import 'package:dart_monty_flutter/dart_monty_flutter.dart';
  await DartMontyFlutter.ensureInitialized();

  // after
  import 'package:dart_monty/dart_monty.dart';
  await DartMonty.ensureInitialized();
  ```

### Fixed

- **`Monty.exec` now accepts `externals:`.** `Monty.run` always supported
  externals; the static one-shot wrapper silently dropped them, leaving
  Python in `Monty.exec(...)` unable to call back into Dart. Forwarded
  through to `monty.run` and pinned with FFI + WASM integration tests.
- **`MontyRepl.feed` re-syncs `ext_fn_names` on every call.** The
  iterative path called `setExtFns`, the fast path did not, so names
  registered in a previous feed leaked into the next feed's NameLookup
  resolution and surfaced as a confusing
  "No handler registered for: X" error instead of a clean Python
  NameError. `setExtFns` now runs at the top of `feed()` (with `[]` when
  externals is empty), covering both paths. Three regression scenarios
  pinned on FFI + WASM. Note: the upstream list-comprehension shadowing
  bug (API_REVIEW §4) is a separate engine-level issue.

### Added

- **`MontyRepl.scriptName` getter.** The reference `pydantic_monty`
  class exposes `script_name`; the Dart side stored `_scriptName` but
  had no accessor. `Monty.scriptName` returns the same value with a
  `'main.py'` fallback to match the engine default.

### Changed

- **`MontyRepl.snapshot` / `restore` throw `StateError` mid-pause.**
  Previously they bubbled an opaque Rust-side error when called while
  a `feedStart`/`resume` loop was paused. Dart now tracks pending
  state and throws `StateError` with an actionable message instead.
- **REPL dartdoc tightened.** Stale "REPL doesn't support NameLookup"
  comment removed (the Rust handle auto-resolves names via
  `ext_fn_names`; the Dart branch only fires when a name was not
  registered). `feedStart`'s `List<String> externalFunctions` shape is
  now documented as intentional (versus `feedRun`'s `Map<String,
  MontyCallback>`), and `detectContinuation` is called out as a
  Dart-only helper without a `pydantic_monty` equivalent.

### API alignment

Reshapes the public Dart surface to two classes — `Monty` (stateless)
and `MontyRepl` (stateful) — matching the reference `pydantic_monty`
Python package.

- **`Monty(code)` is now a compiled-program holder.** Construct with
  Python source, call `.run({inputs, externalFunctions, limits,
  osHandler})` to execute. State does not persist between calls —
  each `.run()` is a fresh interpreter. For REPL-style state
  accumulation use `MontyRepl()`.
- **`MontySession` is removed.** Its job (catch Python exceptions,
  return them as `MontyResult.error`) now lives directly on
  `MontyRepl.feedRun`. `clearState()`, `snapshot()`, `restore()` move
  onto `MontyRepl`. The two-class shape mirrors `pydantic_monty`
  exactly.
- **`MontyRepl.feedRun` returns Python errors as data**, not as a
  thrown `MontyScriptError`. Binding-level failures (resource limits,
  disposed handle) still throw. The iterative entry points
  (`feedStart` / `resume`) keep their throwing contract since they
  hand control back to the caller per progress step.
- **`externalFunctions:`** is the parameter name on `Monty.run`,
  `Monty.exec`, and `MontyRepl.feedRun` (`Map<String, MontyCallback>`).
  `MontyRepl.feedStart` already used this name with a `List<String>`
  value; the map/list divergence between iterative and
  run-to-completion entry points is intentional and documented.
- **`MontyRepl.feedRun`** runs to completion (paired symmetrically
  with `feedStart`).

### Test infrastructure

- **Shared FFI/WASM test bodies.** Twin test pairs share a single
  `_<name>_test_body.dart` containing the assertions; the
  `ffi_*_test.dart` and `wasm_*_test.dart` files are thin wrappers
  that set the right `@Tags` and import the body.

### Additive features

- **`printCallback`** parameter on `Monty.run`, `Monty.exec`, and
  `MontyRepl.feedRun` — batch callback invoked with the script's
  captured `print()` output before the call returns.
- **`MountDir` + `memoryMountedOsHandler`** — declarative virtual
  mounts for Python `pathlib.Path`, backed by an in-memory map.
  Enforces path normalisation, `..` traversal rejection, mode, and
  per-write byte limit. dart:io-backed real-filesystem variant is a
  follow-up.
- **`MontyDataclass.hydrate` / `dartAttrs`** — convert a Python
  `@dataclass` returned to Dart into a user-supplied class via a
  factory.

## 0.0.14 - monty upstream upgrade

### Upgraded
- Rust dependency `monty` bumped from `v0.0.12` → `v0.0.14` (Cargo.toml + Cargo.lock)

### Added — new public API

- **`OsCallNotHandledException`** (`lib/src/platform/os_call_exception.dart`,
  re-exported from `package:dart_monty_core/dart_monty_core.dart`). Throw from
  an `OsCallHandler` to signal that the host does not implement the requested
  OS call. Python sees `NameError: name '<fn>' is not defined` — matching the
  semantics of an undefined global — instead of the generic `RuntimeError`
  that `OsCallException` produces. Optional `fnName` field lets the handler
  override the function name reported to Python.
  ```dart
  final monty = Monty(osHandler: (op, args, kwargs) async {
    if (op == 'os.getenv') return Platform.environment[args[0] as String];
    throw const OsCallNotHandledException(); // → NameError in Python
  });
  ```
- **`MontyRepl.resumeNotFound(String fnName)`** — public method on the REPL
  façade; also exposed on `ReplPlatform` for platform-layer callers.
- **`OsCallHandler` now handles `"date.today"` and `"datetime.now"`** — monty
  v0.0.14 adds these as explicit OS calls. Hosts return `MontyDate(year, month, day)`
  for `date.today` and `MontyDateTime(...)` for `datetime.now`. The single
  positional arg to `datetime.now` carries the timezone as `MontyTimeZone` or
  `MontyNone`.

### Added — internal plumbing

- `monty_resume_not_found` / `monty_repl_resume_not_found` C FFI exports,
  matching `ExtFunctionResult::NotFound` in upstream monty
  (`native/src/handle.rs`, `native/src/repl_handle.rs`, `native/src/lib.rs`,
  `native/include/dart_monty.h`).
- `DartMontyBridge.resumeNotFound` / `DartMontyBridge.replResumeNotFound` on
  the WASM JS bridge (`js/src/bridge.js`, `js/src/worker_src.js`).
- `resumeNotFound` on the abstract binding contracts: `MontyCoreBindings`,
  `ReplBindings`, `NativeBindings`, and `WasmBindings` (run + REPL variants).
- FFI + WASM integration tests for `date.today()` / `datetime.now()` OS calls
  and for the `OsCallNotHandledException` → `NameError` path
  (`ffi_datetime_oscall_test.dart`, `wasm_datetime_oscall_test.dart`).

### What changed upstream (monty v0.0.12 → v0.0.14)

**New types (not yet surfaced in dart_monty_core):**
- `ExcType` — 35 named exception variants (ValueError, FrozenInstanceError, JsonDecodeError,
  TimeoutError, RePatternError, …). `resume_with_exception` already parses these by string; the
  new variants are automatically accepted.
- `JsonMontyObject` / `JsonMontyArray` / `JsonMontyPairs` — upstream serde-serialize wrappers.
  dart_monty_core continues to use its own `monty_object_to_json` / `json_to_monty_object`.
- `ExtFunctionResult::NotFound` — signal that the host does not handle an OS call, allowing
  Python to raise `NameError: name '<fn>' is not defined`. Now surfaced through the full
  stack as `OsCallNotHandledException` (FFI + WASM).

**New OsFunction variants:**
- `OsFunction::DateToday` → `"date.today"` — Python `date.today()`.
  Host must return `MontyDate(year, month, day)` via the `OsCallHandler`.
- `OsFunction::DateTimeNow` → `"datetime.now"` — Python `datetime.now(tz=...)`.
  Host must return `MontyDateTime(...)`. The single positional arg carries the tz
  as `MontyTimeZone` or `MontyNone`.

**Breaking changes (transparent to dart_monty_core):**
- `CodeLoc` fields widened from `u16` → `u32` — fixes panic on source lines > 65 535 chars.
  Traceback line/column numbers now support larger values with no API change.
- `PyMontyComplete::create` takes `MontyObject` by value — Python-layer change, no FFI impact.
- `DictPairs` gained `len()` / `is_empty()` — not yet used in convert.rs.

**Bug fixes (inherited):**
- OS auto-dispatch during `start()` (PR #337): start-time OS calls no longer stall execution.
- `not_handled` sentinel now respected for async OS callbacks (PR #337).
- `datetime.now()` / `date.today()` added to Python stdlib support (PR #332).
- Non-ASCII column offsets corrected (PR #342).

### Gap inventory — follow-up work required

| # | Gap | File(s) | Priority | Status |
|---|-----|---------|----------|--------|
| 1 | `ExtFunctionResult::NotFound` not in FFI — no `monty_resume_not_found` / `monty_repl_resume_not_found` export; hosts cannot signal "OS call not handled" | `native/src/handle.rs`, `native/src/repl_handle.rs`, `native/src/lib.rs`, `native/include/dart_monty.h`, Dart binding chain | High | **Closed** — surfaced as `OsCallNotHandledException` across FFI + WASM |
| 2 | No integration tests for `"date.today"` / `"datetime.now"` OS calls | `test/`, `native/tests/` | High | **Closed** — `ffi_datetime_oscall_test.dart`, `wasm_datetime_oscall_test.dart`, `native/tests/integration.rs` |
| 3 | `OsCallHandler` docs don't explain return types for `"date.today"` (use `MontyDate`) and `"datetime.now"` (use `MontyDateTime`) — fixed `externals.dart` comment, but no example | `lib/src/externals.dart`, `example/` | Medium | Open |
| 4 | `Ellipsis` serialised as plain `"..."` string; upstream `JsonMontyObject` uses `{"$ellipsis":"..."}` to disambiguate from the string literal `"..."` | `native/src/convert.rs`, `lib/src/platform/monty_value.dart` | Low | Open |
| 5 | `DictPairs.len()` / `DictPairs.is_empty()` not used in `dict_to_json` — minor convert.rs efficiency opportunity | `native/src/convert.rs` | Low | Open |

## 0.0.12 - Initial Release

- Multi-REPL support on WASM with snapshot integration tests
- `compile`, `runPrecompiled`, `startPrecompiled` on WASM + `MontySession` snapshot/restore
- API alignment: `inputs`, `MontySyntaxError`, `jsAligned` flag
- Rename `MontyNull` → `MontyNone`, `callbacks` → `externals`
- `resumeWithException` through full stack for typed OS errors
- 464/464 fixture conformance tests passing on native and WASM
- POSIX VFS, dataclass ext-fns, async dispatch loop for WASM
