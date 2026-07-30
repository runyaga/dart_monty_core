# Changelog

## Unreleased (0.19.0)

Requires `monty` v0.0.19. The `monty` crate's public surface was split in 0.19 —
it went from 1321 to 306 public items and most of what this package uses moved to
the new `monty-types` crate — so this is a substantial internal change with a
small consumer-facing surface.

### Breaking

- **The `open()` OS-call op is now `'open'`, was `'Open'`.** ⚠️ **This is the one
  change that fails silently.** If you have a custom `OsCallHandler` that matches
  on the op name, a `case 'Open':` (or `if (op == 'Open')`) stops matching and
  every `open()` falls through to your not-handled path. Rename it:

  ```dart
  // before
  if (op == 'Open') { ... }
  // after
  if (op == 'open') { ... }
  ```

  Upstream renamed exactly one of the 23 ops in v0.0.19 (the other 22 are
  unchanged);
  `'Open'` was the only capitalised, undotted name, so `'open'` is now consistent
  with `Path.*`, `os.*`, `date.*` and `datetime.*`.

- **Print output is capped at 10 MB and raises `MemoryError` past it.** Print
  collection previously sat outside all resource accounting, so sandboxed code
  could exhaust the *host* process with a `while True: print(x)` loop. Exceeding
  the cap now raises a normal, catchable Python `MemoryError` — the write is
  rejected, nothing is truncated and no output is silently lost:

  ```python
  try:
      for _ in range(1_000_000):
          print("x" * 100_000)
  except MemoryError:
      ...          # reachable; chunk the output or stream it via printCallback
  ```

- **Session snapshots are not portable across this upgrade.** The canonical dump
  for `"2 + 2"` changed from 60 to 59 bytes, because serialized sessions now carry
  `CompileOptions`. Snapshots taken with 0.18.x cannot be restored on 0.19.0 and
  must be regenerated. (This has been true of every monty bump: 98 → 74 → 60 → 59.)

- **`monty`'s argument-error wording now matches CPython** for Python-style
  argument callsites. For example `json.dumps(1, 2)` raised
  `TypeError('dumps expected at most 1 argument, got 2')` and now raises
  `TypeError('dumps() takes 1 positional argument but 2 were given')`. If you
  assert on these strings, update them.

- **`native/Cargo.lock` is now committed.** The build hook compiles the Rust crate
  as a top-level package on every consumer's `pub get`, so the lockfile is honoured
  and pinning it is what makes your build reproducible. It is also load-bearing:
  free resolution selected a `get-size2` whose `GetSize` impl targeted a different
  `compact_str` major than `ruff_python_ast` used, and the build failed inside a
  dependency neither we nor you control. If you vendor or patch transitive Rust
  dependencies, you now inherit our pins.

### Deliberately unchanged

- **`assert` keeps CPython semantics.** monty v0.0.19 enables pytest-style
  introspected assert messages by default, so `assert 2 == 5` would raise
  `AssertionError('assert 2 == 5')` where CPython raises an empty
  `AssertionError()`. This release pins them **off**, preserving 0.18 behaviour;
  adopting a new upstream default silently is not an upgrade. An opt-in is
  planned.

### Security

- Removed four stale `unic-*` advisory exemptions from `native/deny.toml`.
  v0.0.19 dropped that dependency chain entirely, so the crate no longer carries
  those unmaintained transitive dependencies.

### Internal

- Depends on the new `monty-types` crate; `monty_type_checking` is now
  `monty-type-checking` upstream (the Rust path is unchanged). `monty-fs` is
  **not** required — this package never used `monty::fs`.
- The conformance corpus moved to v0.0.19's 531 fixtures (was 482 from v0.0.18),
  and `tool/check_fixture_corpus.sh` now fails the build if the corpus and the
  pinned monty version disagree.


## 0.18.1

Requires `monty` v0.0.18 (Rust 1.95+ to build from source). Upgrades the
embedded interpreter and surfaces Python `open()` / file I/O with typed OS
exceptions.

### Breaking

- **Snapshot bytecode format changed.** `monty` v0.0.18 re-encoded
  instructions: the `monty_snapshot` byte stream for `"2 + 2"` shrank from 74
  to 60 bytes. Snapshots are NOT portable across the 0.17 → 0.18 upgrade —
  consumers persisting snapshots must regenerate them. Pinned by
  `snapshot_format_pinning` in `native/tests/integration.rs`.
- **Building from source now requires Rust 1.95+** (upstream `monty` raised its
  MSRV). Run `rustup update stable`.

### Added

- **`open()` / file I/O.** `memoryMountedOsHandler` services the `Open` OS-call
  (existence-check for `r`/`rb`, truncate-create for `w`/`wb`, create-preserving
  for `a`/`ab`) and the `append_text`/`append_bytes` calls the interpreter
  emits. Python can `open()` files, read/write/append, and use
  `with open(...) as f:` against an in-memory mount. A new **`MontyFileHandle`**
  `MontyValue` represents the returned file object.
- **`resolveOpenCall(...)`** — the store-agnostic `open()` primitive that owns
  the mode→effect mapping (existence-check / truncate / create → file handle,
  with typed errors). `memoryMountedOsHandler` delegates to it, and any
  `OsCallHandler` (e.g. a `package:file`-backed one) can support `open()` by
  supplying its `exists`/`truncate`/`createIfMissing` primitives.
- **Typed OS exceptions.** OS-handler errors are delivered to Python as their
  real class — `except FileNotFoundError:` / `except PermissionError:` now work
  (previously every `OsCallException` surfaced as `RuntimeError`). New FFI +
  WASM resume entry points: `monty_repl_resume_with_exception` and
  `DartMontyBridge.replResumeWithException`.

### Changed

- **Upgraded the embedded interpreter to `monty` v0.0.18** — an `open()` builtin
  with buffered file I/O and `with` / context-manager support, plus upstream
  garbage-collector, exception-safety, and performance fixes.
- **`resolveFutures` per-call errors are now catchable in Python.** An `errors`
  entry on `resolveFutures` is raised as a `RuntimeError` at the `await` point,
  so a wrapping `try/except RuntimeError` catches it normally. Previously this
  short-circuited past Python's exception handling and terminated the script
  with `MontyScriptError`. Scripts that relied on the old script-terminating
  behavior (without a `try/except`) still surface a terminal error.

### Fixed

- **`memoryMountedOsHandler`'s `Path.read_bytes` returns a typed bytes value**
  instead of a bare list, so binary `open(..., 'rb').read()` buffers correctly.

### Known limitations

- `with__cm_*` use `monty`'s synthetic `_test_cm()`, which exists only under the
  testing-only `test-hooks` cargo feature (never shipped). They have dedicated
  conformance on both backends via opt-in test-hooks builds that never touch the
  shipped binaries: `bash tool/test_cm.sh` (FFI) and `bash tool/test_cm_wasm.sh`
  (WASM). The default suites skip them; real `with open(...)` is covered by
  `with__all`.
- `range__ops` (`2**63` range membership) and `edge__int_float_mod`
  (`int % float`) diverge on the shared `monty` wasm32 engine — an upstream
  concern, not a host-binding gap. Skipped on the WASM runners only; both pass
  on native FFI.

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
