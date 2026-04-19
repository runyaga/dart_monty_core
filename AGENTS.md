# AGENTS.md — dart_monty_core build & test guide

This file is the authoritative reference for building every artifact in this
repo, running every test suite, and operating every demo — locally and in CI.
Read it before touching any build step.

---

## Artifact flow — the mental model

```
native/src/ (Rust)
  ├─ cargo build --release
  │     → libdart_monty_core_native.{dylib,so,dll}   [FFI backend: VM/desktop]
  │
  ├─ cargo build --bin oracle
  │     → native/target/debug/oracle             [FFI test oracle]
  │
  └─ cargo build --target wasm32-wasip1 --release
        → dart_monty_core_native.wasm   (copied to assets/)
              │
              ▼
js/src/ (esbuild via node build.js)
  └─────────────────────────────── assets/          ← canonical staging area
                                   ├── dart_monty_core_native.wasm
                                   ├── dart_monty_core_bridge.js
                                   └── dart_monty_core_worker.js
                                         │
              ┌──────────────────────────┼──────────────────────────┐
              ▼                          ▼                          ▼
  test/integration/web/           packages/dart_monty_web/web/   packages/dart_monty_flutter/
  ├── dart_monty_core_bridge.js    ├── dart_monty_core_bridge.js       (uses FFI dylib at runtime)
  ├── dart_monty_core_worker.js    ├── dart_monty_core_worker.js
  ├── dart_monty_core_native.wasm  ├── dart_monty_core_native.wasm
  ├── @pydantic/wasi-*             ├── @pydantic/wasi-*
  ├── wasm_runner.dart.js     └── repl_demo.dart.js
  └── wasm_runner.wasm            (dart compile js)
      (dart compile wasm)
```

**Rule**: `assets/` is the only directory that receives build output directly.
Everything else copies from `assets/`. The `assets/` files are git-ignored;
downstream copies are temporary and are cleaned up by script traps.

---

## Pre-built reference worktree

A local worktree at `/Users/runyaga/dev/dart_monty_core--wasm-support`
(branch `feature/wasm-flutter-support`) has **all artifacts pre-built** and
committed. When the Rust or npm build chain is broken or slow, copy from here:

```bash
SRC=/Users/runyaga/dev/dart_monty_core--wasm-support

# Populate assets/ (all three files)
cp "$SRC/assets/dart_monty_core_bridge.js"   assets/
cp "$SRC/assets/dart_monty_core_worker.js"   assets/
cp "$SRC/assets/dart_monty_core_native.wasm" assets/

# Populate test web dir directly (skip the copy step below)
cp "$SRC/test/integration/web/dart_monty_core_bridge.js"   test/integration/web/
cp "$SRC/test/integration/web/dart_monty_core_worker.js"   test/integration/web/
cp "$SRC/test/integration/web/dart_monty_core_native.wasm" test/integration/web/
cp "$SRC/test/integration/web/wasm_runner.dart.js"    test/integration/web/
cp "$SRC/test/integration/web/wasm_runner.mjs"        test/integration/web/
cp "$SRC/test/integration/web/wasm_runner.wasm"       test/integration/web/
```

---

## Repository layout

