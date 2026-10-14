#!/usr/bin/env bash
#
# prebuild.sh — rebuild dart_monty_core web assets.
#
# Produces (under lib/assets/ so Flutter can resolve them via
# `packages/dart_monty_core/assets/...`):
#   lib/assets/dart_monty_core_bridge.js         (IIFE main-thread bridge)
#   lib/assets/dart_monty_core_worker.js         (ESM WASM worker)
#   lib/assets/dart_monty_core_native.wasm       (Rust engine compiled to WASI)
#   lib/assets/dart_monty_core_worker.wasm (native/worker, O7 profile)
#
# lib/assets/dart_monty_core_worker.js is NOT built: it is the
# hand-written Web Worker that runs the proto worker wasm, edited in place.
#
# These files are committed to git (Mode A asset distribution).
#
# The recipes are tool/build_native_wasm.sh (in-process engine + JS glue) and
# tool/build_worker_wasm.sh (proto worker); both remap build-machine paths
# through tool/rust_remap.sh.
#
# Regenerate assets locally when native/, native/worker/ or js/ source changes:
#
#   bash tool/prebuild.sh                 # every asset
#   bash tool/prebuild.sh --worker-only   # only the proto worker wasm
#   git add lib/assets/ tool/wasm-provenance.json
#
# --worker-only exists because neither wasm build is byte-reproducible: a
# worker change should not rewrite the in-process engine's committed bytes.
#
# Requires: rustup with wasm32-wasip1 target, node 20+, npm, and the Dart SDK
# (its bundled binaryen `wasm-opt`).

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

SCOPE=worker
case "${1:-}" in
  ""|--worker-only) ;;
  *) echo "usage: bash tool/prebuild.sh" >&2; exit 2 ;;
esac

echo "[prebuild] Repo root: $ROOT"
echo "[prebuild] Ensuring wasm32-wasip1 target is installed..."
# In native/, so it lands on the toolchain native/rust-toolchain.toml selects.
(cd native/worker && rustup target add wasm32-wasip1)


bash tool/build_worker_wasm.sh

echo "[prebuild] Done. Assets in $ROOT/lib/assets/."
ls -la lib/assets/

# Re-record the hash of the sources these assets were built FROM, so
# tool/check_asset_freshness.sh can detect a stale asset later. Derived, not
# declared -- nobody has to remember to update it, which is the whole point.
bash "$(dirname "$0")/check_asset_freshness.sh" --update "$SCOPE"
