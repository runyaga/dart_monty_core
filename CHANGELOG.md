# Changelog

## 0.18.0

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
