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

Every cell here is **green on `main`** as of the futures-driveloop fix
(`dart_monty_core` PR landing this doc). The `useFutures` opt-in is
the toggle that activates the cell-5 column.

### L1 — `MontyRepl.feedStart` + manual loop

| | sync Dart | async Dart |
|---|---|---|
| bare Python call | ✅ caller resumes with the value | ✅ caller awaits then resumes |
| `await ext()` | ✅ caller drives `resumeAsFuture` / `resolveFutures` | ✅ same path |

L1 has always supported every cell — the caller controls dispatch, so
the host can implement whatever protocol it wants. Reference:
[`_repl_futures_test_body.dart`][repl-futures] (10 tests).

### L2 — `MontyRepl.feedRun(useFutures: false)` (default)

| | sync Dart | async Dart |
|---|---|---|
| bare Python call | ✅ | ✅ (callback awaited eagerly Dart-side) |
| `await ext()` | ❌ `TypeError: 'str' object can't be awaited` |

Default behaviour preserves back-compat: callbacks are awaited inline
before resuming Python. Python sees the plain value, so `await fn()`
fails because the value is not awaitable.

### L2 — `MontyRepl.feedRun(useFutures: true)`

| | sync Dart | async Dart |
|---|---|---|
| bare Python call | ✅ | ✅ |
| `await ext()` | ✅ | ✅ |
| `asyncio.gather(a(), b(), c())` over externals | ✅ all dispatch concurrently, resolve in argument order |

`useFutures: true` switches `_driveLoop` to launch each callback as an
unawaited `Future`, reply with `resumeAsFuture()`, and batch the results
back via `resolveFutures()` when the engine surfaces
`MontyResolveFutures`. Reference:
[`_feedrun_async_matrix_body.dart`][feedrun-matrix].

### L3 — `Monty(code).run(useFutures: …)`

`Monty.run` and `Monty.exec` plumb `useFutures` straight through to
`feedRun`. The matrix is identical to L2. Reference:
[`_run_async_matrix_body.dart`][run-matrix].

### L4 — `MontyRuntime.execute` (dart_monty)

| `MontyRuntime(useFutures:)` | sync Dart | async Dart | `await ext()` |
|---|---|---|---|
| `false` (default) | ✅ | ✅ (eager) | ❌ TypeError |
| `true` | ✅ | ✅ | ✅ |

L4 takes a different code path than L2/L3: `MontyRuntime` constructs a
`PlatformBridge` whose `dispatchToolCallAsFuture` is the futures-mode
twin of `dispatchToolCall`. Setting `useFutures: true` on `MontyRuntime`
flips the bridge into futures mode, which leverages `ReplPlatform`'s
existing `MontyFutureCapable` implementation (no `_driveLoop` involved).
Reference: `dart_monty/test/integration/_runtime_async_matrix_body.dart`.

## When to opt in

Set `useFutures: true` when **any** of:

- The Python script uses `await` against a Dart-registered external
  (the only way to express "this host call is async" inside Python).
- You want concurrent host-handler dispatch — `asyncio.gather` over
  externals dispatches all callbacks before the first
  `MontyResolveFutures`, so independent I/O fans out instead of
  serialising.

Leave `useFutures: false` (the default) when:

- The host handlers are simple sync values or you don't care about
  concurrency — serial dispatch is easier to reason about and avoids
  any chance of handlers racing over shared state.
- You want bit-for-bit back-compat with pre-fix behaviour.

## How errors surface

`useFutures: true` collects per-call errors into a map and passes them
to `resolveFutures(results, errors)`. Today, an `errors` entry
**terminates the script** with `MontyScriptError` rather than raising a
catchable Python `RuntimeError` (`try / except RuntimeError` does not
catch). The error message bubbles up verbatim in
`MontyScriptError.message`, so callers can route it however they want.
This is a known pydantic-monty engine constraint, not a host-side bug;
the L1 manual-loop tests pin the contract end-to-end.

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
