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
# Usage: bash tool/test_wasm_unit.sh [--dart2wasm] [-- <extra dart test args>]
#
#   --dart2wasm  Compile the Dart TEST CODE with dart2wasm instead of dart2js.
#
# Two different things are called "wasm" here, and conflating them hides bugs:
#
#   1. The ENGINE — the Rust crate built for wasm32-wasip1 and loaded by the JS
#      worker. Every test in this suite drives it, whichever compiler is used.
#      That is what makes them `wasm`-tagged.
#   2. The DART COMPILE TARGET — dart2js or dart2wasm. This flag picks that.
#
# Axis 2 matters on its own: dart2js has a single number type, so `4.0 is int`
# is true and integral doubles collapse to ints; dart2wasm has real doubles and
# does not. Code can therefore pass on one and fail on the other while driving
# an identical engine. Passing extra args after `--` does NOT work for this:
# they land after the positional file list and `dart test` reads them as paths.
# =============================================================================
set -euo pipefail

COMPILER=()
LABEL="dart2js"
if [ "${1:-}" = "--dart2wasm" ]; then
  COMPILER=(-c dart2wasm)
  LABEL="dart2wasm"
  shift
fi

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
  # --force bypasses EBADPLATFORM on arm64 hosts (the WASI package declares
  # cpu: wasm32). tool/test_wasm.sh and the CI test-wasm job already use --force.
  (cd "$PKG/js" && npm install --force --silent)
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
# The file list below is explicit rather than a glob, so that a deliberately
# excluded test stays excluded. The cost is that a NEW wasm_*_test.dart is
# silently never run — which is exactly what happened to the two 0.19 suites:
# they existed, were tagged `wasm`, and no CI job touched them. Guard the class.
echo "--- Checking every wasm_*_test.dart is listed ---"
UNLISTED=0
for f in test/integration/wasm_*_test.dart; do
  if ! grep -qF "$f" "$0"; then
    echo "  UNLISTED: $f"
    UNLISTED=1
  fi
done
if [ "$UNLISTED" = "1" ]; then
  echo "FAIL: the file(s) above are tagged wasm but are not in this script's list,"
  echo "      so nothing runs them. Add them below, or add an explicit exclusion"
  echo "      comment naming why they are skipped."
  exit 1
fi
echo "  all listed"

# Concurrency: half the cores, capped at 4, floor of 2. Override with
# WASM_TEST_CONCURRENCY.
#
# This was hardcoded to 2. On a GitHub runner (4 vCPU) the formula still yields
# 2, so CI behaviour is UNCHANGED and this is not a CI tuning knob -- that is
# deliberate, because a shared runner has no headroom to spend and raising it
# there would trade throughput for flakiness.
#
# The cap is 4 because the gain stops there. Measured 2026-09-14 in a 12-core
# container, dart2js variant: c=2 46s, c=4 31s, c=6 30s, c=8 28s. Everything
# past 4 buys seconds for a linear rise in concurrent Chrome instances. The
# dart2wasm variant barely moves at all (32s -> ~31s), so the honest saving on
# a full local gate is ~13s of 163s, not the ~30s the dart2js number alone
# suggests. Four runs at c=4 across both variants: +737 ~85, all green.
CORES=$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 2)
CONCURRENCY=$(( CORES / 2 ))
[ "$CONCURRENCY" -gt 4 ] && CONCURRENCY=4
[ "$CONCURRENCY" -lt 2 ] && CONCURRENCY=2
CONCURRENCY=${WASM_TEST_CONCURRENCY:-$CONCURRENCY}

echo ""
echo "--- Running dart test -p chrome ($LABEL) --tags=wasm ---"
echo "    ${CORES} cores detected -> --concurrency ${CONCURRENCY}"
dart test \
  -p chrome \
  "${COMPILER[@]}" \
  --run-skipped \
  --tags=wasm \
  --exclude-tags=pending-futures \
  --reporter expanded \
  --concurrency "$CONCURRENCY" \
  test/integration/wasm_dataclass_hydrate_test.dart \
  test/integration/wasm_datetime_oscall_test.dart \
  test/integration/wasm_feedrun_async_matrix_test.dart \
  test/integration/wasm_fixture_test.dart \
  test/integration/wasm_monty_async_inputs_test.dart \
  test/integration/wasm_monty_compile_run_test.dart \
  test/integration/wasm_monty_exec_externals_test.dart \
  test/integration/wasm_mount_dir_test.dart \
  test/integration/wasm_open_test.dart \
  test/integration/wasm_output_depth_test.dart \
  test/integration/wasm_oscall_decline_test.dart \
  test/integration/wasm_float_roundtrip_test.dart \
  test/integration/wasm_multi_repl_test.dart \
  test/integration/wasm_print_callback_test.dart \
  test/integration/wasm_repl_corpus_test.dart \
  test/integration/wasm_repl_extfns_lifecycle_test.dart \
  test/integration/wasm_repl_futures_test.dart \
  test/integration/wasm_repl_snapshot_lifecycle_test.dart \
  test/integration/wasm_run_async_matrix_test.dart \
  test/integration/wasm_setextfns_test.dart \
  test/integration/wasm_type_check_test.dart \
  test/integration/wasm_control_d_test.dart \
  test/integration/wasm_monty_019_semantics_test.dart \
  test/integration/wasm_ellipsis_test.dart \
  test/integration/wasm_repr_oracle_test.dart \
  test/integration/wasm_wire_format_test.dart \
  test/integration/wasm_wire_contract_test.dart \
  test/integration/wasm_inbound_forgery_test.dart \
  test/integration/wasm_envelope_decode_test.dart \
  test/integration/wasm_recursion_ceiling_test.dart \
  test/integration/wasm_mem_spike_repro.dart \
  test/integration/wasm_poison_boundary_test.dart \
  "$@"
