#!/usr/bin/env bash
# =============================================================================
# dart_monty_core — every breaking change to the consumer surface is announced
# =============================================================================
# Checks tool/breaking-ledger.tsv against git and against CHANGELOG.md, in BOTH
# directions:
#
#   1. Every `!` commit touching lib/ has a ledger row.        (nothing omitted)
#   2. Every ledger row's anchor appears in CHANGELOG.md.      (nothing stale)
#      Whitespace-insensitive, so rewrapping prose cannot break a check.
#   3. Every ledger row names a real `!` commit touching lib/. (no dead rows)
#
# WHY THIS EXISTS. `43366ba fix(limits)!: session-scoped resource limits` shipped
# with no CHANGELOG entry and no ledger row, including the part where web went
# from silently ignoring `limits:` to throwing UnsupportedError. The prose
# cross-check that should have caught it — "19 rows, 19 in the CHANGELOG" — had
# been performed, and went stale within a day. A human ticking a column is not a
# check.
#
# SCOPE, stated so green here is not mistaken for more than it is:
#
#   - Only commits touching `lib/` are in scope. That is the Dart API consumers
#     write code against. Breaking changes to native/, hook/, js/, tooling and
#     fixtures are covered collectively by the release preamble, not row by row.
#     Widening this is a deliberate decision, not a bug fix.
#   - It verifies a change was MENTIONED, never that what was written is TRUE.
#     The CHANGELOG announced core#136 as fixed for three tiers while the escape
#     was live, and no grep would have caught that.
#
# Usage: bash tool/check_breaking_recorded.sh [base-ref]
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

CHANGELOG="$PKG/CHANGELOG.md"
LEDGER="$PKG/tool/breaking-ledger.tsv"

[ -f "$LEDGER" ] || { echo "FATAL: missing $LEDGER" >&2; exit 2; }

# Anchors are prose, and prose gets rewrapped. Compare against a
# whitespace-flattened CHANGELOG so a line break cannot break a check.
FLAT="$(mktemp)"
trap 'rm -f "$FLAT"' EXIT
tr '\n' ' ' < "$CHANGELOG" | tr -s ' ' > "$FLAT"

BASE="${1:-}"
if [ -z "$BASE" ]; then
  BASE="$(git merge-base HEAD origin/main 2>/dev/null \
       || git merge-base HEAD main 2>/dev/null || true)"
fi
[ -n "$BASE" ] || { echo "FATAL: cannot determine a base ref; pass one" >&2; exit 2; }

echo "--- breaking changes to lib/ since $(git rev-parse --short "$BASE") ---"

FAILED=0
SEEN_OIDS=""

# `fix(x)!: …` / `feat!: …` — the conventional-commit breaking marker.
breaking_lib_commits() {
  git log --format='%h' "$BASE"..HEAD | while read -r sha; do
    subject="$(git log -1 --format='%s' "$sha")"
    [[ "$subject" =~ ^[a-z]+(\([^\)]*\))?!: ]] || continue
    git show --stat --format='' "$sha" | grep -q '^ lib/' || continue
    echo "$sha"
  done
}

IN_SCOPE="$(breaking_lib_commits)"

# --- 1. nothing omitted ------------------------------------------------------
for sha in $IN_SCOPE; do
  if grep -qE "^${sha}[[:space:]]" "$LEDGER"; then
    continue
  fi
  echo "  FAIL  $sha  $(git log -1 --format='%s' "$sha")"
  echo "        touches lib/ and is marked breaking, but has no row in"
  echo "        tool/breaking-ledger.tsv. Add the row and the CHANGELOG entry,"
  echo "        or drop the '!' if the change is not breaking."
  FAILED=$((FAILED + 1))
done

