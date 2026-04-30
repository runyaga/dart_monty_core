#!/usr/bin/env bash
# =============================================================================
# dart_monty_core — WASM fixture conformance test
# =============================================================================
# Builds the JS bridge from js/src/ (npm + esbuild), compiles wasm_runner.dart
# to JS, then serves everything with COOP/COEP headers and runs headless Chrome
# to exercise the fixture corpus tests.
#
# Prerequisites:
#   - node / npm (for building js/src/ → assets)
#   - cargo with wasm32-wasip1 target (for the WASM binary)
#   - dart
#   - Chrome / Chromium
#
# Usage: bash tool/test_wasm.sh [--skip-build]
#
#   --skip-build   Skip the npm + cargo build steps (use existing assets).
#                  Useful when you've already built and just want to re-run tests.
#
# Output protocol (parsed from Chrome stderr):
#   FIXTURE_RESULT:{"name":"<file>","ok":<bool>}
#   FIXTURE_DONE:{"total":<n>,"passed":<n>,"failed":<n>,"skipped":<n>}
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
JS_DIR="$PKG/js"
ASSETS_DIR="$PKG/lib/assets"
INTEG_WEB="$PKG/test/integration/web"
SERVE_PORT=8097
SKIP_BUILD=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

echo "=== dart_monty_core WASM fixture tests ==="
echo ""

# -------------------------------------------------------
# Step 1: Build WASM binary
# -------------------------------------------------------
if [ "$SKIP_BUILD" = false ]; then
  echo "--- Building WASM binary (cargo wasm32-wasip1) ---"
  cd "$PKG/native"
  cargo build --target wasm32-wasip1 --release
  mkdir -p "$ASSETS_DIR"
  cp target/wasm32-wasip1/release/dart_monty_core_native.wasm "$ASSETS_DIR/"
  echo "  WASM binary: OK ($(du -sh "$ASSETS_DIR/dart_monty_core_native.wasm" | cut -f1))"
else
  echo "--- Skipping WASM binary build (--skip-build) ---"
fi

if [ ! -f "$ASSETS_DIR/dart_monty_core_native.wasm" ]; then
  echo "ERROR: Missing WASM binary: $ASSETS_DIR/dart_monty_core_native.wasm"
  echo "  Run without --skip-build to build it."
  exit 1
fi

# -------------------------------------------------------
# Step 2: Build JS bridge (npm + esbuild)
# -------------------------------------------------------
if [ "$SKIP_BUILD" = false ]; then
  echo ""
  echo "--- Building JS bridge (npm) ---"
  if ! command -v npm &>/dev/null; then
    echo "ERROR: npm not found. Install Node.js to build the JS bridge."
    exit 1
  fi
  cd "$JS_DIR"
  # --force bypasses EBADPLATFORM on arm64/x64 hosts (the WASI package
  # @pydantic/monty-wasm32-wasi declares cpu: wasm32). The CI test-wasm
  # job already uses --force.
  npm install --force --silent
  # build.js copies the WASM binary from native/target/ into assets/ under the
  # deployed name (dart_monty_core_native.wasm) —
  # point it at our assets dir by running it from there
  node build.js
  echo "  JS bridge: OK"
else
  echo "--- Skipping JS bridge build (--skip-build) ---"
fi

for f in dart_monty_core_bridge.js dart_monty_core_worker.js; do
  if [ ! -f "$ASSETS_DIR/$f" ]; then
    echo "ERROR: Missing JS asset: $ASSETS_DIR/$f"
    echo "  Run without --skip-build to build the JS bridge."
    exit 1
  fi
done

# -------------------------------------------------------
# Step 3: Compile wasm_runner.dart → JS
# -------------------------------------------------------
echo ""
echo "--- dart pub get ---"
cd "$PKG"
dart pub get

echo ""
echo "--- Compiling wasm_runner.dart → JS ---"
mkdir -p "$INTEG_WEB"
dart compile js \
  test/integration/wasm_runner.dart \
  -o "$INTEG_WEB/wasm_runner.dart.js" \
  --no-source-maps
