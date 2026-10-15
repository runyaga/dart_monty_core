#!/usr/bin/env bash
#
# prebuild.sh — rebuild dart_monty_core's web asset.
#
# Produces (under lib/assets/ so Flutter can resolve it via
# `packages/dart_monty_core/assets/...`):
#   lib/assets/dart_monty_core_worker.wasm (native/worker, O7 profile)
#
# lib/assets/dart_monty_core_worker.js is NOT built: it is the
# hand-written Web Worker that runs the worker wasm, edited in place.
#
# Both files are committed to git (Mode A asset distribution).
#
# The recipe is tool/build_worker_wasm.sh; it remaps build-machine paths
# through tool/rust_remap.sh.
#
# Regenerate the asset locally when native/worker/ source changes:
#
#   bash tool/prebuild.sh
#   git add lib/assets/ tool/wasm-provenance.json
#
# Requires: rustup with the wasm32-wasip1 target and the Dart SDK (its bundled
# binaryen `wasm-opt`).

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

case "${1:-}" in
  "") ;;
  *) echo "usage: bash tool/prebuild.sh" >&2; exit 2 ;;
esac

echo "[prebuild] Repo root: $ROOT"
echo "[prebuild] Ensuring wasm32-wasip1 target is installed..."
# In native/worker, so it lands on the toolchain native/rust-toolchain.toml
# selects.
(cd native/worker && rustup target add wasm32-wasip1)

bash tool/build_worker_wasm.sh

echo "[prebuild] Done. Assets in $ROOT/lib/assets/."
command ls -la lib/assets/

# Re-record the hash of the sources the wasm was built FROM, so
# tool/check_asset_freshness.sh can detect a stale asset later. Derived, not
# declared -- nobody has to remember to update it, which is the whole point.
bash "$(dirname "$0")/check_asset_freshness.sh" --update worker
