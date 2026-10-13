#!/usr/bin/env bash
# =============================================================================
# build_native_wasm.sh — the recipe for the in-process engine's assets:
#   lib/assets/dart_monty_core_native.wasm  (native/, wasm32-wasip1, release)
#   lib/assets/dart_monty_core_worker.js    (js/build.js)
#   lib/assets/dart_monty_core_bridge.js    (js/build.js)
# Run through tool/prebuild.sh, which also re-records provenance.
# =============================================================================
# Its own file because it is an INPUT to the assets: tool/check_asset_freshness
# .sh hashes it with native/ and js/, so a changed flag reads as a stale asset
# until the module is rebuilt with it.
#
# Usage: bash tool/build_native_wasm.sh
# =============================================================================
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
ROOT="$PWD"
source tool/rust_remap.sh

# --target-dir is explicit because js/build.js copies the module from
# native/target/wasm32-wasip1/release: an inherited CARGO_TARGET_DIR (or a
# configured one) would otherwise build elsewhere and leave an older module at
# the path build.js reads.
echo "[prebuild] Building Rust WASM binary..."
(cd native && env -u RUSTFLAGS \
  CARGO_ENCODED_RUSTFLAGS="$(remap_rustflags "$ROOT")" \
  cargo build --locked --release --target wasm32-wasip1 \
    --target-dir "$ROOT/native/target")

echo "[prebuild] Installing JS bridge deps..."
(cd js && npm install)

echo "[prebuild] Bundling bridge + worker + copying WASM..."
(cd js && node build.js)
