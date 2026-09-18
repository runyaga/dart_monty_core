#!/usr/bin/env bash
# =============================================================================
# tool/run_example_smoke.sh — run the example programs AND count them
# =============================================================================
# Usage: bash tool/run_example_smoke.sh [LOGFILE]
#
# ONE BODY, TWO CALLERS, because they had drifted. CI ran the suite and then
# asserted a count (ci.yaml, `assert_test_count.sh … 14 example`); tool/gate.sh
# ran the same suite and asserted NOTHING:
#
#   gate.sh:274  s examples dart test test/integration/example_smoke_test.dart \
#                  -p vm --run-skipped --tags=example
#
# So `bash tool/gate.sh` printed `PASS examples` for a run of one test, or of
# zero. A suite that registers nothing prints success and exits 0 -- this repo
# has already paid for that shape once (8dbdd59, "646 of 1593 registered tests"
# asserting nothing), and the local gate is the thing a contributor is told to
# trust BEFORE pushing.
#
# The two callers also disagreed on the reporter: CI pinned --reporter=expanded,
# the gate took whatever `dart test` chose. Same body now, so they cannot.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

LOG="${1:-/tmp/example-test.log}"

# Derived, not hardcoded: see tool/example_floor.sh for why, and for the
# MAX_SKIPS lock that stops a new skip from lowering its own bar. Computed
# BEFORE the run so a tree-level fault (an example hidden in a subdirectory)
# reports as itself rather than as a count mismatch 12 seconds later.
if ! FLOOR=$(bash tool/example_floor.sh); then
  echo "FAIL: cannot determine the example floor -- see above." >&2
  exit 1
fi

set -o pipefail
dart test test/integration/example_smoke_test.dart \
  -p vm --run-skipped --tags=example \
  --reporter=expanded 2>&1 | tee "$LOG"
RC=$?

if [ "$RC" -ne 0 ]; then
  echo "FAIL: example smoke suite exited $RC." >&2
  exit "$RC"
fi

bash tool/assert_test_count.sh "$LOG" "$FLOOR" example
