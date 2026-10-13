#!/usr/bin/env bash
# =============================================================================
# build_worker_wasm.sh — the recipe for lib/assets/dart_monty_core_proto_worker
# .wasm (O7). Run through tool/prebuild.sh, which also re-records provenance.
# =============================================================================
# Its own file because it is an INPUT to the asset: tool/check_asset_freshness
# .sh hashes it with native/worker/, so a changed profile or wasm-opt flag set
# reads as a stale asset until the module is rebuilt with it.
#
# Usage: bash tool/build_worker_wasm.sh
# =============================================================================
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# The Dart SDK's bundled wasm-opt (binaryen), so the O7 asset is optimised by
# the same binaryen as the SDK CI pins. `dart` may be the SDK's own launcher
# (dart-sdk/bin/dart) or Flutter's wrapper (flutter/bin/dart, SDK in
# bin/cache/dart-sdk). DART_SDK overrides both.
sdk_wasm_opt() {
  local bin candidate
  if [ -n "${DART_SDK:-}" ]; then
    candidate="$DART_SDK/bin/utils/wasm-opt"
  else
    bin="$(dirname "$(python3 -c 'import os,shutil,sys; print(os.path.realpath(shutil.which("dart") or sys.exit("dart not on PATH")))')")"
    candidate="$bin/utils/wasm-opt"
    [ -x "$candidate" ] || candidate="$bin/cache/dart-sdk/bin/utils/wasm-opt"
  fi
  [ -x "$candidate" ] || { echo "FATAL: no wasm-opt at $candidate (set DART_SDK)" >&2; return 1; }
  printf '%s\n' "$candidate"
}

# O7: the worker crate's `mixd` profile with a 2 MiB shadow stack (set by
# native/worker/build.rs), then the SDK's wasm-opt -Os with the B4c/B4e
# feature set. -Os grows the gzip size a little over the plain cargo output;
# O7 accepts that for the recursion-depth margin it buys.
build_worker_wasm() {
  local wasm_opt raw out=lib/assets/dart_monty_core_proto_worker.wasm
  wasm_opt="$(sdk_wasm_opt)"
  echo "[prebuild] Building the proto worker wasm (native/worker, profile mixd)..."
  # Panic locations embed source paths. Remap the cargo home and the checkout
  # so the committed module carries neither the builder's home directory nor
  # where the repo was cloned; the bytes then depend less on the machine.
  # CARGO_ENCODED_RUSTFLAGS, not RUSTFLAGS: cargo splits RUSTFLAGS on spaces
  # (a home or checkout path with one breaks the flag), and an inherited
  # CARGO_ENCODED_RUSTFLAGS would silently override RUSTFLAGS. Arguments are
  # separated by 0x1f; this sets the whole value, so nothing is inherited.
  #
  # --target-dir is explicit so `raw` below is the module THIS build wrote: an
  # inherited CARGO_TARGET_DIR (or a configured one) would otherwise build
  # elsewhere and leave an older module at the path wasm-opt reads.
  local cargo_home="${CARGO_HOME:-$HOME/.cargo}" sep=$'\x1f'
  local target_dir="$PWD/native/worker/target"
  (cd native/worker && env -u RUSTFLAGS \
    CARGO_ENCODED_RUSTFLAGS="--remap-path-prefix=$cargo_home=/cargo$sep--remap-path-prefix=$PWD=/src" \
    cargo build --locked --profile mixd --lib --target wasm32-wasip1 \
      --target-dir "$target_dir")
  raw="$target_dir/wasm32-wasip1/mixd/dart_monty_worker.wasm"
  echo "[prebuild] $("$wasm_opt" --version)"
  "$wasm_opt" \
    --enable-bulk-memory --enable-bulk-memory-opt --enable-sign-ext \
    --enable-mutable-globals --enable-nontrapping-float-to-int \
    --enable-multivalue --enable-reference-types \
    --enable-call-indirect-overlong \
    -Os "$raw" -o "$out"
}

build_worker_wasm
