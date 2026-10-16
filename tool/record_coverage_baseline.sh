#!/usr/bin/env bash
# =============================================================================
# Record tool/coverage-baseline.json on main, from main's own CI coverage
# =============================================================================
# PRs no longer commit the coverage baseline (tool/coverage_ratchet.sh fails
# only on a DECREASE, against the base branch's copy). Something has to move the
# baseline up after a merge, or the floor never rises and coverage can slide back
# to an old number with every PR green. This is that step.
#
# It runs on a maintainer's machine, with that maintainer's own git/gh
# credentials, after a PR is merged and main's CI run for the merge commit has
# finished. It is deliberately NOT a CI job: main is a protected branch with
# required status checks, so a workflow token could not push to it without
# widening branch protection or putting a write token in CI.
#
# What it does:
#   1. requires a clean checkout of main at origin/main;
#   2. finds the successful push-CI run for that exact commit and downloads its
#      `lcov-merged` artifact (the same honest.info the PR ratchet measured);
#   3. runs `coverage_ratchet.sh honest.info --update` (no base ref, so it writes);
#   4. if the file changed, commits ONLY tool/coverage-baseline.json and pushes.
#
# The baseline is refreshed once per release, in the release PR: run with
# --no-commit on main, then carry the modified file into the release branch
# (the `changelog-assembly` label lets that PR touch it). Step 4 is then skipped.
#
# Usage: bash tool/record_coverage_baseline.sh [--dry-run] [--no-commit] [--run-id ID]
# Exit: 0 recorded or already current; 1 refused or failed.
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

DRY=0
NOCOMMIT=0
RUN_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --no-commit) NOCOMMIT=1; shift ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    *) echo "usage: $0 [--dry-run] [--no-commit] [--run-id ID]" >&2; exit 2 ;;
  esac
done

REPO="$(gh repo view --json nameWithOwner --jq .nameWithOwner)" || exit 1
git fetch --quiet origin main || { echo "FAIL: cannot fetch origin/main"; exit 1; }
[ "$(git branch --show-current)" = "main" ] ||
  { echo "FAIL: not on main"; exit 1; }
[ -z "$(git status --porcelain)" ] ||
  { echo "FAIL: working tree is not clean"; exit 1; }
HEAD_SHA="$(git rev-parse HEAD)"
[ "$HEAD_SHA" = "$(git rev-parse origin/main)" ] ||
  { echo "FAIL: main is not at origin/main (pull first)"; exit 1; }

if [ -z "$RUN_ID" ]; then
  RUN_ID="$(gh run list -R "$REPO" -w CI -b main -e push --json databaseId,headSha,conclusion \
    --jq "[.[] | select(.headSha==\"$HEAD_SHA\" and .conclusion==\"success\")][0].databaseId")"
fi
if [ -z "$RUN_ID" ] || [ "$RUN_ID" = "null" ]; then
  echo "FAIL: no successful push CI run for ${HEAD_SHA:0:7} yet. Wait for it."
  exit 1
fi
# Provenance, for a run found above and for one passed with --run-id alike: it
# must be the successful push-CI run of main at THIS commit, or the recorded
# floor could be stale or come from an unrelated branch.
META="$(gh run view "$RUN_ID" -R "$REPO" --json headSha,headBranch,event,conclusion,workflowName \
  --jq '[.headSha,.headBranch,.event,.conclusion,.workflowName]|join(" ")')" ||
  { echo "FAIL: cannot read run $RUN_ID"; exit 1; }
if [ "$META" != "$HEAD_SHA main push success CI" ]; then
  echo "FAIL: run $RUN_ID is '$META', not the successful push CI run of main at $HEAD_SHA"
  exit 1
fi

TMP="$(mktemp -d)"
trap '/bin/rm -rf "$TMP"' EXIT
if ! gh run download "$RUN_ID" -R "$REPO" -n lcov-merged -D "$TMP"; then
  # No artifact is fine ONLY when the coverage job legitimately did not run
  # (a docs-only merge). Anything else (expired artifact, auth, network) is a
  # failure, not a skip.
  CONC="$(gh run view "$RUN_ID" -R "$REPO" --json jobs \
    --jq '[.jobs[] | select(.name | startswith("Coverage (merged")) | .conclusion][0]')" || exit 1
  if [ "$CONC" = "skipped" ]; then
    echo "note: the coverage job was skipped in run $RUN_ID (docs-only merge)."
    echo "      Nothing to record."
    exit 0
  fi
  echo "FAIL: could not download lcov-merged from run $RUN_ID (coverage job: ${CONC:-absent})."
  echo "      Artifacts expire after one day; re-run CI on main, then retry."
  exit 1
fi
[ -s "$TMP/honest.info" ] || { echo "FAIL: artifact has no honest.info"; exit 1; }

# The artifact was written on a CI runner, so its SF: paths are the runner's
# absolute checkout. Re-root them onto this checkout; every measured file is
# under lib/.
sed "s#^SF:.*/lib/#SF:$PWD/lib/#" "$TMP/honest.info" > "$TMP/local.info" || exit 1
bash tool/coverage_ratchet.sh "$TMP/local.info" --update || exit 1
if git diff --quiet -- tool/coverage-baseline.json; then
  echo "baseline already current at ${HEAD_SHA:0:7}"
  exit 0
fi
git --no-pager diff --stat -- tool/coverage-baseline.json
if [ "$NOCOMMIT" = "1" ]; then
  echo "updated tool/coverage-baseline.json from ${HEAD_SHA:0:7}; not committed (--no-commit)"
  exit 0
fi
if [ "$DRY" = "1" ]; then
  git checkout -- tool/coverage-baseline.json
  echo "dry run: not committed"
  exit 0
fi
git add tool/coverage-baseline.json &&
  git commit -q -m "chore(coverage): record baseline at ${HEAD_SHA:0:7}" \
    -- tool/coverage-baseline.json || { echo "FAIL: commit failed"; exit 1; }
if ! git push origin main; then
  # Branch protection refused it (the pusher is not allowed to bypass required
  # checks). Leave main exactly as it was; the baseline stays where it is.
  git reset -q --hard "$HEAD_SHA"
  echo "FAIL: push to main refused; local main reset. Branch protection must"
  echo "      let the maintainer running this script push to main."
  exit 1
fi
echo "recorded baseline at ${HEAD_SHA:0:7}"
