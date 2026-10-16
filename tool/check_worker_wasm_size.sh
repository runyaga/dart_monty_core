#!/usr/bin/env bash
# =============================================================================
# The worker wasm stays inside its download budget
# =============================================================================
# lib/assets/dart_monty_core_worker.wasm (the O7 build: worker crate,
# profile mixd, SDK wasm-opt -Os) is what every browser page downloads. Its
# budget is 5.75 MB of gzip level 9 output. O7 measured 5.66 MB; the in-process
# engine it is to replace ships at 5.39 MB.
#
# The instrument is zlib's deflate at level 9 (Python's gzip module), the same
# one the 5.66 figure was measured with. Dart's GZipCodec is NOT used: its zlib
# compresses this file ~1.8% worse, enough to move a module across the line.
#
# Raising the budget is a deliberate decision, made in this file, not a side
# effect of a dependency or toolchain bump.
#
# Usage: bash tool/check_worker_wasm_size.sh
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

WASM=lib/assets/dart_monty_core_worker.wasm
BUDGET=5750000

if [ ! -s "$WASM" ]; then
  echo "FAIL: $WASM is missing or empty. Run: bash tool/prebuild.sh"
  exit 1
fi

GZ=$(python3 -I -c 'import gzip,sys;print(len(gzip.compress(open(sys.argv[1],"rb").read(),9)))' "$WASM") || {
  echo "FAIL: could not measure $WASM"
  exit 1
}
RAW=$(wc -c < "$WASM" | tr -d ' ')

# A floor as well: a truncated or placeholder module must not read as "small".
if [ "$GZ" -lt $((BUDGET / 2)) ]; then
  echo "FAIL: $WASM is $GZ bytes gzipped, implausibly small for the worker."
  exit 1
fi
if [ "$GZ" -gt "$BUDGET" ]; then
  echo "FAIL: $WASM is $GZ bytes gzip -9 ($RAW raw), over its $BUDGET budget."
  exit 1
fi
echo "OK: $WASM is $GZ bytes gzip -9 ($RAW raw), budget $BUDGET."

# The same module's linear-memory layout: the stack must come first, so an
# overflow traps instead of writing over the data (tool/check_worker_wasm_layout.py).
python3 -I test/tool/wasm_layout_test.py >/dev/null 2>&1 || { echo "FAIL: test/tool/wasm_layout_test.py"; exit 1; }
python3 -I tool/check_worker_wasm_layout.py "$WASM" || exit 1
