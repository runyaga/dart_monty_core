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
# Usage: bash tool/record_coverage_baseline.sh [--dry-run] [--run-id ID]
# Exit: 0 recorded or already current; 1 refused or failed.
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

DRY=0
RUN_ID=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --run-id) RUN_ID="${2:-}"; shift 2 ;;
    *) echo "usage: $0 [--dry-run] [--run-id ID]" >&2; exit 2 ;;
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

TMP="$(mktemp -d)"
trap '/bin/rm -rf "$TMP"' EXIT
gh run download "$RUN_ID" -R "$REPO" -n lcov-merged -D "$TMP" 2>/dev/null
if [ ! -s "$TMP/honest.info" ]; then
  echo "note: run $RUN_ID has no lcov-merged artifact (a docs-only merge skips"
  echo "      the coverage job). Nothing to record."
  exit 0
fi

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
if [ "$DRY" = "1" ]; then
  git checkout -- tool/coverage-baseline.json
  echo "dry run: not committed"
  exit 0
fi
git add tool/coverage-baseline.json &&
  git commit -q -m "chore(coverage): record baseline at ${HEAD_SHA:0:7}" \
    -- tool/coverage-baseline.json &&
  git push origin main || { echo "FAIL: commit or push refused"; exit 1; }
echo "recorded baseline at ${HEAD_SHA:0:7}"