```
dart_monty_core/
├── native/                     # Rust crate (monty engine + C ABI)
│   ├── src/lib.rs              # FFI C exports + wasm target
│   ├── src/bin/oracle.rs       # Oracle CLI binary (FFI test source of truth)
│   ├── include/dart_monty.h    # C header (source for ffigen)
│   └── target/                 # Cargo output (git-ignored)
│
├── js/                         # JS bridge (esbuild)
│   ├── src/bridge.js           # Main-thread IIFE → dart_monty_core_bridge.js
│   ├── src/worker_src.js       # Worker ESM → dart_monty_core_worker.js
│   ├── src/wasm_glue.js        # WASM C API wrappers (imported by worker)
│   ├── build.js                # esbuild bundler script
│   └── package.json
│
├── assets/                          # Built JS+WASM staging area (git-ignored)
│   ├── dart_monty_core_bridge.js    ← node js/build.js
│   ├── dart_monty_core_worker.js    ← node js/build.js
│   └── dart_monty_core_native.wasm  ← cargo build wasm32-wasip1
│
├── lib/                        # Dart library source
│   └── src/
│       ├── ffi/                # FFI backend (dart:ffi)
│       │   └── generated/dart_monty_bindings.dart  ← ffigen output
│       ├── wasm/               # WASM backend (JS interop)
│       └── platform/           # Shared platform abstractions
│
├── test/integration/
│   ├── wasm_runner.dart        # dart2js fixture runner (464 tests)
│   ├── wasm_runner_wasm.dart   # dart2wasm fixture runner (464 tests)
│   ├── oracle_ffi_test.dart    # FFI conformance (spawns oracle binary)
│   ├── _fixture_corpus.dart    # 464 Python fixtures (embedded const map)
│   └── web/                    # Served by test HTTP server
│       ├── fixtures.html       # dart2js entry point
│       └── wasm_runner_wasm.html  # dart2wasm entry point
│
├── packages/
│   ├── dart_monty_web/         # Browser REPL demo (pure Dart web)
│   └── dart_monty_flutter/     # Flutter REPL demo (mobile/desktop/web)
│
├── docs/
│   └── index.html              # GitHub Pages cover page
│
└── tool/
    ├── test_wasm.sh            # Full WASM test pipeline
    ├── serve_demo.sh           # Web demo build + serve
    ├── run_flutter_demo.sh     # Flutter demo launcher
    ├── generate_bindings.sh    # ffigen regeneration
    ├── install-hooks.sh        # Install pre-commit hook
    └── pre-commit.sh           # Pre-commit checks (fmt, analyze, bindings)
```

---

## One-time setup

```bash
# Install pre-commit hooks
bash tool/install-hooks.sh

# Add Rust targets
rustup target add wasm32-wasip1          # WASM builds
rustup component add rustfmt clippy      # code quality
```

---

## Build step 1 — Rust FFI dylib (for VM/desktop tests and Flutter)

```bash
cd native
cargo build --release
```

**Output** (platform-specific):
- macOS: `native/target/release/libdart_monty_core_native.dylib`
- Linux: `native/target/release/libdart_monty_core_native.so`
- Windows: `native/target/release/dart_monty_core_native.dll`

**Used by**: `MontyFfi` backend (dart:ffi), Flutter REPL demo, FFI conformance tests.

---

## Build step 1b — Rust oracle binary (for FFI conformance tests)

```bash
cd native
cargo build --bin oracle
```

**Output**: `native/target/debug/oracle`

**Used by**: `oracle_ffi_test.dart` — spawns oracle as a subprocess. Each of
the 464 fixtures is run through both the oracle and the FFI binding; outputs
must match exactly.

**How the oracle works**:
```
dart test oracle_ffi_test.dart
  │
  ├── for each fixture:
  │     oracle process ← fixture source code (stdin)
  │     oracle stdout  → expected result (value or exception type)
  │     FFI binding    ← same fixture source code
  │     FFI result     → actual result
  │     assert oracle == FFI
  │
  └── 464 fixtures, all must pass
```

The oracle binary, FFI dylib, and WASM binary are **all compiled from the same
`native/src/lib.rs`** — they must stay in sync. If you change Rust source,
rebuild all three.

---

## Build step 2 — Rust WASM binary

```bash
cd native
cargo build --target wasm32-wasip1 --release
```

**Output**: `native/target/wasm32-wasip1/release/dart_monty_core_native.wasm`

The WASM binary is the monty interpreter compiled to run inside a browser
WASM Worker. It is loaded by `dart_monty_core_worker.js` at runtime.

---

## Build step 3 — JS bridge (esbuild)

```bash
cd js

# --force required on x64 Linux: @pydantic/monty-wasm32-wasi declares
# cpu:wasm32; npm refuses to install on non-wasm32 hosts without --force.
# The package is a WASM binary that runs in a WASI runtime regardless of
# host CPU — the platform check is a false positive.
npm install --force

node build.js
```

**Output** (written directly to `assets/`):
- `assets/dart_monty_core_bridge.js` — IIFE, loaded on the main thread
- `assets/dart_monty_core_worker.js` — ESM Worker, loads + runs the WASM binary
- `assets/dart_monty_core_native.wasm` — copied from `native/target/wasm32-wasip1/release/dart_monty_core_native.wasm`

