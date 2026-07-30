# Async / Sync Matrix

dart_monty_core's interaction with Python scripts has four orthogonal
axes. This page is the cell-by-cell reference for what works at every
combination, when to opt into the futures path, and where the contract
lives in code.

## The four axes

1. **Dart handler shape** — `sync` (returns a value via `Future.value`)
   vs `async` (returns a `Future` that resolves later).
2. **Python call shape** — `bare` call (`fn(x)`) vs `await fn(x)`.
3. **API layer** —
   - **L1.** `MontyRepl.feedStart` + caller-driven
     `resumeAsFuture` / `resolveFutures` (manual loop)
   - **L2.** `MontyRepl.feedRun` (managed loop — `_driveLoop` drives
     dispatch internally)
   - **L3.** `Monty(code).run` / `Monty.exec` (one-shot wrapper around
     `feedRun`)
   - **L4.** `MontyRuntime.execute` (in `dart_monty`; routes through
     `PlatformBridge` rather than `_driveLoop`)
4. **Backend** — FFI vs WASM. The matrix is identical on both unless
   noted.

## The matrix

Every cell here is green on `main`, verified by the `*_async_matrix_*`
integration suites on both backends. Registering a callback under
`externalAsyncFunctions` is what activates the `await ext()` column.

> **Updated for 0.17.1+.** This document previously described a boolean
> `useFutures:` parameter on `feedRun` / `feedStart` / `Monty.run`. That parameter
> was **removed in 0.17.1**; futures dispatch is now selected **per function** by
> registering it in `externalAsyncFunctions` rather than globally by a flag. The
> underlying engine protocol (`resumeAsFuture` / `resolveFutures`) is unchanged —
> only how you opt in.

### L1 — `MontyRepl.feedStart` + manual loop

| | sync Dart | async Dart |
|---|---|---|
| bare Python call | ✅ caller resumes with the value | ✅ caller awaits then resumes |
| `await ext()` | ✅ caller drives `resumeAsFuture` / `resolveFutures` | ✅ same path |

L1 has always supported every cell — the caller controls dispatch, so
the host can implement whatever protocol it wants. Reference:
[`_repl_futures_test_body.dart`][repl-futures] (10 tests).

### L2 — `MontyRepl.feedRun` with `externalFunctions` only

| | sync Dart | async Dart |
|---|---|---|
| bare Python call | ✅ | ✅ (callback awaited eagerly Dart-side) |
| `await ext()` | ❌ `TypeError: 'str' object can't be awaited` |

A callback registered under `externalFunctions` is awaited inline before Python
resumes, so Python sees a plain value and `await fn()` fails — the value is not
awaitable.

### L2 — `MontyRepl.feedRun` with `externalAsyncFunctions`

| | sync Dart | async Dart |
|---|---|---|
| bare Python call | ✅ | ✅ |
| `await ext()` | ✅ | ✅ |
| `asyncio.gather(a(), b(), c())` over externals | ✅ all dispatch concurrently, resolve in argument order |

For functions registered in `externalAsyncFunctions`, `_driveLoop` launches the
callback as an unawaited `Future`, replies with `resumeAsFuture()`, and batches
results back via `resolveFutures()` when the engine surfaces
`MontyResolveFutures`. Because the choice is per function, a single script can mix
inline-awaited and futures-dispatched externals. Reference:
[`_feedrun_async_matrix_body.dart`][feedrun-matrix].

### L3 — `Monty(code).run(...)`

`Monty.run` and `Monty.exec` plumb `externalFunctions` and
`externalAsyncFunctions` straight through to `feedRun`. The matrix is identical to
L2. Reference:
[`_run_async_matrix_body.dart`][run-matrix].

### L4 — `MontyRuntime.execute` (dart_monty)

| registration | sync Dart | async Dart | `await ext()` |
|---|---|---|---|
| `externalFunctions` | ✅ | ✅ (eager) | ❌ TypeError |
| `externalAsyncFunctions` | ✅ | ✅ | ✅ |

L4 takes a different code path than L2/L3: `MontyRuntime` constructs a
`PlatformBridge` whose `dispatchToolCallAsFuture` is the futures-mode twin of
`dispatchToolCall`, leveraging `ReplPlatform`'s `MontyFutureCapable`
implementation (no `_driveLoop` involved).
Reference: `dart_monty/test/integration/_runtime_async_matrix_body.dart`.

## When to register a function as async

Register under `externalAsyncFunctions` when **either** of:

- The Python script uses `await` against a Dart-registered external
  (the only way to express "this host call is async" inside Python).
- You want concurrent host-handler dispatch — `asyncio.gather` over
  externals dispatches all callbacks before the first
  `MontyResolveFutures`, so independent I/O fans out instead of
  serialising.

Use plain `externalFunctions` when:

- The handler returns a simple synchronous value, or you do not need
  concurrency — serial dispatch is easier to reason about and removes any chance
  of handlers racing over shared state.

## How errors surface

Futures dispatch collects per-call errors into a map and passes them to
`resolveFutures(results, errors)`. **These errors are catchable in Python** — an
`errors` entry surfaces as a raisable exception, so `try / except` around the
`await` works.

> **Corrected.** This section previously stated that an `errors` entry
> *terminates the script* with `MontyScriptError` and that `try / except
> RuntimeError` does not catch it. That was fixed in 0.17.1 — see the CHANGELOG
> entry "`resolveFutures` per-call errors are now catchable in Python", which notes
> the old behaviour short-circuited past Python's exception handling. The L1
> manual-loop tests pin the current contract end-to-end.

⚠️ **This is verified for L1–L3 (`dart_monty_core`) only.** L4 goes through
`dart_monty`'s `PlatformBridge`, a different code path, and that repo has open
issues reporting async errors still bypassing Python `try/except`
(`dart_monty#311`, `dart_monty#242`). Do not assume the fix reaches L4 until those
are closed.

## The spec — the executable matrix

Every claim on this page is a test:

- L1: [`test/integration/_repl_futures_test_body.dart`][repl-futures]
- L2: [`test/integration/_feedrun_async_matrix_body.dart`][feedrun-matrix]
- L3: [`test/integration/_run_async_matrix_body.dart`][run-matrix]
- L4 (in dart_monty): `test/integration/_runtime_async_matrix_body.dart`

Each shared body has FFI + WASM driver pairs (the L4 body has FFI only
because dart_monty's integration suite is FFI-tagged). Run them with:

```bash
# dart_monty_core (FFI)
dart test \
  test/integration/ffi_repl_futures_test.dart \
  test/integration/ffi_feedrun_async_matrix_test.dart \
  test/integration/ffi_run_async_matrix_test.dart \
  -p vm --run-skipped --tags=ffi

# dart_monty_core (WASM)
bash tool/test_wasm_unit.sh
```

[repl-futures]: ../../test/integration/_repl_futures_test_body.dart
[feedrun-matrix]: ../../test/integration/_feedrun_async_matrix_body.dart
[run-matrix]: ../../test/integration/_run_async_matrix_body.dart
