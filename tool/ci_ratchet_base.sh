#!/usr/bin/env bash
# =============================================================================
# The ref the coverage ratchet compares against, per CI event
# =============================================================================
# Prints one ref on stdout; ci.yaml's coverage-merge job assigns it to
# RATCHET_BASE_REF.
#
#   pull_request   origin/$GITHUB_BASE_REF (fetched, depth 1), as before.
#   anything else  the first parent of HEAD (push to main, workflow_dispatch),
#                  except for a baseline-recording commit (below): HEAD itself.
#
# WHY THE PUSH CASE IS NOT EMPTY. With no base ref, tool/coverage_ratchet.sh
# has no way to tell a deleted file from a vanished one: every baseline file
# absent from the tracefile is VANISHED. A merge that deletes lib files (the
# cutover deletes 38) then failed the post-merge run, the `lcov-merged`
# artifact was never uploaded, and tool/record_coverage_baseline.sh, which
# needs a successful push run of that commit, could not record. The first
# parent of a squash or merge commit is main as it was before the change, so
# comparing with it applies the same DELETED rule the PR passed with.
#
# THE RECORDING COMMIT IS THE ONE EXCEPTION. After a deleting merge M,
# tool/record_coverage_baseline.sh commits the new baseline R on top of it. At R
# the first parent M still carries the OLD baseline, which lists the deleted
# files, and `git diff M R -- lib/` holds no deletion, so they would read as
# VANISHED and R's own run would fail. A commit that changes
# tool/coverage-baseline.json is compared with itself (HEAD): its baseline is
# the freshly recorded one, and the tracefile must still not fall below it. This
# only widens the push case, where the baseline is only ever written by that
# recorder; a PR cannot reach it.
#
# A push whose HEAD has no parent in the checkout (a shallow clone, a root
# commit) FAILS instead of falling back to the empty ref: that fallback is the
# deadlock above, and a guard that degrades silently reports PASS for a check
# that did not run. The checkout must be fetched with depth >= 2.
#
# Usage:
#   RATCHET_BASE_REF="$(bash tool/ci_ratchet_base.sh)"   # reads GITHUB_EVENT_NAME,
#                                                        # GITHUB_BASE_REF
#   bash tool/ci_ratchet_base.sh --self-test              # the controls
# =============================================================================
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
RATCHET="$(cd "$(dirname "$0")" && pwd)/coverage_ratchet.sh"

resolve() {
  if [ "${GITHUB_EVENT_NAME:-}" = pull_request ] && [ -n "${GITHUB_BASE_REF:-}" ]; then
    # Not fatal: coverage_ratchet.sh refuses a ref that does not resolve.
    git fetch --no-tags --depth=1 origin "${GITHUB_BASE_REF}" >&2 2>/dev/null || true
    echo "origin/${GITHUB_BASE_REF}"
    return 0
  fi
  if ! git rev-parse --verify --quiet 'HEAD^1^{commit}' >/dev/null; then
    echo "FAIL: HEAD has no first parent in this checkout." >&2
    echo "  A push is compared with the commit before it, so the checkout" >&2
    echo "  needs fetch-depth >= 2. Refusing to run the ratchet with no base:" >&2
    echo "  every file the change deleted would read as VANISHED." >&2
    return 1
  fi
  if ! git diff --quiet 'HEAD^1' HEAD -- tool/coverage-baseline.json; then
    git rev-parse --verify 'HEAD^{commit}'
    return 0
  fi
  git rev-parse --verify 'HEAD^1^{commit}'
}