`build.js` copies the WASM binary automatically, so build step 2 is only
needed if you run steps out of order.

---

## Build step 3b — WASI runtime (required for dart2wasm tests and web demo)

The dart2wasm runner and the web demo both require the WASI browser runtime
from `@pydantic/monty-wasm32-wasi`. `node build.js` does **not** copy this
file — it must be copied manually.

```bash
# For WASM fixture tests:
mkdir -p test/integration/web/@pydantic/monty-wasm32-wasi
cp js/node_modules/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs \
   test/integration/web/@pydantic/monty-wasm32-wasi/

# For web demo:
mkdir -p packages/dart_monty_web/web/@pydantic/monty-wasm32-wasi
cp js/node_modules/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs \
   packages/dart_monty_web/web/@pydantic/monty-wasm32-wasi/
```

**Symptom if missing**: headless Chrome loads `wasm_runner_wasm.html` and
reports `TypeError: Cannot read properties of undefined (reading 'init')` for
every fixture. The `wasi-worker-browser.mjs` file is the WASI polyfill that
the worker needs to initialise the WASM module.

---

## Build step 4 — dart2js test runner

```bash
dart pub get
dart compile js \
  test/integration/wasm_runner.dart \
  -o test/integration/web/wasm_runner.dart.js \
  --no-source-maps
```

**Output**: `test/integration/web/wasm_runner.dart.js`

---

## Build step 5 — dart2wasm test runner

```bash
dart compile wasm \
  test/integration/wasm_runner_wasm.dart \
  -o test/integration/web/wasm_runner.wasm
```

**Output** (dart compile wasm always produces both):
- `test/integration/web/wasm_runner.wasm`
- `test/integration/web/wasm_runner.mjs`

---

## Copy assets to test web dir

Before running tests manually, copy from `assets/` into `test/integration/web/`.
`tool/test_wasm.sh` does this automatically; its cleanup trap removes them on exit.

```bash
cp assets/dart_monty_core_bridge.js   test/integration/web/
cp assets/dart_monty_core_worker.js   test/integration/web/
cp assets/dart_monty_core_native.wasm test/integration/web/
# Also copy WASI runtime (step 3b above)
```

---

## Running the FFI conformance tests (464 fixtures)

```bash
# Build prerequisites (steps 1 + 1b)
cd native && cargo build --release && cargo build --bin oracle && cd ..
dart pub get
dart test test/integration/oracle_ffi_test.dart \
  -p vm --run-skipped --tags=ffi --reporter=expanded
```

**Expected**: 464 fixtures pass.

---

## Running the WASM conformance tests (464 fixtures)

### dart2js — full build pipeline

```bash
bash tool/test_wasm.sh
# Runs: cargo build → npm install --force → node build.js → dart compile js
#       → copy assets → COOP/COEP server → headless Chrome
```

### dart2js — skip build (assets already built)

```bash
bash tool/test_wasm.sh --skip-build
# Skips cargo + npm; still re-compiles wasm_runner.dart and copies assets
```

### dart2wasm — manual run

```bash
# 1. Ensure assets are built (steps 1–3b above)
# 2. Build dart2wasm runner (step 5)
# 3. Copy assets to test web dir
# 4. Ensure COOP/COEP server is running on :8097 (test_wasm.sh starts one)
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
LOG=$(mktemp)
timeout 120 "$CHROME" --headless=new --disable-gpu --no-sandbox \
  --disable-dev-shm-usage --enable-logging=stderr --v=0 \
  "http://127.0.0.1:8097/wasm_runner_wasm.html" 2>"$LOG" || true
python3 -c "
import re, sys
log = open('$LOG').read()
for f in re.findall(r'FIXTURE_RESULT:\{[^}]+\"ok\":false[^}]*\}', log)[:10]: print(f)
for d in re.findall(r'FIXTURE_DONE:\{[^}]+\}', log): print(d)
"
rm "$LOG"
```

**Expected**: `FIXTURE_DONE:{"total":464,"passed":464,"failed":0,"skipped":0,...}`

---

## Running Rust checks

All four checks run inside `native/`:

