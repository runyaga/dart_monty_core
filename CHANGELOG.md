# Changelog

## 0.0.14 - monty upstream upgrade

### Upgraded
- Rust dependency `monty` bumped from `v0.0.12` → `v0.0.14` (Cargo.toml + Cargo.lock)

### What changed upstream (monty v0.0.12 → v0.0.14)

**New types (not yet surfaced in dart_monty_core):**
- `ExcType` — 35 named exception variants (ValueError, FrozenInstanceError, JsonDecodeError,
  TimeoutError, RePatternError, …). `resume_with_exception` already parses these by string; the
  new variants are automatically accepted.
- `JsonMontyObject` / `JsonMontyArray` / `JsonMontyPairs` — upstream serde-serialize wrappers.
  dart_monty_core continues to use its own `monty_object_to_json` / `json_to_monty_object`.
- `ExtFunctionResult::NotFound` — signal that the host does not handle an OS call, allowing
  Python to raise an appropriate exception. **Not yet exposed in the FFI** (see gaps below).

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

| # | Gap | File(s) | Priority |
|---|-----|---------|----------|
| 1 | `ExtFunctionResult::NotFound` not in FFI — no `monty_resume_not_found` / `monty_repl_resume_not_found` export; hosts cannot signal "OS call not handled" | `native/src/handle.rs`, `native/src/repl_handle.rs`, `native/src/lib.rs`, `native/include/dart_monty.h`, Dart binding chain | High |
| 2 | No integration tests for `"date.today"` / `"datetime.now"` OS calls | `test/`, `native/tests/` | High |
| 3 | `OsCallHandler` docs don't explain return types for `"date.today"` (use `MontyDate`) and `"datetime.now"` (use `MontyDateTime`) — fixed `externals.dart` comment, but no example | `lib/src/externals.dart`, `example/` | Medium |
| 4 | `Ellipsis` serialised as plain `"..."` string; upstream `JsonMontyObject` uses `{"$ellipsis":"..."}` to disambiguate from the string literal `"..."` | `native/src/convert.rs`, `lib/src/platform/monty_value.dart` | Low |
| 5 | `DictPairs.len()` / `DictPairs.is_empty()` not used in `dict_to_json` — minor convert.rs efficiency opportunity | `native/src/convert.rs` | Low |

## 0.0.12 - Initial Release

- Multi-REPL support on WASM with snapshot integration tests
- `compile`, `runPrecompiled`, `startPrecompiled` on WASM + `MontySession` snapshot/restore
- API alignment: `inputs`, `MontySyntaxError`, `jsAligned` flag
- Rename `MontyNull` → `MontyNone`, `callbacks` → `externals`
- `resumeWithException` through full stack for typed OS errors
- 464/464 fixture conformance tests passing on native and WASM
- POSIX VFS, dataclass ext-fns, async dispatch loop for WASM
