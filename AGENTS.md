# AGENTS.md — dart_monty_core build & test guide for AI agents

This file tells AI agents exactly how to build every artifact in this repo,
what commands to run, and **exactly where to put the output files**.

---

## Repository layout (critical paths)

```
dart_monty_core/
├── native/                     # Rust source (monty engine + C ABI)
│   ├── src/                    # Rust source files
│   └── target/                 # Cargo build output (git-ignored)
│       └── wasm32-wasip1/release/dart_monty_native.wasm  ← built by cargo
│
├── js/                         # JS bridge (esbuild)
│   ├── src/                    # JS source (wasm_glue.js, worker_src.js, bridge.js)
│   ├── build.js                # esbuild script
│   └── package.json
│
├── assets/                     # Pre-built JS+WASM artifacts (git-ignored)
│   ├── dart_monty_bridge.js    ← built by js/build.js
│   ├── dart_monty_worker.js    ← built by js/build.js
│   └── dart_monty_native.wasm  ← copied from native/target/ by cargo build
│
├── test/integration/
│   ├── wasm_runner.dart        # dart2js test runner
│   ├── wasm_runner_wasm.dart   # dart2wasm test runner
│   └── web/                   # Served by test HTTP server (most files git-ignored)
│       ├── fixtures.html       # dart2js entry point
│       ├── wasm_runner_wasm.html  # dart2wasm entry point
│       ├── dart_monty_bridge.js   ← copied from assets/ before each test run
│       ├── dart_monty_worker.js   ← copied from assets/
│       ├── dart_monty_native.wasm ← copied from assets/
│       ├── wasm_runner.dart.js    ← dart compile js output
│       ├── wasm_runner.mjs        ← dart compile wasm output
│       └── wasm_runner.wasm       ← dart compile wasm output
│
├── packages/
│   ├── dart_monty_web/         # Browser REPL demo (dart2js)
│   │   ├── pubspec.yaml
│   │   └── web/
│   │       ├── index.html
│   │       ├── repl_demo.dart  # Demo source
│   │       ├── .gitignore      # Excludes compiled artifacts below
│   │       ├── repl_demo.dart.js    ← dart compile js output (NOT committed)
│   │       ├── dart_monty_bridge.js ← copied from assets/ (NOT committed)
│   │       ├── dart_monty_worker.js ← copied from assets/ (NOT committed)
│   │       └── dart_monty_native.wasm ← copied from assets/ (NOT committed)
│   └── dart_monty_flutter/     # Flutter REPL demo
│       ├── pubspec.yaml
│       └── lib/main.dart
│
└── tool/
    ├── test_wasm.sh            # Full dart2js test pipeline (build + serve + Chrome)
    └── serve_demo.sh           # Full web demo pipeline (build + serve + open browser)
```

---

## Build step 1 — Rust → WASM binary

```bash
cd native
cargo build --target wasm32-wasip1 --release
```

**Output:** `native/target/wasm32-wasip1/release/dart_monty_native.wasm`

**Copy to assets:**
```bash
mkdir -p assets
cp native/target/wasm32-wasip1/release/dart_monty_native.wasm assets/
```

---

## Build step 2 — JS bridge

```bash
cd js
npm install           # first time; add --force on Linux (EBADPLATFORM for wasm32 pkg)
node build.js
```

**Output** (written directly to `assets/`):
- `assets/dart_monty_bridge.js`
- `assets/dart_monty_worker.js`

`build.js` also copies `dart_monty_native.wasm` from
`native/target/wasm32-wasip1/release/` into `assets/` automatically,
so step 1's copy is only needed if you run build steps out of order.

---

## Build step 3 — dart2js test runner

```bash
dart pub get
dart compile js \
  test/integration/wasm_runner.dart \
  -o test/integration/web/wasm_runner.dart.js \
  --no-source-maps
```

**Output:** `test/integration/web/wasm_runner.dart.js`

---

## Build step 4 — dart2wasm test runner

```bash
dart pub get   # if not already done
dart compile wasm \
  test/integration/wasm_runner_wasm.dart \
  -o test/integration/web/wasm_runner.wasm
```

**Output** (dart compile wasm always produces both):
- `test/integration/web/wasm_runner.wasm`
- `test/integration/web/wasm_runner.mjs`

---

## Copy assets to test web dir (before serving)

```bash
cp assets/dart_monty_bridge.js   test/integration/web/
cp assets/dart_monty_worker.js   test/integration/web/
cp assets/dart_monty_native.wasm test/integration/web/
```

These three files are removed by `test_wasm.sh`'s cleanup trap after each run.
**Always re-copy before running tests manually.**

---

## Running the tests

### dart2js — full build pipeline (recommended)

```bash
bash tool/test_wasm.sh
```

### dart2js — skip build (assets already built)