# --- 2 & 3. nothing stale, no dead rows -------------------------------------
while IFS=$'\t' read -r sha anchor; do
  case "$sha" in ''|\#*) continue ;; esac
  [ -n "${anchor:-}" ] || {
    echo "  FAIL  $sha  row has no anchor phrase"
    FAILED=$((FAILED + 1))
    continue
  }

  flat_anchor="$(echo "$anchor" | tr -s ' ')"
  if ! grep -qF -- "$flat_anchor" "$FLAT"; then
    echo "  FAIL  $sha  anchor missing from CHANGELOG.md:"
    echo "        \"$anchor\""
    FAILED=$((FAILED + 1))
    continue
  fi

  # VALIDATED AGAINST HISTORY, NOT AGAINST THE RANGE.
  #
  # This used to require the row's sha to appear in $IN_SCOPE -- the breaking
  # commits between the merge-base and HEAD. The ledger is CUMULATIVE: it holds
  # a row for every breaking change ever shipped. So a row stayed valid only
  # while its commit happened to sit in the current diff, and went "dead" the
  # moment it merged.
  #
  # Measured 2026-09-19: on `main`, merge-base(HEAD, origin/main) IS HEAD, so
  # the range is EMPTY and ALL 24 rows failed -- main's own CI was red on this
  # check. On PR #169 the range held six non-breaking commits, so all 24 failed
  # there too. The check could only pass on a branch that still had every
  # historical breaking commit in front of it, which is true exactly once.
  #
  # What direction 3 is actually for, per this file's own header, is "no dead
  # rows": the sha must name a REAL breaking commit that touched lib/. That is
  # a question about history, and it is asked here. Both jobs that run this
  # check use fetch-depth: 0, so history is present.
  # An identifier, not an arbitrary revision expression. `git rev-parse` would
  # happily resolve `main`, a tag, or `HEAD~3` here and call the row valid.
  case "$sha" in
    *[!0-9a-fA-F]*)
      echo "  FAIL  $sha  ledger identifier is not a hex commit id."
      FAILED=$((FAILED + 1))
      continue
      ;;
  esac

  if ! row_oid="$(git rev-parse --verify --quiet "${sha}^{commit}" 2>/dev/null)"
  then
    echo "  FAIL  $sha  ledger row names a commit that does not exist."
    echo "        Either the sha is wrong, or the commit was rebased away and"
    echo "        the row needs updating. A row pointing at nothing checks"
    echo "        nothing."
    FAILED=$((FAILED + 1))
    continue
  fi

  # REACHABLE FROM HEAD, not merely present in the object store. Existence is a
  # weaker claim than the range check it replaces: a commit on an unmerged
  # branch, or a pre-rebase object not yet gc'd, resolves fine and certifies
  # nothing about what this history actually shipped.
  if ! git merge-base --is-ancestor "$row_oid" HEAD 2>/dev/null; then
    echo "  FAIL  $sha  ledger row names a commit that is not an ancestor of"
    echo "        HEAD. It exists, but this history never shipped it, so the"
    echo "        row certifies nothing here."
    FAILED=$((FAILED + 1))
    continue
  fi

  # One row per commit. Compared as full object ids, because two rows can name
  # the same commit at different abbreviation lengths and read as distinct.
  if echo "$SEEN_OIDS" | grep -qx "$row_oid"; then
    echo "  FAIL  $sha  duplicate ledger row: this commit already has one."
    FAILED=$((FAILED + 1))
    continue
  fi
  SEEN_OIDS="$SEEN_OIDS$row_oid
"

  row_subject="$(git log -1 --format='%s' "$row_oid")"
  if ! [[ "$row_subject" =~ ^[a-z]+(\([^\)]*\))?!: ]]; then
    echo "  FAIL  $sha  ledger row names a commit that is not marked breaking:"
    echo "        \"$row_subject\""
    FAILED=$((FAILED + 1))
    continue
  fi

  if ! git show --stat --format='' "$row_oid" | grep -q '^ lib/'; then
    echo "  FAIL  $sha  ledger row names a breaking commit that does not touch"
    echo "        lib/, which is the surface this ledger covers."
    FAILED=$((FAILED + 1))
    continue
  fi

  echo "  ok    $sha  $anchor"
done < "$LEDGER"

echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "FAIL — $FAILED problem(s) between git, tool/breaking-ledger.tsv and CHANGELOG.md."
  exit 1
fi

COUNT="$(echo "$IN_SCOPE" | grep -c . || true)"
echo "PASS — $COUNT breaking lib/ change(s), each with a row and a live CHANGELOG anchor."
