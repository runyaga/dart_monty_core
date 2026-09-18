#!/usr/bin/env bash
# =============================================================================
# tool/example_floor.sh — how many example smoke tests MUST pass
# =============================================================================
# Prints the number to stdout. Every diagnostic goes to stderr, so the caller
# can use `$(bash tool/example_floor.sh)` safely.
#
# THIS IS A RATCHET, AND IT HAD TO BE. The floor was hardcoded `14` in
# .github/workflows/ci.yaml, exactly met at 14 of 14. Two different failures
# hide on either side of a number like that, and fixing one alone re-opens the
# other:
#
#   * A CONSTANT does not rise. Add a 16th example and the floor is still 14, so
#     afterwards one of the existing fifteen can be deleted or skipped and CI
#     stays green. Nothing raises it; nothing notices it was not raised.
#   * A COUNT DERIVED FROM THE TREE does not hold. Delete an example and the
#     derived floor drops with it, so the deletion passes its own check. That is
#     the `--update` shape -- a change that excuses itself -- and it is strictly
#     WEAKER than the constant it would replace.
#
# So both directions fail: EXPECTED_PROGRAMS is declared here and compared
# against the tree. Fewer is a regression; more is an improvement that has to be
# captured in the same commit. Same contract as tool/coverage_ratchet.sh and
# tool/metrics_ratchet.sh.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

# Example programs under example/, top level. Bump in the SAME commit that adds
# or removes one.
EXPECTED_PROGRAMS=15

# Declared skips in test/integration/example_smoke_test.dart. Deriving the floor
# from the skip list alone would let a new skip lower its own bar, so this is a
# deliberate constant too.
#
# The one skip is example/06_compile_and_platform.dart, blocked on core#152:
# Monty.compile() throws "snapshot is not supported on the one-shot handle" on
# the FFI backend (ffi_core_bindings.dart:186-191 vs
# native_bindings_ffi.dart:297). A LIBRARY defect, not an example defect. When
# core#152 is fixed this drops to 0 and the floor rises to 15.
MAX_SKIPS=1

FILES=$(find example -maxdepth 1 -name '*.dart' -type f | wc -l | tr -d ' ')
NESTED=$(find example -name '*.dart' -type f | wc -l | tr -d ' ')

# example_smoke_test.dart selects with Directory('example').listSync(), which is
# NON-RECURSIVE. A .dart file in a subdirectory of example/ is not a test at
# all: it does not fail and it does not skip, it simply is not there.
if [ "$NESTED" -ne "$FILES" ]; then
  echo "FAIL: $((NESTED - FILES)) example .dart file(s) live in a SUBDIRECTORY of example/." >&2
  echo "  test/integration/example_smoke_test.dart selects with" >&2
  echo "  Directory('example').listSync(), which does not recurse, so those" >&2
  echo "  files are silently not smoke-tested." >&2
  find example -mindepth 2 -name '*.dart' -type f | sed 's/^/    /' >&2
  exit 1
fi

if [ "$FILES" -lt "$EXPECTED_PROGRAMS" ]; then
  echo "FAIL: $FILES example programs, expected $EXPECTED_PROGRAMS." >&2
  echo "  An example was deleted or renamed. If that was deliberate, lower" >&2
  echo "  EXPECTED_PROGRAMS in tool/example_floor.sh in the SAME commit and say" >&2
  echo "  why in the body -- do not let a deletion clear its own bar." >&2
  exit 1
fi

if [ "$FILES" -gt "$EXPECTED_PROGRAMS" ]; then
  echo "FAIL: $FILES example programs, expected $EXPECTED_PROGRAMS." >&2
  echo "  An example was ADDED and the count was not captured. Raise" >&2
  echo "  EXPECTED_PROGRAMS to $FILES in tool/example_floor.sh in the SAME" >&2
  echo "  commit, so the new example is covered by the floor from now on." >&2
  echo "  An uncaptured addition leaves room for a later deletion to go green." >&2
  exit 1
fi

SKIPS=$(grep -cE "^[[:space:]]*'example/[^']+\.dart':" \
  test/integration/example_smoke_test.dart || true)

if [ "$SKIPS" -gt "$MAX_SKIPS" ]; then
  echo "FAIL: $SKIPS example(s) are skipped, but MAX_SKIPS is $MAX_SKIPS." >&2
  echo "  A new skip must not lower the bar it is measured against. Raise" >&2
  echo "  MAX_SKIPS in tool/example_floor.sh in the SAME commit that adds the" >&2
  echo "  skip, and say why in the body." >&2
  grep -nE "^[[:space:]]*'example/[^']+\.dart':" \
    test/integration/example_smoke_test.dart | sed 's/^/    /' >&2
  exit 1
fi

echo "  example programs: $FILES (expected $EXPECTED_PROGRAMS), skips: $SKIPS (max $MAX_SKIPS)" >&2
echo $((EXPECTED_PROGRAMS - SKIPS))
