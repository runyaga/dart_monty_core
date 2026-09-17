#!/usr/bin/env bash
# =============================================================================
# Every published page must state the versions it was built from, correctly.
# =============================================================================
# The pages carry a version badge so a reader can tell WHICH build of
# dart_monty_core they are driving -- the deployed site is the one artefact a
# user meets without a pubspec in front of them, and "the demo is broken" and
# "the demo is old" are indistinguishable without it.
#
# A hand-written version string rots the moment someone bumps the pubspec, and
# rots SILENTLY: nothing compiles an HTML shell. This is the same failure shape
# tool/check_fixture_links.sh exists for (links pinned to the wrong monty tag),
# so it gets the same treatment -- a check, not a comment.
#
# Sources of truth, in order of appearance in the badge:
#   dart_monty_core version -> pubspec.yaml `version:`
#   monty pin               -> native/Cargo.toml `tag = "vX.Y.Z"`
#   wire format             -> native/src/convert.rs WIRE_FORMAT_VERSION
# =============================================================================
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

PUB_VER="$(grep -m1 -E '^version:' pubspec.yaml | awk '{print $2}')"
CARGO_TAG="$(grep -m1 -oE 'tag = "v[0-9.]+"' native/Cargo.toml | grep -oE 'v[0-9.]+')"
WIRE_VER="$(grep -m1 -oE 'WIRE_FORMAT_VERSION: u32 = [0-9]+' native/src/convert.rs \
  | grep -oE '[0-9]+$')"

[ -n "$PUB_VER" ]   || { echo "FATAL: no version: in pubspec.yaml"; exit 2; }
[ -n "$CARGO_TAG" ] || { echo "FATAL: no monty tag in native/Cargo.toml"; exit 2; }
[ -n "$WIRE_VER" ]  || { echo "FATAL: no WIRE_FORMAT_VERSION in native/src/convert.rs"; exit 2; }

EXPECTED="dart_monty_core v${PUB_VER} &middot; monty ${CARGO_TAG} &middot; wire v${WIRE_VER}"

# Every page a reader can land on.
PAGES="
docs/index.html
packages/dart_monty_web/web/index_js.html
packages/dart_monty_web/web/index_wasm.html
packages/dart_monty_web/web/matrix_js.html
packages/dart_monty_web/web/matrix_wasm.html
"

# Deliberately excluded, with the reason. An exclusion must be stated here, not
# achieved by being forgotten.
EXCLUDED="
packages/dart_monty_web/web/index.html
"

# -----------------------------------------------------------------------------
# THE LIST MUST COVER THE DIRECTORY, NOT JUST EXIST
# -----------------------------------------------------------------------------
# The loop below checks listed -> exists. It never checked exists -> listed, so
# a NEW page was not version-checked at all -- which is precisely the failure
# the comment inside that loop claims to catch ("a new page added without one
# would otherwise pass by not being looked at"). It could not: an unlisted page
# is never looked at. The stated intent and the code disagreed.
#
# Measured 2026-09-17 before this check: 6 pages on disk, 5 listed, and the
# sixth is the documented stub -- so this closes a trap rather than a live gap.
# `|| true` IS LOAD-BEARING. Under `set -euo pipefail` a failing `find` (a
# renamed or deleted directory -- the exact case the floor below exists for)
# aborts the script at this assignment with exit 1 and NO OUTPUT, so the
# refusal never prints and the reader is told nothing. Measured while
# falsifying this guard: the collapsed-discovery arm died silently here.
DISCOVERED="$(find docs packages/dart_monty_web/web -name '*.html' -type f \
  2>/dev/null | sort || true)"

# REFUSE ON A COLLAPSED SET. If the directories move, `find` returns nothing,
# every page below is "covered" and this gate reports PASS over an empty set --
# a vacuous green that reads as evidence.
NDISC="$(printf '%s\n' "$DISCOVERED" | grep -c '\.html$' || true)"
if [ "$NDISC" -lt 5 ]; then
  echo "REFUSING: discovered $NDISC .html page(s) under docs/ and"
  echo "  packages/dart_monty_web/web (floor 5; it was 6 when written)."
  echo "  Discovery is broken, or pages were deleted. Do not lower the floor."
  exit 2
fi

UNCOVERED=""
for found in $DISCOVERED; do
  case " $(echo $PAGES) $(echo $EXCLUDED) " in
    *" $found "*) ;;
    *) UNCOVERED="$UNCOVERED $found" ;;
  esac
done
if [ -n "$UNCOVERED" ]; then
  echo "FAIL: page(s) on disk that this gate never looks at:"
  for u in $UNCOVERED; do echo "  UNCOVERED: $u"; done
  echo ""
  echo "      A page nobody checks can state any version, or none. Add each to"
  echo "      PAGES, or to EXCLUDED with the reason it carries no badge."
  exit 1
fi

rc=0
for page in $PAGES; do
  if [ ! -f "$page" ]; then
    echo "FAIL: $page does not exist (listed in this gate but missing)"
    rc=1
    continue
  fi
  # A page with no version line at all is the failure this gate is really for:
  # a new page added without one would otherwise pass by not being looked at.
  if ! grep -q 'dart_monty_core v' "$page"; then
    echo "FAIL: $page carries no version badge."
    echo "      Add: $EXPECTED"
    rc=1
    continue
  fi
  if ! grep -qF "$EXPECTED" "$page"; then
    echo "FAIL: $page states the wrong versions."
    echo "      expected: $EXPECTED"
    echo "      found:    $(grep -m1 -o 'dart_monty_core v[^<]*' "$page")"
    rc=1
  fi
done

if [ "$rc" -ne 0 ]; then
  echo ""
  echo "The badge is assembled from pubspec.yaml, native/Cargo.toml and"
  echo "native/src/convert.rs. Update the pages to match, not the other way."
  exit 1
fi

echo "PASS — all $NDISC page(s) on disk are covered; the published ones state"
echo "       $EXPECTED"
