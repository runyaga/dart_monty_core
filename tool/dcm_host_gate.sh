#!/usr/bin/env bash
# =============================================================================
# DCM host gate — runs every DCM check OUTSIDE the container, on dcm 1.39.0
# =============================================================================
# WHY OUTSIDE. `tool/gate.sh` runs inside the `dmc-build` container, which has
# dcm 1.37.0. The host has 1.39.0, and 1.39.0 is the version this project
# standardises on. Rather than keep two dcm installs in step, the DCM checks
# move to the host entirely and gate.sh skips them when it detects a container.
#
# WHY AN ISOLATED WORKTREE, and not just `cd` to the repo. The container and the
# host cannot share one `.dart_tool/package_config.json`. Measured 2026-09-16:
# the container resolves dependencies to `/home/.pub-cache/...` and **57 of 59
# of those paths do not exist on the host**. Pointing host dcm at the live tree
# would analyse against a broken package config -- the exact failure that
# produced a bogus 4777-issue reading in the sibling repo, where a stale
# package_config silently made every measurement meaningless.
#
# And the damage would not be one-directional: a host `dart pub get` on the live
# tree rewrites that file to host paths, breaking the CONTAINER gate. gate.sh's
# own `dart pub get` (line ~103) is INSIDE the native-source-hash block, so it
# is conditional -- the container would stay broken until someone happened to
# change a .rs file. A throwaway worktree avoids the thrash in both directions.
#
# Usage:
#   bash tool/dcm_host_gate.sh            # run the checks
#   bash tool/dcm_host_gate.sh --update   # regenerate baselines, copy them back
# =============================================================================
set -uo pipefail

if [ -e /run/.containerenv ] || [ -e /.dockerenv ]; then
  echo "FAIL: this script must run on the HOST, not inside the container."
  echo "  The container has dcm 1.37.0 and resolves packages to /home/.pub-cache,"
  echo "  which does not exist on the host. Run it from macOS:"
  echo "    bash tool/dcm_host_gate.sh"
  exit 1
fi

# ONE NAME FOR ONE DECISION. Three scripts each honoured their own spelling --
# DCM_RATCHET_ALLOW_MISSING, METRICS_RATCHET_ALLOW_MISSING -- so "let me gate
# without a licence" needed a combination nobody printed, and setting just one
# left this gate RED on the other. Measured with a `dcm` shim reporting
# "Not activated." and every credential unset:
#
#   (nothing set)                      -> DCM HOST GATE RED
#   DCM_RATCHET_ALLOW_MISSING=1        -> DCM HOST GATE RED   (metrics still FAIL)
#   both specific names set            -> GREEN, all three "SKIP (checked nothing)"
#
# DCM_ALLOW_MISSING is the umbrella. The specific names still work on their own,
# for skipping exactly one check on purpose.
if [ "${DCM_ALLOW_MISSING:-0}" = "1" ]; then
  export DCM_RATCHET_ALLOW_MISSING=1
  export METRICS_RATCHET_ALLOW_MISSING=1
fi

REPO="$(git rev-parse --show-toplevel)"
cd "$REPO"
UPDATE=0
[ "${1:-}" = "--update" ] && UPDATE=1

WANT_DCM=1.39.0
if ! command -v dcm >/dev/null 2>&1; then
  echo "FAIL: dcm is not on the host PATH."
  echo "  brew trust --formula cqlabs/dcm/dcm && brew install cqlabs/dcm/dcm@$WANT_DCM"
  exit 1
fi
HAVE_DCM=$(dcm --version 2>&1 | tr -d '\r' | awk '{print $NF}')
if [ "$HAVE_DCM" != "$WANT_DCM" ]; then
  echo "FAIL: host dcm is $HAVE_DCM, this project standardises on $WANT_DCM."
  echo "  brew link --overwrite cqlabs/dcm/dcm@$WANT_DCM"
  exit 1
fi

# The worktree is DETACHED at HEAD, so it analyses exactly what is committed and
# cannot be dirtied by accident. It lives outside the repo so no gate step, and
# no `git status`, ever sees it.
WT="${DCM_HOST_WORKTREE:-${TMPDIR:-/tmp}/dcm-host-$(basename "$REPO")}"
cleanup() {
  [ "${DCM_HOST_KEEP:-0}" = "1" ] && return 0
  git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
  git -C "$REPO" worktree prune >/dev/null 2>&1
}
# PIPE IS IN THE LIST DELIBERATELY. Measured 2026-09-16: running this script
# piped into `head -20` left the worktree behind — head closed the pipe, the
# script took SIGPIPE, and a trap on EXIT/INT/TERM alone does not fire for it.
# Reading a gate's output through `head` or `tail` is the normal thing to do,
# so the cleanup has to survive it.
trap cleanup EXIT INT TERM PIPE

# A worktree left by an earlier crashed run would otherwise make `worktree add`
# fail; prune first so a stale registration cannot block this run.
git -C "$REPO" worktree remove --force "$WT" >/dev/null 2>&1
git -C "$REPO" worktree prune >/dev/null 2>&1
git worktree add --detach "$WT" HEAD >/dev/null 2>&1 || {
  echo "FAIL: could not create the analysis worktree at $WT"; exit 1; }

echo "worktree: $WT  (detached at $(git rev-parse --short HEAD))"
if ! (cd "$WT" && dart pub get >/dev/null 2>&1); then
  echo "FAIL: host \`dart pub get\` failed in the worktree."
  echo "  Without host-resolved dependencies every dcm result is meaningless."
  exit 1
fi

RC=0
run() {
  local label="$1"; shift
  echo "--- $label"
  if (cd "$WT" && "$@"); then echo "    PASS"; else
    local rc=$?
    if [ $rc -eq 77 ]; then echo "    SKIP (checked nothing)"; else echo "    FAIL"; RC=1; fi
  fi
}

if [ "$UPDATE" = "1" ]; then
  run "dcm analyze baseline"  bash tool/dcm_ratchet.sh --update
  run "dcm metrics baseline"  bash tool/metrics_ratchet.sh --update
  # `--update` forces a RELATIVE baseline path, so it writes inside the
  # worktree. Copy the results back, or the regeneration is thrown away with
  # the worktree and the next run reports the same mismatch for ever.
  for b in tool/dcm-baseline.json tool/metrics-baseline.json; do
    if [ -f "$WT/$b" ] && ! cmp -s "$WT/$b" "$REPO/$b"; then
      cp "$WT/$b" "$REPO/$b"; echo "    updated $b in the real repo"
    fi
  done
else
  run "dcm analyze ratchet"    bash tool/dcm_ratchet.sh
  run "dcm metrics ratchet"    bash tool/metrics_ratchet.sh
  run "dcm exclusions (--deep)" bash tool/check_dcm_exclusions.sh --deep
fi

[ $RC -eq 0 ] && echo "DCM HOST GATE GREEN" || echo "DCM HOST GATE RED"
exit $RC
