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
# tag filter that matches nothing. 241 tests per compiler observed, 34 of
# them the dump and load oracle cases, 19 the host-object oracle cases and
# 36 the print-sink oracle cases.
#
# The coverage run loads one suite at a time (`-j 1`). Chrome's precise
# coverage is binary here: each `Profiler.takePreciseCoverage` reports a
# function that has run and resets it, and the runner takes one per suite, in
# the one tab every suite shares. Run concurrently, the other suites in this
# directory (no `worker` tests, so they finish in seconds) take theirs while
# worker_channel_web_test.dart is still running: worker_channel.dart's
# functions are reported then, under a suite whose record drops them, and the
# blocks they run afterwards are never reported. Measured: lines 122 and 124
# (the cancelled start, which runs late in the suite) were 0 in 3 of 10 CI
# runs and in 4 of 14 local runs under CPU load, with every test passing;
# with `-j 1`, 0 of 20 local runs under the same load.
#
# Usage: bash tool/test_worker_web.sh [--coverage DIR]
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

FLOOR=265
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
  [ "$compiler" = dart2js ] && [ "${#COV[@]}" -gt 0 ] && extra=(-j 1 "${COV[@]}")
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
