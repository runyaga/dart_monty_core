# Changelog

## Unreleased

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
