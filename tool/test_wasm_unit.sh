#!/usr/bin/env bash
# =============================================================================
# dart_monty_core — WASM unit-style test runner
# =============================================================================
# Runs the package:test-style WASM tests under test/integration/wasm_*_test.dart
# (datetime_oscall, multi_repl, setextfns) via `dart test -p chrome`.
#
# These tests need window.DartMontyBridge available on the page. The
# package:test browser harness's default HTML template doesn't include the
# bridge; dart_test.yaml's `custom_html_template_path` points at
# test/integration/wasm_test_template.html which adds the <script> tag.
#
# Bridge assets must therefore be served from the same path as the test HTML.
# This script stages them into test/integration/ and removes them on exit.
# COOP/COEP headers are NOT required — the bridge does not use
# SharedArrayBuffer or Atomics, so the default dart-test browser server works.
#
# Usage: bash tool/test_wasm_unit.sh [-- <extra dart test args>]
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
INTEG="$PKG/test/integration"
ASSETS="$PKG/lib/assets"
WASI_PKG="$PKG/js/node_modules/@pydantic/monty-wasm32-wasi"

cd "$PKG"

echo "=== dart_monty_core WASM unit-style tests ==="

# -----------------------------------------------------------------------------
# Step 1: Ensure committed assets exist (Mode A — assets/ is the source of truth)
# -----------------------------------------------------------------------------
for f in dart_monty_core_bridge.js dart_monty_core_worker.js dart_monty_core_native.wasm; do
  if [ ! -f "$ASSETS/$f" ]; then
    echo "FATAL: missing $ASSETS/$f"
    echo "  Run: bash tool/prebuild.sh"
    exit 1
  fi
done

# -----------------------------------------------------------------------------
# Step 2: Ensure the WASI runtime is installed (npm dep, gitignored)
# -----------------------------------------------------------------------------
if [ ! -f "$WASI_PKG/wasi-worker-browser.mjs" ]; then
  echo "--- Installing WASI runtime (npm install in js/) ---"
  if ! command -v npm &>/dev/null; then
    echo "FATAL: npm not found. Install Node.js to fetch @pydantic/monty-wasm32-wasi."
    exit 1
  fi
  (cd "$PKG/js" && npm install --silent)
fi
if [ ! -f "$WASI_PKG/wasi-worker-browser.mjs" ]; then
  echo "FATAL: $WASI_PKG/wasi-worker-browser.mjs still missing after npm install"
  exit 1
fi

# -----------------------------------------------------------------------------
# Step 3: Stage assets into test/integration/ (gitignored; cleaned on exit)
# -----------------------------------------------------------------------------
STAGED=(
  "$INTEG/dart_monty_core_bridge.js"
  "$INTEG/dart_monty_core_worker.js"
  "$INTEG/dart_monty_core_native.wasm"
  "$INTEG/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs"
)
cleanup() {
  rm -f "${STAGED[@]}"
  rmdir "$INTEG/@pydantic/monty-wasm32-wasi" 2>/dev/null || true
  rmdir "$INTEG/@pydantic" 2>/dev/null || true
}
trap cleanup EXIT

cp "$ASSETS/dart_monty_core_bridge.js"   "$INTEG/"
cp "$ASSETS/dart_monty_core_worker.js"   "$INTEG/"
cp "$ASSETS/dart_monty_core_native.wasm" "$INTEG/"
mkdir -p "$INTEG/@pydantic/monty-wasm32-wasi"
cp "$WASI_PKG/wasi-worker-browser.mjs" "$INTEG/@pydantic/monty-wasm32-wasi/"

# -----------------------------------------------------------------------------
# Step 4: Run the WASM unit-style tests
# -----------------------------------------------------------------------------
echo ""
echo "--- Running dart test -p chrome --tags=wasm ---"
dart test \
  -p chrome \
  --run-skipped \
  --tags=wasm \
  --reporter expanded \
  --concurrency 2 \
  test/integration/wasm_datetime_oscall_test.dart \
  test/integration/wasm_fixture_test.dart \
  test/integration/wasm_multi_repl_test.dart \
  test/integration/wasm_setextfns_test.dart \
  "$@"
