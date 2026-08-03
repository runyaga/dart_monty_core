# Monty Web REPL — web/ assets

This directory contains the Dart source and compiled HTML entry points for the
browser REPL demo. For full build and serve instructions, see
[`../README.md`](../README.md).

---

## Compilation

Run these commands from the **repo root** (not from this directory):

### dart2js

```bash
dart compile js \
  packages/dart_monty_web/web/repl_demo.dart \
  -o packages/dart_monty_web/web/repl_demo.dart.js \
  --no-minify
```

### dart2wasm

```bash
dart compile wasm \
  packages/dart_monty_web/web/repl_demo.dart \
  -o packages/dart_monty_web/web/repl_demo.wasm
```

---

## Serving

Use the `tool/serve_demo.sh` script from the repo root, or run the Python server
manually:

> **On COOP/COEP.** `serve_demo.sh` sends them, but that is a local-dev
> convenience — it is not how the deployed site gets isolated. Measured inside
> each page with no `Cross-Origin-*` response headers: `index_js.html` has
> `crossOriginIsolated === false` and no `SharedArrayBuffer` at all, and works
> anyway; `index_wasm.html` has `crossOriginIsolated === true` because
> **`coi-serviceworker.js` injects the headers client-side**.
>
> That service worker is therefore **load-bearing for the dart2wasm page** — do
> not remove it. It is the supported way to obtain isolation on hosts that cannot
> set response headers, such as GitHub Pages.

```bash
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

## Assets required before serving

```bash
# 1. Build JS bridge (outputs to repo root assets/)
cd js && npm install --force && node build.js && cd ..

# 2. Copy bridge assets into this directory
cp assets/dart_monty_core_bridge.js   packages/dart_monty_web/web/
cp assets/dart_monty_core_worker.js   packages/dart_monty_web/web/
cp assets/dart_monty_core_native.wasm packages/dart_monty_web/web/

# 3. Copy WASI runtime (node build.js does NOT copy this — manual step required)
mkdir -p packages/dart_monty_web/web/@pydantic/monty-wasm32-wasi
cp js/node_modules/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs \
   packages/dart_monty_web/web/@pydantic/monty-wasm32-wasi/
```

If the WASI runtime is missing, the dart2wasm demo will show
`TypeError: Cannot read properties of undefined (reading 'init')` in the console.