```bash
bash tool/test_wasm.sh --skip-build
```

This still re-compiles `wasm_runner.dart` to JS and copies assets.
`--skip-build` only skips the `cargo build` + `npm install && node build.js` steps.

### dart2wasm — manual run after build steps 1-4 above

The `test_wasm.sh` script runs `fixtures.html` (dart2js).
To test dart2wasm separately, run Chrome on `wasm_runner_wasm.html`:

```bash
# 1. Copy assets (if not already done)
cp assets/dart_monty_bridge.js   test/integration/web/
cp assets/dart_monty_worker.js   test/integration/web/
cp assets/dart_monty_native.wasm test/integration/web/

# 2. Start COOP/COEP server (must be running; test_wasm.sh starts one on :8097)
#    If test_wasm.sh server is still up, reuse it. Otherwise start manually:
python3 - test/integration/web 8097 <<'PYEOF' &
import sys, http.server, functools
directory = sys.argv[1]; port = int(sys.argv[2])
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        super().end_headers()
    def log_message(self, *a): pass
http.server.HTTPServer(('127.0.0.1', port), functools.partial(H, directory=directory)).serve_forever()
PYEOF

# 3. Run headless Chrome on wasm_runner_wasm.html
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
LOG=$(mktemp)
timeout 120 "$CHROME" --headless=new --disable-gpu --no-sandbox \
  --disable-dev-shm-usage --enable-logging=stderr --v=0 \
  "http://127.0.0.1:8097/wasm_runner_wasm.html" 2>"$LOG" || true
grep -oE 'FIXTURE_RESULT:\{[^}]+\}' "$LOG" | grep '"ok":false'
grep -oE 'FIXTURE_DONE:\{[^}]+\}' "$LOG"
rm "$LOG"
```

**Expected result:** `FIXTURE_DONE:{"total":464,"passed":464,"failed":0,"skipped":0,...}`

---

## Copy assets for web demo

The web demo (`packages/dart_monty_web/web/`) also needs the bridge assets.
These are **not committed** (`.gitignore` excludes them).

```bash
cp assets/dart_monty_bridge.js   packages/dart_monty_web/web/
cp assets/dart_monty_worker.js   packages/dart_monty_web/web/
cp assets/dart_monty_native.wasm packages/dart_monty_web/web/
```

Compile the demo Dart app:

```bash
cd packages/dart_monty_web
dart pub get
dart compile js web/repl_demo.dart -o web/repl_demo.dart.js
```

Then use `tool/serve_demo.sh` to build+copy+serve all in one step.

---

## Quick reference — file provenance

| File | Built by | Copy destination |
|---|---|---|
| `dart_monty_native.wasm` | `cargo build --target wasm32-wasip1` | `assets/`, `test/integration/web/`, `packages/dart_monty_web/web/` |
| `dart_monty_bridge.js` | `node js/build.js` | `assets/`, `test/integration/web/`, `packages/dart_monty_web/web/` |
| `dart_monty_worker.js` | `node js/build.js` | `assets/`, `test/integration/web/`, `packages/dart_monty_web/web/` |
| `wasm_runner.dart.js` | `dart compile js wasm_runner.dart` | `test/integration/web/` |
| `wasm_runner.wasm` + `.mjs` | `dart compile wasm wasm_runner_wasm.dart` | `test/integration/web/` |
| `repl_demo.dart.js` | `dart compile js repl_demo.dart` | `packages/dart_monty_web/web/` |

---

## What NOT to commit

- `assets/*.js`, `assets/*.wasm` — git-ignored, built artifacts
- `test/integration/web/dart_monty_*.js`, `test/integration/web/*.wasm` — cleaned up by test runner
- `test/integration/web/wasm_runner.dart.js*` — compiled output
- `test/integration/web/wasm_runner.mjs`, `wasm_runner.wasm` — compiled output
- `packages/dart_monty_web/web/repl_demo.*js`, `packages/dart_monty_web/web/*.wasm` — demo compiled output
- `packages/dart_monty_web/web/dart_monty_*.js` — bridge assets, not committed
- `packages/dart_monty_web/web/@pydantic/` — npm package, not committed

---

## Stale artifacts warning

If you modify any source file, you **must** rebuild the corresponding artifact
before running tests. The mapping:

| Source changed | Rebuild |
|---|---|
| `native/src/**` | Step 1 (cargo) + Step 2 (npm/node) |
| `js/src/**` | Step 2 (npm/node) |
| `test/integration/wasm_runner.dart` | Step 3 (dart compile js) |
| `test/integration/wasm_runner_wasm.dart` | Step 4 (dart compile wasm) |
| `packages/dart_monty_web/web/repl_demo.dart` | `dart compile js` in dart_monty_web |
| `lib/**` (library code) | Steps 3 + 4 (re-compile dart runners) |
