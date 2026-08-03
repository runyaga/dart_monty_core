#!/usr/bin/env bash
# =============================================================================
# dart_monty_core — WASM fixture conformance test
# =============================================================================
# Builds the JS bridge from js/src/ (npm + esbuild), compiles the corpus runner
# for a web target, then serves everything with COOP/COEP headers and runs
# headless Chrome to exercise the fixture corpus tests.
#
# TWO DART TARGETS, ONE WASM ENGINE. Everything here drives the same Rust
# engine (lib/assets/dart_monty_core_native.wasm). What --dart2wasm changes is
# the compiler used for the DART side of the harness:
#
#   default      dart compile js   test/integration/wasm_runner.dart
#   --dart2wasm  dart compile wasm test/integration/wasm_runner_wasm.dart
#
# They are not interchangeable. dart2js has a single number type, so `4.0 is
# int` is true and integral doubles collapse to ints, while dart2wasm has real
# doubles — a corpus fixture can pass on one and fail on the other. CI has run
# both since ci.yaml:583/:669; the gate only ever ran the dart2js half, so a
# dart2wasm-only corpus regression reached CI unchallenged.
#
# Prerequisites:
#   - node / npm (for building js/src/ → assets)
#   - cargo with wasm32-wasip1 target (for the WASM binary)
#   - dart
#   - Chrome / Chromium
#
# Usage: bash tool/test_wasm.sh [--skip-build] [--dart2wasm]
#
#   --skip-build   Skip the npm + cargo build steps (use existing assets).
#                  Useful when you've already built and just want to re-run tests.
#   --dart2wasm    Compile the runner with dart2wasm instead of dart2js.
#                  Mirrors the flag tool/test_wasm_unit.sh already takes.
#
# --dart2wasm STAGES INTO A TEMP DIR, and that is load-bearing rather than
# tidiness. `dart compile wasm -o test/integration/web/wasm_runner.wasm` — what
# CI runs, and what the file's own header tells you to run — writes three
# TRACKED files: wasm_runner.wasm, wasm_runner.mjs and wasm_runner.wasm.map.
# The gate is read-only, and dart2wasm output is no more byte-reproducible than
# the Rust wasm, so compiling in place would leave the tree dirty after every
# gate run with a diff that means nothing. Serving a temp dir keeps the gate's
# "never writes to the working tree" guarantee literally true.
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
SKIP_BUILD=false
DART2WASM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=true; shift ;;
    --dart2wasm)  DART2WASM=true;  shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

# Distinct base ports so a dart2js and a dart2wasm run can overlap without one
# silently serving the other's staging dir. The port is then probed, because a
# hardcoded one is not actually available: 8098 was already held by an unrelated
# process on the first machine this ran on, the backgrounded server died on
# EADDRINUSE, and -- since `set -e` does not see a background failure -- the run
# went on to spend the whole Chrome timeout loading nothing and blamed Chrome.
if [ "$DART2WASM" = true ]; then
  PORT_BASE=8098
  TARGET="dart2wasm"
else
  PORT_BASE=8097
  TARGET="dart2js"
fi

SERVE_PORT=""
for offset in 0 10 20 30 40 50 60 70 80 90; do
  candidate=$((PORT_BASE + offset))
  if python3 -c "
import socket, sys
s = socket.socket()
try:
    s.bind(('127.0.0.1', $candidate))
except OSError:
    sys.exit(1)
finally:
    s.close()
" 2>/dev/null; then
    SERVE_PORT="$candidate"
    break
  fi
  echo "  port $candidate busy, trying next"
done
if [ -z "$SERVE_PORT" ]; then
  echo "ERROR: no free port near $PORT_BASE" >&2
  exit 1
fi

echo "=== dart_monty_core WASM fixture tests ($TARGET) ==="
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
# Step 3: Choose the serve dir, then compile the runner into it
# -------------------------------------------------------
echo ""
echo "--- dart pub get ---"
cd "$PKG"
dart pub get

STAGE=""
if [ "$DART2WASM" = true ]; then
  # Compile OUTSIDE the repo. See the header: -o into test/integration/web/
  # would overwrite three tracked files.
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dmc-wasm-corpus.XXXXXX")"
  SERVE_DIR="$STAGE"
  ENTRY="wasm_runner_wasm.html"
  cp "$INTEG_WEB/$ENTRY" "$STAGE/"
else
  SERVE_DIR="$INTEG_WEB"
  ENTRY="fixtures.html"
  mkdir -p "$INTEG_WEB"
fi

# -------------------------------------------------------
# Cleanup trap — installed BEFORE the first write so an aborted compile cannot
# strand staged assets in test/integration/web/.
# -------------------------------------------------------
SERVE_PID=""

cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  # The temp dir holds every dart2wasm artefact; nothing to prune in the repo.
  if [ -n "$STAGE" ]; then
    rm -rf "$STAGE"
    return
  fi
  rm -f "$INTEG_WEB/dart_monty_core_bridge.js" \
        "$INTEG_WEB/dart_monty_core_worker.js" \
        "$INTEG_WEB/dart_monty_core_native.wasm" \
        "$INTEG_WEB/wasm_runner.dart.js" \
        "$INTEG_WEB/wasm_runner.dart.js.deps"
}
trap cleanup EXIT

