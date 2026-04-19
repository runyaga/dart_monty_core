#!/usr/bin/env bash
# =============================================================================
# dart_monty_core — build and serve the REPL web demo locally
#
# Usage:
#   bash tool/serve_demo.sh [--skip-build] [--dart2wasm]
#
# Options:
#   --skip-build   Skip npm + cargo + dart compile steps (use existing assets).
#   --dart2wasm    Compile Dart → WASM (dart2wasm) in addition to dart2js.
#
# What it does:
#   1. Build the Rust WASM binary (cargo, wasm32-wasip1)
#   2. Build the JS bridge (npm + esbuild in js/)
#   3. Copy bridge assets → packages/dart_monty_web/web/
#   4. Compile repl_demo.dart → JS (and optionally WASM)
#   5. Start a COOP/COEP HTTP server
#   6. Open the demo in the default browser
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
WEB_PKG="$PKG/packages/dart_monty_web"
WEB_DIR="$WEB_PKG/web"
JS_DIR="$PKG/js"
ASSETS_DIR="$PKG/assets"
SERVE_PORT=8098
SKIP_BUILD=false
DART2WASM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true; shift ;;
    --dart2wasm)  DART2WASM=true;  shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

echo "=== dart_monty_core REPL demo ==="
echo ""

# ---------------------------------------------------------------------------
# Step 1: Build WASM binary
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = false ]; then
  echo "--- Building WASM binary (cargo wasm32-wasip1) ---"
  cd "$PKG/native"
  cargo build --target wasm32-wasip1 --release
  mkdir -p "$ASSETS_DIR"
  cp target/wasm32-wasip1/release/dart_monty_native.wasm "$ASSETS_DIR/dart_monty_core_native.wasm"
  echo "  WASM binary: OK ($(du -sh "$ASSETS_DIR/dart_monty_core_native.wasm" | cut -f1))"
else
  echo "--- Skipping WASM binary build (--skip-build) ---"
fi

if [ ! -f "$ASSETS_DIR/dart_monty_core_native.wasm" ]; then
  echo "ERROR: Missing WASM binary: $ASSETS_DIR/dart_monty_core_native.wasm"
  echo "  Run without --skip-build to build it."
  exit 1
fi

# ---------------------------------------------------------------------------
# Step 2: Build JS bridge (npm + esbuild)
# ---------------------------------------------------------------------------
if [ "$SKIP_BUILD" = false ]; then
  echo ""
  echo "--- Building JS bridge (npm) ---"
  if ! command -v npm &>/dev/null; then
    echo "ERROR: npm not found. Install Node.js to build the JS bridge."
    exit 1
  fi
  cd "$JS_DIR"
  npm install --silent
  node build.js
  echo "  JS bridge: OK"
else
  echo "--- Skipping JS bridge build (--skip-build) ---"
fi

for f in dart_monty_core_bridge.js dart_monty_core_worker.js dart_monty_core_native.wasm; do
  if [ ! -f "$ASSETS_DIR/$f" ]; then
    echo "ERROR: Missing bridge asset: $ASSETS_DIR/$f"
    echo "  Run without --skip-build to build the JS bridge."
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Step 3: Copy bridge assets into web/
# ---------------------------------------------------------------------------
echo ""
echo "--- Copying assets to $WEB_DIR ---"
mkdir -p "$WEB_DIR"
cp "$ASSETS_DIR/dart_monty_core_bridge.js"   "$WEB_DIR/"
cp "$ASSETS_DIR/dart_monty_core_worker.js"   "$WEB_DIR/"
cp "$ASSETS_DIR/dart_monty_core_native.wasm" "$WEB_DIR/"

# WASI runtime for the Worker (needed when running dart2wasm)
WASI_PKG="$JS_DIR/node_modules/@pydantic/monty-wasm32-wasi"
if [ -f "$WASI_PKG/wasi-worker-browser.mjs" ]; then
  mkdir -p "$WEB_DIR/@pydantic/monty-wasm32-wasi"
  cp "$WASI_PKG/wasi-worker-browser.mjs" "$WEB_DIR/@pydantic/monty-wasm32-wasi/"
fi
echo "  Assets: OK"

# ---------------------------------------------------------------------------
# Step 4: Compile repl_demo.dart → JS (dart2js)
# ---------------------------------------------------------------------------
echo ""
echo "--- dart pub get ---"
cd "$PKG"
dart pub get

if [ "$SKIP_BUILD" = false ]; then
  echo ""
  echo "--- Compiling repl_demo.dart → JS (dart2js) ---"
  dart compile js \
    "$WEB_PKG/web/repl_demo.dart" \
    -o "$WEB_DIR/repl_demo.dart.js" \
    --no-minify
  echo "  dart2js: OK"

  if [ "$DART2WASM" = true ]; then
    echo ""
    echo "--- Compiling repl_demo.dart → WASM (dart2wasm) ---"
    dart compile wasm \
      "$WEB_PKG/web/repl_demo.dart" \
      -o "$WEB_DIR/repl_demo.wasm"
    echo "  dart2wasm: OK"
  fi
else
  echo "--- Skipping dart compile (--skip-build) ---"
fi

# ---------------------------------------------------------------------------
# Cleanup trap — remove copied assets when server exits
# ---------------------------------------------------------------------------
SERVE_PID=""
cleanup() {
  [ -n "$SERVE_PID" ] && kill "$SERVE_PID" 2>/dev/null || true
  rm -f \
    "$WEB_DIR/dart_monty_core_bridge.js" \
    "$WEB_DIR/dart_monty_core_worker.js" \
    "$WEB_DIR/dart_monty_core_native.wasm" \
    "$WEB_DIR/repl_demo.dart.js" \
    "$WEB_DIR/repl_demo.dart.js.deps" \
    "$WEB_DIR/repl_demo.dart.js.map" \
    "$WEB_DIR/repl_demo.mjs" \
    "$WEB_DIR/repl_demo.support.js" \
    "$WEB_DIR/repl_demo.wasm" \
    "$WEB_DIR/repl_demo.wasm.map"
  rm -rf "$WEB_DIR/@pydantic"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Step 5: Start COOP/COEP HTTP server
# ---------------------------------------------------------------------------
echo ""
echo "--- Starting server on :$SERVE_PORT ---"

python3 - "$WEB_DIR" "$SERVE_PORT" <<'PYEOF' &
import sys, http.server, functools

directory = sys.argv[1]
port = int(sys.argv[2])

class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()
    def guess_type(self, path):
        if path.endswith('.mjs'):  return 'application/javascript'
        if path.endswith('.wasm'): return 'application/wasm'
        return super().guess_type(path)
    def log_message(self, fmt, *args): pass

handler = functools.partial(H, directory=directory)
http.server.HTTPServer(('127.0.0.1', port), handler).serve_forever()
PYEOF

SERVE_PID=$!
sleep 1
echo "  Server: http://127.0.0.1:$SERVE_PORT"

# ---------------------------------------------------------------------------
# Step 6: Open browser
# ---------------------------------------------------------------------------
URL="http://127.0.0.1:$SERVE_PORT/index_js.html"
echo "  Opening: $URL"
echo ""
echo "Press Ctrl-C to stop the server."
echo ""

if command -v open &>/dev/null; then
  open "$URL"
elif command -v xdg-open &>/dev/null; then
  xdg-open "$URL"
fi

# Wait for server
wait "$SERVE_PID"
