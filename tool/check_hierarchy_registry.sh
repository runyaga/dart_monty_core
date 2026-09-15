#!/usr/bin/env bash
# =============================================================================
# The type and exception hierarchies have ONE registry, and it is complete
# =============================================================================
# WHY THIS IS A SOURCE-LEVEL SCRIPT AND NOT A DART TEST.
#
# The obvious guard is `expect(samples.length, 26)` inside the matrix, and that
# is what was there. It CANNOT WORK. Dart has no runtime reflection on the web
# or under AOT, so a test cannot enumerate the subtypes of a sealed class. That
# guard compares a hand-written table against a hand-written number: adding a
# 27th subtype WITHOUT a sample leaves the table at 26 and the test green. It
# detects a sample being deleted, and nothing else -- while its own comment
# claimed it stopped the matrix rotting.
#
# Reading lib/ is the only way to know what the hierarchy actually contains.
# Same idiom as tool/check_forgery_coverage.sh, for the same reason.
#
# THREE FAILURES, not one:
#   1. a hierarchy member with no registry entry   (coverage silently shrank)
#   2. a registry entry naming no real class       (a dead row, tests a ghost)
#   3. the SAME member declared in two registries  (the phantom double set:
#      two sources of truth that can disagree about semantics)
# =============================================================================
set -uo pipefail

REG=test/unit/platform/_hierarchy_registry.dart
FAIL=0

[ -f "$REG" ] || { echo "FATAL: no registry at $REG"; exit 2; }

# --- what the hierarchy ACTUALLY contains, read from lib/ ---------------------
# `[A-Za-z0-9_]`, NOT `[A-Za-z]`. The first version of this gate used the
# letters-only class and was FALSIFIED BY ITS OWN PROBE: a planted
# `MontyProbe27` was invisible to it and the gate reported PASS. Any real
# subtype with a digit in its name -- MontyInt64, MontyUtf8String -- would have
# been equally invisible, which is the exact silent-shrink this file exists to
# stop.
LIB_VALUES=$(grep -rhoE '^final class (Monty[A-Za-z0-9_]+) extends MontyValue' \
  lib/src/platform/ | awk '{print $3}' | LC_ALL=C sort -u)
LIB_ERRORS=$(grep -rhoE '^(final )?class (Monty[A-Za-z0-9_]+) extends (MontyError|MontyScriptError)' \
  lib/src/platform/ | sed -E 's/^(final )?class //; s/ extends.*//' | LC_ALL=C sort -u)

# --- what the registry CLAIMS ------------------------------------------------
REG_VALUES=$(grep -oE "^  '(Monty[A-Za-z0-9_]+)':" "$REG" | tr -d " ':" | LC_ALL=C sort)
REG_ERRORS=$(grep -oE '// ERROR (Monty[A-Za-z0-9_]+)' "$REG" | awk '{print $3}' | LC_ALL=C sort)

check() {                       # check <label> <from-lib> <from-registry>
  local label="$1" lib="$2" reg="$3"
  local missing extra dupes
  missing=$(LC_ALL=C comm -23 <(echo "$lib") <(echo "$reg" | LC_ALL=C sort -u))
  extra=$(LC_ALL=C comm -13 <(echo "$lib") <(echo "$reg" | LC_ALL=C sort -u))
  # A name appearing twice in the registry is the phantom double set.
  dupes=$(echo "$reg" | LC_ALL=C uniq -d)

  if [ -n "$missing" ]; then
    echo "FAIL: $label in lib/ with NO registry entry -- coverage shrank silently:"
    echo "$missing" | sed 's/^/    /'
    FAIL=1
  fi
  if [ -n "$extra" ]; then
    echo "FAIL: $label registry rows naming no real class -- testing a ghost:"
    echo "$extra" | sed 's/^/    /'
    FAIL=1
  fi
  if [ -n "$dupes" ]; then
    echo "FAIL: $label declared TWICE in the registry -- two sources of truth"
    echo "      that can drift into different semantics:"
    echo "$dupes" | sed 's/^/    /'
    FAIL=1
  fi
  [ -z "$missing$extra$dupes" ] &&
    echo "  ok  $label: $(echo "$lib" | wc -l | tr -d ' ') member(s), each registered exactly once"
}

check "MontyValue subtype" "$LIB_VALUES" "$REG_VALUES"
check "MontyError subclass" "$LIB_ERRORS" "$REG_ERRORS"

# --- nobody may keep a SECOND sample table ----------------------------------
# The registry is the single source. A second table of per-subtype samples is
# the phantom double set this file exists to prevent, and it is how two suites
# come to disagree about what a type means.
# Match the DECLARATION NAME, not the type arguments. An earlier version keyed
# on `<String, MontyValue>` and was weakened the moment DCM's
# avoid-inferrable-type-arguments made the registry drop its own type args: a
# stray table could then evade the gate simply by omitting them too.
STRAY=$(grep -rlnE '(final|const|var)[[:space:]]+(hierarchySamples|wireFixtures|samples|fixtures)[[:space:]]*=[[:space:]]*(<[^>]*>)?\{' \
  test/ 2>/dev/null | grep -v "$REG" || true)
if [ -n "$STRAY" ]; then
  echo "FAIL: a second per-subtype sample table exists outside the registry:"
  echo "$STRAY" | sed 's/^/    /'
  echo "      Import the registry instead. Two tables disagree eventually."
  FAIL=1
else
  echo "  ok  no competing sample table outside the registry"
fi

[ "$FAIL" = 0 ] && echo "PASS — one registry, complete, no duplicates." || exit 1
