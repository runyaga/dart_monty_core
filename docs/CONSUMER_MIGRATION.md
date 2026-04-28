# Consumer migration: dart_monty_core API alignment

This document tracks every public-API change in `dart_monty_core` that
downstream consumers need to act on. Recipes land incrementally as
each PR in the API-alignment series merges.

## PR roadmap

| PR | Status | Scope |
|---|---|---|
| **PR-A** | merged | Bug fixes, REPL polish (no breaking changes). |
| PR-B | upcoming | `Monty(code)` reshape, `externals` → `externalFunctions`, `feed` → `feedRun`, `MontySession.start` → `feedStart`. **Breaking.** |
| PR-C | upcoming | `printCallback`, `MountDir`, `registerDataclass`. **Additive only.** |

---

## PR-A — bug fixes and REPL polish (non-breaking)

No call-site changes are required. PR-A surfaces strictly improve the
existing API:

- `Monty.exec(...)` now accepts `externals:` (previously dropped
  silently).
- `MontyRepl.feed(...)` correctly clears `ext_fn_names` between calls
  — code that depended on the leaked-name behavior was always broken;
  Python NameError is now raised cleanly.
- New `String? get scriptName` on `MontyRepl` and `MontySession`;
  `String get scriptName` on `Monty` (defaults to `'main.py'`).
- `MontyRepl.snapshot()` / `restore()` throw `StateError` instead of
  an opaque Rust-side error when called while a `feedStart`/`resume`
  loop is paused.

If your code already wraps `snapshot`/`restore` in a try/catch on a
generic exception, the type changes from a Rust-derived exception to
`StateError`. Consider catching `StateError` explicitly.

### Per-package checklist (PR-A)

| Package | Action |
|---|---|
| `dart_monty` | None. Verify `dart test` passes after `pub upgrade`. |
| `soliplex_*` | None. |
| `dart_monty_plugins` | None. |

---

## PR-B — structural and naming alignment (breaking)

> Recipes land when PR-B is in review. This section is a placeholder.

### Quick mapping table (preview)

| Before | After | Tier |
|---|---|---|
| `Monty()` constructor (no args) | `MontySession()` for REPL, `Monty(code)` for one-shot | breaking |
| `monty.run(code)` (REPL) | `session.feedRun(code)` or `Monty(code).run()` | breaking |
| `externals: ...` | `externalFunctions: ...` | breaking |
| `MontySession.start(...)` | `MontySession.feedStart(...)` | breaking |
| `MontyRepl.feed(...)` | `MontyRepl.feedRun(...)` | breaking |

### Per-package checklist (PR-B) — to be filled in

- `dart_monty`: full call-site enumeration with file paths and counts.
- `soliplex_*`: same.
- `dart_monty_plugins`: same.
- Follow-up consumer ticket: `dart_monty/example/web/web/index.html`
  HTML/JS snippet update (deferred from main PR pass per agreement).

---

## PR-C — additive new feature parameters

> Recipes land when PR-C is in review.

### Quick mapping table (preview)

| Before | After | Tier |
|---|---|---|
| `MontyResult.printOutput` only | `printCallback: (stream, text) {}` parameter (batch) | additive |
| `OsCallHandler` for fs | `mount: [MountDir(...)]` (or keep `osHandler` for custom logic) | additive |
| `MontyDataclass` returned | `monty.registerDataclass('User', User.from)` | additive |

### Per-package checklist (PR-C) — to be filled in

- `dart_monty`: which packages benefit from `MountDir` over hand-rolled
  fs handlers.
- `soliplex_*`: where `printCallback` replaces stream wiring.
- Follow-up: dart:io-backed real-filesystem `MountDir` (PR-C ships
  memory-backed only).

---

## Verification per consumer

After bumping `dart_monty_core`:

```bash
cd <consumer_repo>
dart pub upgrade dart_monty_core
dart analyze --fatal-infos
dart test
```

If a consumer breaks on PR-B, run `dart fix --apply` first; the
analyzer pinpoints every renamed call site since old names cease to
exist in the package surface.

---

## Deferred — not in this series

These items sit behind separate tickets:

- Streaming `printCallback` (per-flush, not batch) — needs Rust C ABI
  callback + WASM Worker postMessage protocol changes.
- Snapshot mid-pause (`progress.dump()` / `load_repl_snapshot`) —
  needs Rust handle changes for snapshotting from `Paused` state.
- `type_check` static analysis API — net-new Rust FFI symbol;
  verifies analysis heap is isolated from execution heap.
- `run_async` / FutureSnapshot parallel host-future resolution —
  coordination between Dart event loop and synchronous Rust worker
  thread (WASM).
- Native input channel (`input_values: Vec<(String, MontyObject)>`)
  instead of literal-prefix `inputsToCode` in `feed`.
- Upstream list-comprehension name-shadowing — engine-level bug;
  filed upstream.
- `dart:io`-backed real-filesystem `MountDir` mode — PR-C ships
  memory-backed only.
