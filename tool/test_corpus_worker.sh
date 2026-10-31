#!/usr/bin/env bash
# =============================================================================
# The upstream 1.3.0 corpus and pool crash recovery on the worker.
# =============================================================================
# One leg per invocation, so each CI job and each local run names what it ran:
#
#   bash tool/test_corpus_worker.sh native
#   bash tool/test_corpus_worker.sh chrome dart2js
#   bash tool/test_corpus_worker.sh firefox dart2wasm
#
# `native` needs the worker executable (tool/build_worker.sh, or CI's artefact).
# The browser legs drive the COMMITTED lib/assets/dart_monty_core_worker
# .{js,wasm} and need the browser on PATH (Firefox: FIREFOX_EXECUTABLE is not
# read by `dart test`; put it on PATH).
#
# The verdict is test/corpus's: the failing set must equal the manifest in
# packages/monty_conformance, both ways. This script adds the floor under the
# test count (a run that registers nothing exits 0) and that the scorecard
# line was printed, so a leg cannot pass without having run the corpus.
#
# The floors are the counts the two legs register on the pinned 703-case
# corpus: 14 on the native leg and 23 on a browser leg. The corpus grew from
# 695 cases to 703 with the 1.3.0 pin; the number of registered tests did
# not, so the floors stay where the measurement put them.
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

leg="${1:-}"
compiler="${2:-}"
case "$leg" in
  native) args=(-p vm); floor=14; scorecard='CORPUS native: total=703' ;;
  chrome|firefox)
    case "$compiler" in
      dart2js|dart2wasm) ;;
      *) echo "usage: $0 native | {chrome|firefox} {dart2js|dart2wasm}" >&2; exit 2 ;;
    esac
    args=(-p "$leg" -c "$compiler"); floor=23; scorecard="CORPUS $compiler: total=703"
    ;;
  *) echo "usage: $0 native | {chrome|firefox} {dart2js|dart2wasm}" >&2; exit 2 ;;
esac

# package:test starts Firefox with a window; a runner with no display needs it
# headless, which Firefox reads from the environment.
[ "$leg" = firefox ] && export MOZ_HEADLESS=1

log="$(mktemp)"
trap '/bin/rm -f "$log"' EXIT
dart test test/corpus "${args[@]}" --tags=corpus-worker 2>&1 | tee "$log"
status=${PIPESTATUS[0]}
if [ "$status" -ne 0 ]; then
  echo "FAIL: corpus-worker ($leg ${compiler}) exited $status"
  exit 1
fi
grep -q "$scorecard" "$log" || {
  echo "FAIL: corpus-worker ($leg ${compiler}) printed no '$scorecard' scorecard line"
  exit 1
}
bash tool/assert_test_count.sh "$log" "$floor" "corpus-worker ($leg ${compiler})"
