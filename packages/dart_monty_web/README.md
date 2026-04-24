# dart_monty_web

Browser REPL demo for [Monty](https://github.com/pydantic/monty) — a sandboxed
Python interpreter in Rust, wrapped by `dart_monty_core`.

> **Note for JS/npm users**: If you are building a JavaScript or TypeScript
> application, use [`@pydantic/monty`](https://www.npmjs.com/package/@pydantic/monty)
> directly — that is the canonical npm package maintained by the Monty authors.
> `dart_monty_web` exists to demonstrate `dart_monty_core` for **Dart web**
> developers who want the same interpreter through Dart APIs.
> For **Flutter Web**, depend on `dart_monty` + `dart_monty_core` and
> call `DartMonty.ensureInitialized()`. See dart_monty_core's top-level
> README "WASM (Flutter Web)" section.

This is a **reference example**: copy the patterns here to build your own
Dart web app on top of `dart_monty_core`.

---

## What it is

A pure Dart web app (not Flutter) with a REPL backed by `MontyWasm`, which runs
the Monty engine inside a **WASM Worker** in the browser. Supports both dart2js
and dart2wasm compilation targets.

---

## How dart_monty_core is used

```dart
import 'package:dart_monty_core/dart_monty_core.dart';

// MontyRepl auto-selects the WASM backend when compiled for web
final repl = MontyRepl();

// Feed Python expressions
final result = await repl.feed('x = 42');
final r2 = await repl.feed('x * 2');
print(r2.value); // MontyInt(84)

// Inject per-invocation inputs — no string-formatting needed
final r3 = await repl.feed(
  'output = [x * scale for x in data]',
  inputs: {'data': [1, 2, 3], 'scale': 10},
);

if (result.error != null) {
  print('${result.error!.excType}: ${result.error!.message}');
}
```

### Concurrent REPLs

Multiple `MontyRepl` instances can coexist concurrently on the WASM backend.
Each instance generates a unique `replId` that is threaded through the JS
bridge into the Web Worker, so independent Rust heap handles are maintained
in a `Map` rather than a single scalar:

```dart
final repl1 = MontyRepl();
final repl2 = MontyRepl();

await repl1.feed('x = 1');
await repl2.feed('x = 2');

print((await repl1.feed('x')).value); // MontyInt(1)
print((await repl2.feed('x')).value); // MontyInt(2)
```

### Compile and run precompiled

`Monty.compile()` and `Monty.runPrecompiled()` are fully supported on the WASM
backend. Use them to avoid re-parsing the same script on repeated executions:

```dart
final binary = await Monty.compile('output = [x * 2 for x in data]');
final monty = Monty();
final result = await monty.runPrecompiled(binary);
```

See [`web/repl_demo.dart`](web/repl_demo.dart) for the full wiring including DOM
manipulation, button event handlers, and the dispose pattern.

---

## Key concepts

### COOP/COEP headers (required for SharedArrayBuffer)

The WASM Worker uses `SharedArrayBuffer` for zero-copy communication. Browsers
only allow `SharedArrayBuffer` on pages served with:

```
Cross-Origin-Opener-Policy: same-origin
Cross-Origin-Embedder-Policy: require-corp
```

The included Python server in `tool/serve_demo.sh` sets these headers. GitHub
Pages **cannot** set custom headers — the dart2js demo works on Pages; the
dart2wasm demo requires local serve.

### Assets

`dart_monty_core_bridge.js`, `dart_monty_core_worker.js`, and
`dart_monty_core_native.wasm` are **committed to git** (Mode A asset
distribution) and ship in the pub.dev package under `assets/`.
Consumers installing via `dart pub add` receive them pre-built and do
not need Node.js or npm to run. CI rebuilds from source on every PR
and verifies the committed files match; regenerate locally with
`bash tool/prebuild.sh` at the repo root.

`repl_demo.dart.js` (the compiled Dart app) is always git-ignored and must be
compiled locally via `dart compile js`. The `tool/serve_demo.sh` script
handles this automatically.

### Why `npm install --force`?

The `@pydantic/monty-wasm32-wasi` package declares `"cpu": "wasm32"`. On x64
Linux (CI), npm refuses to install it without `--force`. The package is a WASM
binary that runs in a WASI runtime regardless of host CPU — the platform check
is a false positive.

---

## Prerequisites

```bash
# 1. Rust toolchain with WASM target
rustup target add wasm32-wasip1

# 2. Node.js 18+
node --version

# 3. Dart SDK (included with Flutter, or standalone)
dart --version
```

---

## Build and serve

### Option A — Use the tool script (recommended)

```bash
# From repo root — builds everything and opens browser on :8098
bash tool/serve_demo.sh

# dart2wasm variant (requires local serve for COOP/COEP)
bash tool/serve_demo.sh --dart2wasm

# Reuse existing assets (skip cargo + npm build)
bash tool/serve_demo.sh --skip-build
```

### Option B — Manual steps

```bash
# 1. Build Rust WASM binary (from repo root)
cd native && cargo build --release --target wasm32-wasip1 && cd ..

# 2. Build JS bridge (outputs to assets/)
cd js && npm install --force && node build.js && cd ..

# 3. Fetch Dart dependencies
dart pub get

# 4. Copy bridge assets to web/
cp lib/assets/dart_monty_core_bridge.js   web/
cp lib/assets/dart_monty_core_worker.js   web/
cp lib/assets/dart_monty_core_native.wasm web/

# 5. Copy WASI runtime (NOT done by build.js — must be copied manually)
mkdir -p web/@pydantic/monty-wasm32-wasi
cp ../../js/node_modules/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs \
   web/@pydantic/monty-wasm32-wasi/

# 6a. Compile Dart to JS
dart compile js web/repl_demo.dart -o web/repl_demo.dart.js --no-minify

# 6b. Or compile Dart to WASM (dart2wasm)
dart compile wasm web/repl_demo.dart -o web/repl_demo.wasm

# 7. Serve with COOP/COEP headers (required for SharedArrayBuffer)
python3 - <<'EOF'
import http.server
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        self.send_header("Access-Control-Allow-Origin", "*")
        super().end_headers()
    def guess_type(self, path):
        if str(path).endswith(".mjs"): return "application/javascript"
        if str(path).endswith(".wasm"): return "application/wasm"
        return super().guess_type(path)
http.server.HTTPServer(("127.0.0.1", 8098), H).serve_forever()
EOF
```

Then visit:
- **dart2js**: http://localhost:8098/index_js.html
- **dart2wasm**: http://localhost:8098/index_wasm.html

---

## GitHub Pages

The public demo is deployed automatically on push to `main` via
`.github/workflows/deploy-pages.yml`.

**URL**: https://runyaga.github.io/dart_monty_core/repl/

Note: The dart2wasm variant (`index_wasm.html`) is available locally but will
not work on GitHub Pages — Pages cannot set COOP/COEP headers and browsers
block `SharedArrayBuffer` without them.

---

## Note on Flutter web

This package uses pure Dart web (not Flutter). Flutter consumers use
`dart_monty` + `dart_monty_core` and call `DartMonty.ensureInitialized()`
— no manual `<script>` tag, no `cp` step. See dart_monty_core's
top-level README for the full pattern.