```bash
cd native

# Format
cargo fmt --check

# Lints (all clippy pedantic + extras; -D warnings = fail on any warning)
cargo clippy -- -D warnings

# Dependency audit (licenses, advisories, bans)
cargo deny check

# Tests with line-coverage gate (≥60% required; src/bin/ excluded from measurement)
cargo llvm-cov --summary-only --ignore-filename-regex 'src/bin/'
```

`cargo llvm-cov` requires the `llvm-tools-preview` component and `cargo-llvm-cov`:

```bash
rustup component add llvm-tools-preview
cargo install cargo-llvm-cov
```

There are currently no `#[test]` functions in `native/src/` — coverage comes
entirely from the oracle binary exercising the library. If line coverage drops
below 60% CI will fail.

---

## Running Dart static checks

```bash
dart pub get

# Static analysis (fatal on infos)
dart analyze --fatal-infos

# Format check
dart format --line-length=80 --set-exit-if-changed lib/ test/ hook/ tool/
```

---

## Running Dart unit tests (JIT + AOT)

There are **no unit tests yet** — only integration tests. Both commands below
exit 79 (no tests found), which is tolerated by CI until unit tests are added.

```bash
# JIT
dart test --exclude-tags=ffi,wasm,integration,ladder --coverage=coverage

# AOT (kernel)
dart test --exclude-tags=ffi,wasm,integration,ladder --platform vm --compiler=kernel
```

---

## Running DCM (code metrics + rules)

DCM requires a licence key; it runs in CI only. For local use install DCM and
substitute your own credentials:

```bash
dart pub get
dcm calculate-metrics --ci-key=<KEY> --email=<EMAIL> lib/
dcm analyze          --ci-key=<KEY> --email=<EMAIL> lib/
```

---

## Running demos

### Web REPL (browser)

```bash
bash tool/serve_demo.sh              # dart2js (default), opens :8098
bash tool/serve_demo.sh --dart2wasm  # dart2wasm variant
bash tool/serve_demo.sh --skip-build # reuse existing assets
```

**What it does**: cargo build → npm install --force → node build.js →
copy assets + WASI runtime → dart compile js → Python COOP/COEP server → open browser.

### Flutter REPL (mobile/desktop)

```bash
# Prerequisite: build FFI dylib (build step 1)
bash tool/run_flutter_demo.sh [--device macos]
```

### GitHub Pages demo

Deployed automatically on every push to `main` via `.github/workflows/deploy-pages.yml`.

URL: **https://runyaga.github.io/dart_monty_core/**

- `/` — cover page with links to both demos
- `/repl/` — Web REPL (dart2js, no COOP/COEP headers on Pages)
- `/flutter/` — Flutter web REPL

---

## CI pipeline

```
changes (path filter)
  │
  ├─► rust ──────────────────────────────────────► build-wasm ──► test-wasm
  │   (fmt + clippy + deny + llvm-cov ≥60%)       (wasm32-wasip1)  (dart2js + dart2wasm
  │                                                                  464 fixtures each)
  ├─► ffigen ─► test     (analyze + fmt + unit JIT + coverage + patch-coverage gate 70%)
  │          ├─ test-aot (unit AOT/kernel — exit 79 tolerated until unit tests exist)
  │          ├─ test-ffi (464 FFI fixtures)
  │          └─ dcm      (calculate-metrics + analyze rules)
  │
  └─► deploy-pages (on main push)
      (cargo + npm + dart compile → GitHub Pages)
```

**Artifact hand-offs**:
- `ffigen` uploads `dart_monty_bindings.dart` → consumed by `test`, `test-ffi`, `dcm`
- `build-wasm` uploads `dart_monty_core_native.wasm` → consumed by `test-wasm`
- `test` uploads `lcov.info` → consumed by `patch-coverage`

**Key CI flags**:
- `npm install --force` — required in `test-wasm` and `deploy-pages` (EBADPLATFORM)
- `--no-source-maps` on `dart compile js` — reduces output size in CI
- `timeout-minutes: 15` on `ffigen` — `libclang-dev` install is slow on Ubuntu

---

## File provenance table

