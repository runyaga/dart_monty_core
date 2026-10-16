# Testing runbook

This package has **eight distinct test mechanisms**. Which one to reach for is
not discoverable from the code, and running the wrong one, or the right one
wrongly, produces a green result that verified nothing.

This file is the single source of truth for how to verify a change.
`AGENTS.md` keeps a short table and links here: restated commands are what
rot. Seven instructions in the sibling `dart_monty` repo's `AGENTS.md` were
outright false precisely because they were a second copy nobody executed.

**The gate for changing this file: run every command in it, verbatim.**

---

## Before you commit: run mechanism 8

```bash
bash tool/gate.sh
```

That is the answer for **every** change. A red step means do not commit,
including when it looks unrelated to what you touched.

The table below is for **fast feedback while developing**, not a substitute.

| While iterating on… | Fastest useful signal |
|---|---|
| pure Dart in `lib/` | 1, then 2 |
| the pool, sessions, the channels (`lib/src/worker/`) | 3 and 4 |
| `native/worker/` (Rust) | rebuild the worker (Traps §1), then 6, 3 and 4 |
| anything the upstream corpus covers | 5 |
| a test harness or CI wiring | read Traps §3 first, then 8 |

---

## 1. Unit tests: pure Dart on the VM

```bash
dart test --exclude-tags=integration,ladder,example,worker
```

**Verifies:** pure-Dart logic, and the session against fakes, with no worker
process. **Cannot verify:** the protocol against a real worker. The gate runs
this with a floor of 3173 tests (`sf unit_tests 3173`).

## 2. Unit tests: the same suite on both web compilers

```bash
dart test --exclude-tags=integration,ladder,example,vm-only,worker \
  -p chrome -c dart2js -c dart2wasm
```

**Not redundant with 1.** dart2js has one number type, so `4.0 is int` is
true there, and a test that passes on the VM can fail on dart2js. The gate's
floor is 6212 (`sf unit_web 6212`).

## 3. The worker on native

```bash
bash tool/build_worker.sh                      # once, and after native/worker/ changes
dart test test/integration/worker -p vm --tags=worker
```

**Verifies:** pool, session, snapshots, host objects and crash recovery
against the real worker executable in `lib/src/bin/<os>-<arch>/`. The gate's
floor is 598 (`sf worker_vm 598`).

## 4. The worker in the browser

```bash
bash tool/test_worker_web.sh
```

**Verifies:** the same behaviour through a Web Worker, on dart2js and
dart2wasm, driving the **committed** `lib/assets/dart_monty_core_worker.{js,wasm}`.
The script asserts a floor of 461 tests per compiler. A feature needs both a
VM runner (`test/integration/worker/*_io_test.dart`) and a web runner
(`test/unit/worker/*_web_test.dart`) over a shared body; a missing runner
leaves a platform untested.

## 5. The upstream corpus

```bash
bash tool/test_corpus_worker.sh native
bash tool/test_corpus_worker.sh chrome dart2js
bash tool/test_corpus_worker.sh firefox dart2wasm
```

**Verifies:** upstream monty's 643 `test_cases` files through the public
`Monty`/`MontySession`, adjudicated strictly by `packages/monty_conformance`
(return values, raised messages and frames). The failing set must equal the
manifest in `packages/monty_conformance/lib/src/worker_corpus_manifest.dart`,
both ways, and the script asserts a floor and the scorecard line, so a leg
cannot pass without having run the corpus.

Its expectations come from the `# Return=` / `# Raise=` directives authored
upstream, so unlike a comparison of two of our own encoders it is **not
circular**. CI runs it as `corpus-worker` and `corpus-worker-web`; the gate
does not.

## 6. Rust

```bash
cd native/worker
cargo fmt --check
cargo clippy --locked --all-targets -- -D warnings
cargo test --locked --release
cargo deny check
```

The gate runs the same four (`cargo_fmt`, `cargo_clippy`, `cargo_test`,
`cargo_deny`).

## 7. Example smoke

```bash
bash tool/run_example_smoke.sh
```

**Verifies:** every `example/*.dart` runs to completion against the native
worker, and that the number of examples matches `tool/example_floor.sh`.
`dart analyze` only checks that an example type-checks.

## 8. The gate: run this before every commit

```bash
bash tool/gate.sh               # read-only; never rebuilds, never restores
```