self_test() {
  local tmp rc=0
  tmp="$(mktemp -d)"; trap '/bin/rm -rf "$tmp"' RETURN
  tmp="$(cd "$tmp" && pwd -P)"
  local repo="$tmp/repo"
  mkdir -p "$repo/lib/src" "$repo/test" "$repo/tool" || return 1
  trace() {
    local spec f hf h n i
    for spec in "$@"; do
      f="${spec%%:*}"; hf="${spec#*:}"; h="${hf%/*}"; n="${hf#*/}"
      echo "SF:$repo/$f"
      i=1; while [ "$i" -le "$n" ]; do
        if [ "$i" -le "$h" ]; then echo "DA:$i,1"; else echo "DA:$i,0"; fi
        i=$((i + 1))
      done
      echo "end_of_record"
    done > "$tmp/trace.info"
  }
  git init -q -b main "$repo" && (
    cd "$repo" && git config user.email t@t && git config user.name t &&
    for f in a b c; do
      echo "// $f" > "lib/src/$f.dart"; echo "// t $f" > "test/${f}_test.dart"
    done &&
    trace lib/src/a.dart:4/4 lib/src/b.dart:2/4 lib/src/c.dart:1/4 &&
    bash "$RATCHET" "$tmp/trace.info" --update >/dev/null &&
    git add -A && git commit -qm base
  ) || return 1
  local base
  base="$(git -C "$repo" rev-parse HEAD)"
  # The state after a squash merge onto main: one commit on top of `base`.
  reset(){ git -C "$repo" checkout -q -f -B main "$base" && git -C "$repo" clean -qfd; }
  commit(){ git -C "$repo" add -A && git -C "$repo" commit -qm x; }
  # run <name> <want exit> <ref text the ratchet output must hold> <event> <base_ref>
  # The ratchet runs as the workflow does: the ref comes from this script.
  run() {
    local name="$1" want="$2" grep_for="$3" event="$4" bref="$5" ref out got=0
    ref="$(cd "$repo" && GITHUB_EVENT_NAME="$event" GITHUB_BASE_REF="$bref" bash "$SELF")" || ref=""
    out="$(cd "$repo" && RATCHET_BASE_REF="$ref" bash "$RATCHET" "$tmp/trace.info" 2>&1)" || got=1
    if [ "$got" != "$want" ]; then
      echo "SELF-TEST FAIL: $name (expected exit $want, got $got; ref='$ref')"; echo "$out"; rc=1
    elif [ -n "$grep_for" ] && ! printf '%s\n' "$out" | grep -qF -- "$grep_for"; then
      echo "SELF-TEST FAIL: $name (output lacks '$grep_for')"; echo "$out"; rc=1
    else echo "ok: $name"; fi
  }

  # The merge deletes a lib file and its test.
  reset; git -C "$repo" rm -q lib/src/a.dart test/a_test.dart; commit
  git -C "$repo" update-ref refs/remotes/origin/main "$base"
  trace lib/src/b.dart:2/4 lib/src/c.dart:1/4
  run "push: a deleted lib file and its test are DELETED" 0 "DELETED" push ""
  run "workflow_dispatch on the merge commit: the same" 0 "DELETED" workflow_dispatch ""
  run "pull_request: the same deletion, as before" 0 "DELETED" pull_request main
  # The pre-fix behaviour, kept as a control: no ref at all is VANISHED.
  local out got=0
  out="$(cd "$repo" && RATCHET_BASE_REF="" bash "$RATCHET" "$tmp/trace.info" 2>&1)" || got=1
  if [ "$got" = 1 ] && printf '%s\n' "$out" | grep -qF VANISHED; then
    echo "ok: no base ref at all: VANISHED (the deadlock this script removes)"
  else echo "SELF-TEST FAIL: empty base ref did not report VANISHED"; echo "$out"; rc=1; fi
  trace lib/src/b.dart:1/4 lib/src/c.dart:1/4
  run "push: a deletion does not excuse a FILE DECREASE" 1 "FILE DECREASE" push ""

  # The recording commit R after that deletion merge M: the baseline is
  # regenerated from the post-deletion tracefile, nothing else changes.
  reset; git -C "$repo" rm -q lib/src/a.dart test/a_test.dart; commit
  trace lib/src/b.dart:2/4 lib/src/c.dart:1/4
  (cd "$repo" && bash "$RATCHET" "$tmp/trace.info" --update >/dev/null) && commit
  run "push: the baseline-recording commit after a deletion merge passes" 0 "" push ""
  # It is not a way round the rule: a recording commit still cannot sit below
  # the baseline it records, and the merge before it keeps its DELETED proof.
  git -C "$repo" checkout -q -f HEAD^1
  run "push: the deleting merge itself, once more, is DELETED" 0 "DELETED" push ""

  # A push that keeps every file but drops one from the tracefile still fails.
  reset; echo '// b2' >> "$repo/lib/src/b.dart"; commit
  trace lib/src/a.dart:4/4 lib/src/b.dart:2/4
  run "push: a kept file missing from the tracefile fails" 1 "" push ""
  # A push that keeps all files and lowers the total still fails.
  reset; echo '// d' > "$repo/lib/src/d.dart"; commit
  trace lib/src/a.dart:4/4 lib/src/b.dart:2/4 lib/src/c.dart:1/4 lib/src/d.dart:0/8
  run "push: a new untested file lowers the total: TOTAL DECREASE" 1 "TOTAL DECREASE" push ""
  # PRs are not weakened: no GITHUB_BASE_REF on a pull_request event must
  # not silently become the first parent.
  local r got2=0
  r="$(cd "$repo" && GITHUB_EVENT_NAME=pull_request GITHUB_BASE_REF=main bash "$SELF")"
  [ "$r" = origin/main ] || { echo "SELF-TEST FAIL: PR ref is '$r', not origin/main"; rc=1; }
  # No parent in the checkout: refuse rather than return an empty ref.
  git clone -q --depth=1 "file://$repo" "$tmp/shallow" 2>/dev/null &&
    (cd "$tmp/shallow" && GITHUB_EVENT_NAME=push bash "$SELF" >/dev/null 2>&1) && got2=1
  if [ "$got2" = 0 ]; then echo "ok: a shallow push checkout is refused"
  else echo "SELF-TEST FAIL: a depth-1 push checkout was accepted"; rc=1; fi
  [ "$rc" = 0 ] && echo "PASS: ci_ratchet_base self-test"
  return "$rc"
}

if [ "${1:-}" = --self-test ]; then self_test; exit $?; fi
cd "$(git rev-parse --show-toplevel)" || exit 1
resolve