| File | Built by | Destination(s) |
|---|---|---|
| `libdart_monty_core_native.{dylib,so,dll}` | `cargo build --release` | (loaded by dart:ffi at runtime) |
| `native/target/debug/oracle` | `cargo build --bin oracle` | (spawned as subprocess by dart test) |
| `dart_monty_core_native.wasm` | `cargo build --target wasm32-wasip1` | `assets/` → `test/integration/web/`, `packages/dart_monty_web/web/` |
| `dart_monty_core_bridge.js` | `node js/build.js` | `assets/` → same as above |
| `dart_monty_core_worker.js` | `node js/build.js` | `assets/` → same as above |
| `wasi-worker-browser.mjs` | npm (pre-built) | `test/integration/web/@pydantic/...`, `packages/dart_monty_web/web/@pydantic/...` |
| `wasm_runner.dart.js` | `dart compile js` | `test/integration/web/` |
| `wasm_runner.wasm` + `.mjs` | `dart compile wasm` | `test/integration/web/` |
| `repl_demo.dart.js` | `dart compile js` | `packages/dart_monty_web/web/` |
| `dart_monty_bindings.dart` | `dart run ffigen` | `lib/src/ffi/generated/` |
| `_fixture_corpus.dart` | `dart tool/generate_fixture_corpus.dart` | `test/integration/` |

---

## What NOT to commit

```
assets/dart_monty_core_*.{js,wasm}          # git-ignored; built at CI time
test/integration/web/dart_monty_core_*.js   # git-ignored; copied before test run
test/integration/web/dart_monty_core_*.wasm # git-ignored; copied before test run
test/integration/web/wasm_runner.dart.js*  # git-ignored; dart compile js output
test/integration/web/@pydantic/        # git-ignored; WASI runtime copy
packages/dart_monty_web/web/repl_demo.dart.js   # git-ignored (see web/.gitignore)
packages/dart_monty_web/web/*.wasm     # git-ignored
packages/dart_monty_web/web/dart_monty_core_*.js     # git-ignored
packages/dart_monty_web/web/@pydantic/ # git-ignored
```

**Exception**: `test/integration/web/wasm_runner.mjs`, `wasm_runner.wasm`,
`wasm_runner.support.js`, `wasm_runner.wasm.map` are committed so the
`wasm_runner_wasm.html` page works in CI without a full dart2wasm build step.

---

## Stale artifact rebuild matrix

If you modify any source file, rebuild the corresponding artifact before testing.

| Source changed | Rebuild required |
|---|---|
| `native/src/**` | Steps 1 + 1b + 2 + 3, then copy assets |
| `js/src/**` | Step 3 (npm/node), then copy assets |
| `test/integration/wasm_runner.dart` | Step 4 (dart compile js) |
| `test/integration/wasm_runner_wasm.dart` | Step 5 (dart compile wasm) |
| `packages/dart_monty_web/web/repl_demo.dart` | `dart compile js` in dart_monty_web |
| `packages/dart_monty_flutter/lib/**` | `flutter build` for target platform |
| `lib/**` (library source) | Steps 4 + 5 (re-compile dart runners) |
| `native/include/dart_monty.h` | Run `bash tool/generate_bindings.sh` |

---

## Common failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `EBADPLATFORM` on `npm install` | `@pydantic/monty-wasm32-wasi` declares `cpu:wasm32` | `npm install --force` |
| Chrome `TypeError: Cannot read ... 'init'` | `wasi-worker-browser.mjs` not copied | Run step 3b (WASI runtime copy) |
| dart2wasm 0/464 all fail | Bridge assets missing from `test/integration/web/` | Copy from `assets/` or from wasm-support worktree |
| FFI `DynamicLibraryLoadError` | Native dylib not built | `cd native && cargo build --release` |
| FFI tests: `ProcessException` on oracle | Oracle binary not built | `cd native && cargo build --bin oracle` |
| Bindings stale check fails in CI | C header changed, ffigen not re-run | `bash tool/generate_bindings.sh` |
| `dart analyze` errors in Flutter package | Flutter SDK not in PATH for analyzer | Add `packages/dart_monty_flutter/**` to `analysis_options.yaml` excludes |
| GitHub Pages REPL broken (SharedArrayBuffer) | Pages can't set COOP/COEP headers | Expected — dart2js works; dart2wasm needs local serve |
