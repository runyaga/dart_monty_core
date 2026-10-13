#!/usr/bin/env bash
# =============================================================================
# WorkerChannel in Chrome, on dart2js and dart2wasm, against the COMMITTED
# lib/assets/dart_monty_core_proto_worker.{js,wasm}
# =============================================================================
# One `dart test` per compiler, not one run with `-c dart2js -c dart2wasm`:
# both compilers write their coverage to the SAME `<test>.chrome.json`, and
# dart2wasm writes an empty one (measured: 37 bytes, versus 110 KB from
# dart2js), so in a combined run the measurement survives or not depending on
# which compiler finishes last. Coverage is taken from dart2js alone.
#
# `vm-only` is excluded because those files do not COMPILE for the web, and a
# load failure fails the run whatever the tag filter.
#
# Only test/unit/worker/ is loaded. Loading the whole suite would compile every
# browser library into the coverage record, and a library whose tests were
# filtered out would be "measured" at whatever its imports happened to run --
# lib/src/wasm/wasm_bindings_js.dart among them, swinging the lib-wide figure
# by 8 points for a reason that has nothing to do with this suite.
#
# Each compiler's run has its own test-count floor: `dart test` exits 0 on a
# tag filter that matches nothing. 11 tests per compiler observed.
#
# Usage: bash tool/test_worker_web.sh [--coverage DIR]
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

FLOOR=10
COV=()
if [ "${1:-}" = "--coverage" ]; then
  [ -n "${2:-}" ] || { echo "FAIL: --coverage needs a directory"; exit 2; }
  COV=(--coverage="$2")
fi

LOG_DIR="$(mktemp -d)"
trap '/bin/rm -rf "$LOG_DIR"' EXIT
rc=0
for compiler in dart2js dart2wasm; do
  extra=()
  [ "$compiler" = dart2js ] && extra=("${COV[@]}")
  echo "=== worker (web, $compiler) ==="
  dart test test/unit/worker -p chrome -c "$compiler" \
    --tags=worker --exclude-tags=vm-only \
    ${extra[@]+"${extra[@]}"} 2>&1 | tee "$LOG_DIR/$compiler.log"
  status=${PIPESTATUS[0]}
  if [ "$status" -ne 0 ]; then
    echo "FAIL: worker (web, $compiler) exited $status"
    rc=1
    continue
  fi
  bash tool/assert_test_count.sh "$LOG_DIR/$compiler.log" "$FLOOR" \
    "worker (web, $compiler)" || rc=1
done
exit $rc
