#!/usr/bin/env bash
# =============================================================================
# E4 watchdog — turn "does not terminate" into an observation
# =============================================================================
# A liveness question cannot be asked from inside the thing whose liveness is
# in doubt. core#156 is a loop calling an external function with no suspension
# budget: an in-suite probe hangs the suite, and a hung suite reports nothing
# except a CI timeout hours later, attributed to whatever ran last.
#
# So the probe runs as its own process and this script holds the clock. Three
# outcomes, and the third is the one that needs a watchdog to exist at all:
#
#   SELF-TERMINATED  the probe finished on its own -- a limit fired, or it hit
#                    its own ceiling. Read the line to tell which.
#   THREW            the probe raised. Also self-terminated; recorded apart
#                    because the exception type is the interesting part.
#   KILLED           the watchdog fired. The run did not terminate inside the
#                    budget. THIS IS THE FINDING, not a test infrastructure
#                    failure.
#
# Usage: bash tool/control/watchdog.sh [wall_seconds] [engine_timeout_ms]
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

WALL="${1:-15}"
ENGINE_MS="${2:-500}"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

echo "watchdog: wall ${WALL}s, engine timeoutMs ${ENGINE_MS}"

# WARM THE BUILD HOOKS OUTSIDE THE CLOCK. `dart run` compiles the Rust native
# asset on a cold tree, which took the ENTIRE watchdog budget on the first
# attempt: the run reported KILLED with calls=0, which reads as "hung
# instantly" when in fact the probe had not started. The watchdog must time the
# PROBE, not the toolchain.
echo "  warming build hooks (untimed)..."
dart run tool/control/liveness_probe.dart 1 >/dev/null 2>&1 || true

# `timeout` is not on macOS by default, so the clock is held here rather than
# depending on coreutils being installed.
dart run tool/control/liveness_probe.dart "$ENGINE_MS" > "$OUT" 2>&1 &
PROBE=$!
( sleep "$WALL"; kill -9 "$PROBE" 2>/dev/null ) &
TIMER=$!
wait "$PROBE" 2>/dev/null
RC=$?
kill -9 "$TIMER" 2>/dev/null
wait "$TIMER" 2>/dev/null

LAST_PROGRESS="$(grep '^PROGRESS:' "$OUT" | tail -1)"
DONE="$(grep '^DONE:' "$OUT" | tail -1)"

if [ -n "$DONE" ]; then
  KIND="$(echo "$DONE" | cut -d: -f2)"
  CALLS="$(echo "$DONE" | cut -d: -f3)"
  MS="$(echo "$DONE" | cut -d: -f4)"
  DETAIL="$(echo "$DONE" | cut -d: -f5-)"
  echo "E4DART:{\"outcome\":\"$KIND\",\"calls\":$CALLS,\"ms\":$MS,\"detail\":\"$(echo "$DETAIL" | tr -d '"' | cut -c1-90)\"}"
  exit 0
fi

# No DONE line: the process was killed mid-flight, which is the observation.
CALLS="$(echo "${LAST_PROGRESS:-PROGRESS:0:0}" | cut -d: -f2)"
MS="$(echo "${LAST_PROGRESS:-PROGRESS:0:0}" | cut -d: -f3)"
echo "E4DART:{\"outcome\":\"KILLED\",\"calls\":${CALLS:-0},\"ms\":${MS:-0},\"detail\":\"watchdog fired after ${WALL}s; rc=$RC\"}"