if [ "$DART2WASM" = true ]; then
  echo ""
  echo "--- Compiling wasm_runner_wasm.dart → WASM (dart2wasm) ---"
  dart compile wasm \
    test/integration/wasm_runner_wasm.dart \
    -o "$STAGE/wasm_runner.wasm"
else
  echo ""
  echo "--- Compiling wasm_runner.dart → JS (dart2js) ---"
  dart compile js \
    test/integration/wasm_runner.dart \
    -o "$INTEG_WEB/wasm_runner.dart.js" \
    --no-source-maps
fi
echo "  Compile: OK"

# -------------------------------------------------------
# Step 4: Copy bridge assets next to the runner
# -------------------------------------------------------
echo ""
echo "--- Copying assets to serve dir ($SERVE_DIR) ---"
cp "$ASSETS_DIR/dart_monty_core_bridge.js"   "$SERVE_DIR/"
cp "$ASSETS_DIR/dart_monty_core_worker.js"   "$SERVE_DIR/"
cp "$ASSETS_DIR/dart_monty_core_native.wasm" "$SERVE_DIR/"
echo "  Assets: OK"

# -------------------------------------------------------
# Step 5: Start COOP/COEP HTTP server
# -------------------------------------------------------
echo ""
echo "--- Starting COOP/COEP server on :$SERVE_PORT ---"

python3 - "$SERVE_DIR" "$SERVE_PORT" <<'PYEOF' &
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

# Confirm the server is actually serving the entry point before handing the URL
# to Chrome. Without this a bind failure is invisible for the whole Chrome
# timeout and then reported as "Chrome may have crashed", which sends you
# debugging the browser instead of the port.
READY=false
for _ in $(seq 1 20); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$SERVE_PORT/$ENTRY" 2>/dev/null; then
    READY=true
    break
  fi
  sleep 0.5
done
if [ "$READY" != true ]; then
  echo "ERROR: server on :$SERVE_PORT never served /$ENTRY" >&2
  exit 1
fi
echo "  Server PID=$SERVE_PID on :$SERVE_PORT (serving $ENTRY)"

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
echo "--- Running WASM fixture tests ($TARGET, $ENTRY) ---"

CHROME_LOG=$(mktemp)

# Poll the log for FIXTURE_DONE rather than waiting on Chrome. Headless Chrome
# does NOT exit when the page finishes, so the previous `timeout 120` burned the
# full two minutes on every run, pass or fail — most of this step's 123s in the
# gate was a browser sitting idle after the corpus had already finished. CI has
# used this poll since ci.yaml's run_test(); the ceiling below is the real
# timeout, and a run that never prints FIXTURE_DONE still fails at step 8.
CHROME_TIMEOUT=240
"$CHROME" \
  --headless=new \
  --disable-gpu \
  --no-sandbox \
  --disable-dev-shm-usage \
  --enable-logging=stderr \
  --v=0 \
  "http://127.0.0.1:$SERVE_PORT/$ENTRY" \
  2>"$CHROME_LOG" &
CHROME_PID=$!

ELAPSED=0
while [ "$ELAPSED" -lt "$CHROME_TIMEOUT" ]; do
  if grep -q 'FIXTURE_DONE:' "$CHROME_LOG" 2>/dev/null; then break; fi
  # Chrome dying early is a result too — stop waiting for a log line that can
  # no longer arrive.
  if ! kill -0 "$CHROME_PID" 2>/dev/null; then break; fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done
kill "$CHROME_PID" 2>/dev/null || true
wait "$CHROME_PID" 2>/dev/null || true
echo "  Chrome run: ${ELAPSED}s"

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

# "0 failed" is not the same as "the corpus ran". A runner that registered
# nothing prints FIXTURE_DONE:{"total":0,...} and every check above is happy —
# the same shape as trap 6 in the testing runbook, and as the gap this flag was
# added to close. Pin the total to the provenance file, which is regenerated
# with the corpus and already verified by tool/check_fixture_corpus.sh.
EXPECTED_TOTAL=$(python3 -c \
  "import json;print(json.load(open('tool/fixture-corpus.json'))['fixture_count'])")
ACTUAL_TOTAL=$(echo "$FIXTURE_DONE" | sed -n 's/.*"total":\([0-9]*\).*/\1/p')
if [ "$ACTUAL_TOTAL" != "$EXPECTED_TOTAL" ]; then
  echo ""
  echo "=== FAILED: corpus size mismatch ==="
  echo "  tool/fixture-corpus.json says $EXPECTED_TOTAL fixtures; the $TARGET run"
  echo "  reported $ACTUAL_TOTAL. Either the corpus was regenerated without"
  echo "  updating the provenance file, or the runner registered nothing."
  exit 1
fi

if [ "$FAILURES" -gt 0 ]; then
  echo ""
  echo "=== FAILED: $FAILURES fixture(s) failed ==="
  exit 1
fi

echo ""
echo "=== PASSED: all WASM fixture tests ($TARGET) ==="