Runs the checks, the unit suites, the worker suites, Rust, the examples and
the coverage ratchet, and prints `GATE GREEN` or `GATE RED` with per-step logs
in `SUMMARY.txt`. **Read the exit code and the verdict line, not the tail of
the summary.** A `FAIL` in the middle of `SUMMARY.txt` is invisible to
`tail`; see trap 5.

The gate also checks its own read-only promise: it snapshots
`git status --porcelain` before step 1 and compares afterwards, and reports
`FAIL read_only_tree` if the run modified anything. It compares against the
snapshot rather than against a clean tree, so a work-in-progress tree does not
trip it.

The DCM ratchets run on the host, against committed `HEAD`:
`bash tool/dcm_host_gate.sh` (see `AGENTS.md` section 4).

---

## Traps

Each of these cost real time. None are guessable.

### 1. A stale worker silently tests the OLD code

`dart test` on the VM spawns whatever executable is in
`lib/src/bin/<os>-<arch>/`. After changing `native/worker/`, run
`bash tool/build_worker.sh`; `bash tool/build_worker.sh --check` fails when
it is stale, and the gate's unit step runs that check first. The browser
tests load the committed `lib/assets/` instead: rebuild them with
`bash tool/prebuild.sh` (trap 7).

### 2. `dart format --output=none` CHECKS; it does not write

Using it to "fix" formatting verifies nothing and leaves the file unformatted.
To write: `dart format --line-length=80 lib/ test/ hook/ tool/`.
To check: add `--output=none --set-exit-if-changed`.

### 3. Explicit file lists silently drop new tests

A file can exist, be correctly tagged, pass locally, and never run in CI.
Prefer a glob or a directory. If a list is unavoidable, add a guard that fails
on an unlisted file. Every suite also has a floor under its test count
(`AGENTS.md` section 3), because `dart test` exits 0 when a filter matches
nothing.

### 4. `--compiler=kernel` is the JIT default, not AOT

A job named `test-aot` once ran no AOT and ended in an `echo` claiming
success. It now builds a real consumer with `dart build cli` and runs it from
the bundle directory, with the worker library bundled through the hook opt-in
and served by self-relaunch:

```bash
cd tool/aot_worker
dart pub get
dart build cli -o build/aot
./build/aot/bundle/bin/aot_worker s10_external_call.json
```

This is a separate CI check: `tool/gate.sh` has no AOT step.

### 5. `$?` after a pipe is the LAST command's status

`cmd | tail -3; echo $?` reports `tail`'s exit code. Capture the status of the
command you care about, or use `${PIPESTATUS[0]}`.

### 6. A bare `return` in a fixture harness is a passing test that asserts nothing

646 of 1593 registered tests once did exactly this (#130). If a fixture cannot
be run, either do not register it, or call `markTestSkipped(reason)`; never
return silently, which reports green.

### 7. The wasm build is not byte-reproducible

An unchanged tree produces a different `.wasm`, so **a `git diff` on the blob
tells you nothing**. Building and gating are therefore separate, and **the
gate never writes to the working tree**:

| | |
|---|---|
| `bash tool/prebuild.sh` | writes `lib/assets/` and `tool/wasm-provenance.json`. You run it, you commit the result. |
| `bash tool/gate.sh` | reads `lib/assets/`. Never rebuilds, never restores. |

The gate's web steps exercise the exact bytes you are about to commit.
Forgetting `prebuild.sh` is caught by `tool/check_asset_freshness.sh` (gate
step `asset_fresh`), which hashes the **inputs** (`native/worker/` without
`target/`, `native/rust-toolchain.toml`, `tool/build_worker_wasm.sh` and
`tool/rust_remap.sh`) rather than the non-reproducible output.

That record lives in `tool/`, which is `.pubignore`d, not in `lib/assets/`,
which ships. It is deliberately **not** a supply-chain attestation: an
in-package hash of an in-package artefact travels in the same archive as the
binary it attests. pub.dev's archive sha256, recorded in `pubspec.lock`, is
strictly stronger.

---

## Verification philosophy

Two disciplines decide whether any of the above is worth running:
**a test is not verified until you have seen it fail**, and **never assert
current behaviour just to make a test pass**. Both, with the cases that prove
them, live in
[`testing-philosophy.md`](testing-philosophy.md): methodology, not procedure,
so it is deliberately not in this runbook.
