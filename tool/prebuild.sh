#!/usr/bin/env bash
#
# prebuild.sh — rebuild dart_monty_core web assets.
#
# Produces:
#   assets/dart_monty_core_bridge.js    (IIFE main-thread bridge)
#   assets/dart_monty_core_worker.js    (ESM WASM worker)
#   assets/dart_monty_core_native.wasm  (Rust engine compiled to WASI)
#
# These files are committed to git (Mode A asset distribution). CI
# verifies they stay in sync with the Rust crate by re-running this
# script and asserting `git diff --exit-code assets/`.
#
# Regenerate assets locally when native/ or js/ source changes:
#
#   bash tool/prebuild.sh
#   git add assets/
#   git commit -m "chore: rebuild web assets"
#
# Requires: rustup with wasm32-wasip1 target, node 20+, npm.

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"

echo "[prebuild] Repo root: $ROOT"
echo "[prebuild] Ensuring wasm32-wasip1 target is installed..."
rustup target add wasm32-wasip1

echo "[prebuild] Building Rust WASM binary..."
cd native
cargo build --release --target wasm32-wasip1
cd "$ROOT"

echo "[prebuild] Installing JS bridge deps..."
cd js
npm install --force

echo "[prebuild] Bundling bridge + worker + copying WASM..."
node build.js
cd "$ROOT"

echo "[prebuild] Done. Assets in $ROOT/assets/."
ls -la assets/