echo "  Compile: OK"

# -------------------------------------------------------
# Step 4: Copy assets into test/integration/web/
# -------------------------------------------------------
echo ""
echo "--- Copying assets to test web dir ---"
cp "$ASSETS_DIR/dart_monty_core_bridge.js"   "$INTEG_WEB/"
cp "$ASSETS_DIR/dart_monty_core_worker.js"   "$INTEG_WEB/"
cp "$ASSETS_DIR/dart_monty_core_native.wasm" "$INTEG_WEB/"
echo "  Assets: OK"

# -------------------------------------------------------
# Cleanup trap
# -------------------------------------------------------
SERVE_PID=""

cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  rm -f "$INTEG_WEB/dart_monty_core_bridge.js" \
        "$INTEG_WEB/dart_monty_core_worker.js" \
        "$INTEG_WEB/dart_monty_core_native.wasm" \
        "$INTEG_WEB/wasm_runner.dart.js" \
        "$INTEG_WEB/wasm_runner.dart.js.deps"
}
trap cleanup EXIT

# -------------------------------------------------------
# Step 5: Start COOP/COEP HTTP server
# -------------------------------------------------------
echo ""
echo "--- Starting COOP/COEP server on :$SERVE_PORT ---"

python3 - "$INTEG_WEB" "$SERVE_PORT" <<'PYEOF' &
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
echo "  Server PID=$SERVE_PID"

# -------------------------------------------------------
# Step 6: Detect Chrome
# -------------------------------------------------------
CHROME=""
for candidate in \
  "google-chrome-stable" \
  "google-chrome" \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "chromium" \
  "chromium-browser"; do
  if command -v "$candidate" &>/dev/null 2>&1 || [ -f "$candidate" ]; then
    CHROME="$candidate"
    break
  fi
done

if [ -z "$CHROME" ]; then
  echo ""
  echo "WARN: Chrome not found. Cannot run WASM integration tests."
  exit 0
fi
echo "  Chrome: $CHROME"

# -------------------------------------------------------
# Step 7: Run headless Chrome
# -------------------------------------------------------
echo ""
echo "--- Running WASM fixture tests ---"

CHROME_LOG=$(mktemp)

timeout 120 "$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --disable-dev-shm-usage \
  --enable-logging=stderr \
  --v=0 \
  "http://127.0.0.1:$SERVE_PORT/fixtures.html" \
  2>"$CHROME_LOG" || true

# -------------------------------------------------------
# Step 8: Parse results
# -------------------------------------------------------
FIXTURE_RESULTS=$(grep -o 'FIXTURE_RESULT:{.*}' "$CHROME_LOG" 2>/dev/null || true)
FIXTURE_DONE=$(grep -o 'FIXTURE_DONE:{.*}' "$CHROME_LOG" 2>/dev/null | head -1 || true)

FAILURES=0
if [ -n "$FIXTURE_RESULTS" ]; then
  FAILURES=$(echo "$FIXTURE_RESULTS" | grep -c '"ok":false' || true)
fi

if [ -n "$FIXTURE_RESULTS" ]; then
  TOTAL=$(echo "$FIXTURE_RESULTS" | wc -l | tr -d ' ')
  PASSED=$(echo "$FIXTURE_RESULTS" | grep -c '"ok":true' || true)
  echo "  Results: $PASSED/$TOTAL passed"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "  FAILURES:"
  echo "$FIXTURE_RESULTS" | grep '"ok":false' | while IFS= read -r line; do
    json="${line#*FIXTURE_RESULT:}"
    echo "    $json"
  done
fi

rm -f "$CHROME_LOG"

echo ""
if [ -z "$FIXTURE_DONE" ]; then
  echo "WARN: No FIXTURE_DONE line captured. Chrome may have crashed or timed out."
  exit 1
fi

echo "$FIXTURE_DONE"

if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "=== FAILED: $FAILURES fixture(s) failed ==="
  exit 1
fi

echo ""
echo "=== PASSED: all WASM fixture tests ==="
