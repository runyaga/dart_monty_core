#!/usr/bin/env bash
# =============================================================================
# dart_monty_core — with__cm_* conformance on WASM (staged test-hooks build)
# =============================================================================
# WASM counterpart to tool/test_cm.sh. The `with__cm_*` fixtures need monty's
# synthetic `_test_cm()`, which only exists under the testing-only `test-hooks`
# cargo feature. This builds a STAGED test-hooks WASM binary into
# test/integration/web/ (never lib/assets, which must stay test-hooks-free),
# compiles the corpus runner with `-DMONTY_TEST_HOOKS=true` (so it stops
# skipping the test-hooks fixtures), and runs the corpus in headless Chrome.
#
# The committed JS bridge (lib/assets/*.js) is reused as-is — only the wasm
# engine needs the feature.
#
# Usage: bash tool/test_cm_wasm.sh
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
INTEG_WEB="$PKG/test/integration/web"
WASI_PKG="$PKG/js/node_modules/@pydantic/monty-wasm32-wasi"
SERVE_PORT=8096
cd "$PKG"

echo "=== with__cm_* conformance on WASM (test-hooks) ==="

# -------------------------------------------------------
# Step 1: Build a test-hooks WASM binary (staged, not lib/assets)
# -------------------------------------------------------
echo "--- Building test-hooks WASM (cargo wasm32-wasip1 --features test-hooks) ---"
(cd native && cargo build --target wasm32-wasip1 --release --features test-hooks)
WASM_SRC="$PKG/native/target/wasm32-wasip1/release/dart_monty_core_native.wasm"
[ -f "$WASM_SRC" ] || { echo "FATAL: missing $WASM_SRC"; exit 1; }

# -------------------------------------------------------
# Step 2: Stage assets into test/integration/web/
# -------------------------------------------------------
echo "--- Staging assets (test-hooks wasm + committed JS bridge) ---"
mkdir -p "$INTEG_WEB"
cp "$WASM_SRC"                                   "$INTEG_WEB/dart_monty_core_native.wasm"
cp "$PKG/lib/assets/dart_monty_core_bridge.js"   "$INTEG_WEB/"
cp "$PKG/lib/assets/dart_monty_core_worker.js"   "$INTEG_WEB/"

# WASI runtime (esbuild doesn't copy it; mirror tool/test_wasm.sh).
if [ ! -f "$WASI_PKG/wasi-worker-browser.mjs" ]; then
  echo "--- Installing WASI runtime (npm install --force in js/) ---"
  (cd js && npm install --force --silent)
fi
mkdir -p "$INTEG_WEB/@pydantic/monty-wasm32-wasi"
cp "$WASI_PKG/wasi-worker-browser.mjs" "$INTEG_WEB/@pydantic/monty-wasm32-wasi/"

# -------------------------------------------------------
# Step 3: Compile the corpus runner with MONTY_TEST_HOOKS=true
# -------------------------------------------------------
echo "--- Compiling wasm_runner.dart -> JS (-DMONTY_TEST_HOOKS=true) ---"
dart pub get >/dev/null
dart compile js \
  -DMONTY_TEST_HOOKS=true \
  test/integration/wasm_runner.dart \
  -o "$INTEG_WEB/wasm_runner.dart.js" \
  --no-source-maps
echo "  Compile: OK"

# -------------------------------------------------------
# Cleanup trap
# -------------------------------------------------------
SERVE_PID=""
cleanup() {
  if [ -n "$SERVE_PID" ]; then kill "$SERVE_PID" 2>/dev/null || true; fi
  rm -f "$INTEG_WEB/dart_monty_core_bridge.js" \
        "$INTEG_WEB/dart_monty_core_worker.js" \
        "$INTEG_WEB/dart_monty_core_native.wasm" \
        "$INTEG_WEB/wasm_runner.dart.js" \
        "$INTEG_WEB/wasm_runner.dart.js.deps"
}
trap cleanup EXIT

# -------------------------------------------------------
# Step 4: COOP/COEP server
# -------------------------------------------------------
echo "--- Starting COOP/COEP server on :$SERVE_PORT ---"
python3 - "$INTEG_WEB" "$SERVE_PORT" <<'PYEOF' &
import sys, http.server, functools
directory = sys.argv[1]; port = int(sys.argv[2])
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

# -------------------------------------------------------
# Step 5: Detect Chrome + run headless
# -------------------------------------------------------
CHROME=""
for c in "google-chrome-stable" "google-chrome" \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "chromium" "chromium-browser"; do
  if command -v "$c" &>/dev/null 2>&1 || [ -f "$c" ]; then CHROME="$c"; break; fi
done
[ -n "$CHROME" ] || { echo "WARN: Chrome not found; cannot run WASM tests."; exit 0; }

echo "--- Running corpus (test-hooks) in headless Chrome ---"
CHROME_LOG=$(mktemp)
timeout 120 "$CHROME" --headless=new --disable-gpu --no-sandbox \
  --disable-dev-shm-usage --enable-logging=stderr --v=0 \
  "http://127.0.0.1:$SERVE_PORT/fixtures.html" 2>"$CHROME_LOG" || true

# -------------------------------------------------------
# Step 6: Parse — require the with__cm fixtures to have run and passed
# -------------------------------------------------------
RESULTS=$(grep -o 'FIXTURE_RESULT:{.*}' "$CHROME_LOG" 2>/dev/null || true)
DONE=$(grep -o 'FIXTURE_DONE:{.*}' "$CHROME_LOG" 2>/dev/null | head -1 || true)
FAILURES=$(echo "$RESULTS" | grep -c '"ok":false' || true)
CM_RUN=$(echo "$RESULTS" | grep -c 'with__cm_' || true)
rm -f "$CHROME_LOG"

echo ""
echo "$DONE"
echo "with__cm fixtures executed: $CM_RUN (expected 6)"

if [ -z "$DONE" ]; then echo "FAILED: no FIXTURE_DONE (Chrome crashed/timed out)"; exit 1; fi
if [ "$FAILURES" -gt 0 ]; then
  echo "FAILED: $FAILURES fixture(s) failed:"
  echo "$RESULTS" | grep '"ok":false' | sed 's/^.*FIXTURE_RESULT:/  /'
  exit 1
fi
if [ "$CM_RUN" -lt 6 ]; then
  echo "FAILED: expected 6 with__cm fixtures to run, saw $CM_RUN"
  echo "  (is the runner compiled with -DMONTY_TEST_HOOKS=true?)"
  exit 1
fi

echo ""
echo "=== PASSED: with__cm_* conformance on WASM ==="
