#!/usr/bin/env bash
# =============================================================================
# Every dcm_options.yaml exclusion must still hide something.
# =============================================================================
# A DCM exclusion is a written promise: "this rule fires here, and here is why
# that is acceptable". When the code it describes changes, the promise silently
# becomes false — the entry stays, its comment still reads convincingly, and it
# now suppresses NOTHING except any future violation that lands in that file.
#
# That is not hypothetical. Four were found in one day, 2026-09-15:
#
#   avoid-unsafe-collection-methods  lib/src/monty_session.dart    (24a31da)
#   avoid-unused-parameters          lib/src/monty_session.dart    (this gate)
#   prefer-match-file-name           lib/src/callbacks.dart        (this gate)
#   prefer-match-file-name           lib/src/repl/monty_repl.dart  (this gate)
#   no-empty-block                   lib/src/platform/monty_platform.dart (c9abbca)
#
# The first three name files that DO NOT EXIST. `lib/src/monty_session.dart`
# was deleted in 22cbe08 (PR #57) and was still excluded by two separate rules
# months later, one of them carrying the comment "limits/scriptName kept for
# API compatibility; REPL ignores both" — describing parameters of a file that
# is not in the tree.
#
# DCM does not warn about this. An exclusion pointing at a missing path is not
# an error to DCM; it simply matches nothing.
#
# WHAT THIS CHECKS (fast, no DCM run, no network)
#   Every exclusion entry that names a CONCRETE path must exist on disk.
#   Glob entries (`test/**`, `lib/**/native_bindings.dart`) are skipped: a glob
#   legitimately matches zero files today and more tomorrow.
#
# WHAT IT DOES NOT CHECK, and how to check it
#   An entry can point at a real file and STILL hide nothing, because the
#   violation it was written for has been fixed — `lib/src/repl/monty_repl.dart`
#   was exactly this (its first class is `MontyRepl`, which already matches the
#   file name). Catching those needs DCM run with the exclusions stripped:
#
#       bash tool/check_dcm_exclusions.sh --deep
#
#   That is not in the gate because it costs a second full `dcm analyze` and
#   needs the CI credentials. Run it when touching dcm_options.yaml.
# =============================================================================
set -euo pipefail

cd "$(dirname "$0")/.."
CONFIG="dcm_options.yaml"

[ -f "$CONFIG" ] || { echo "FATAL: $CONFIG not found"; exit 2; }

DEEP=0
[ "${1:-}" = "--deep" ] && DEEP=1

# ---------------------------------------------------------------------------
# Parse rule-level exclusion entries as  <rule>\t<path>
# ---------------------------------------------------------------------------
ENTRIES="$(python3 - "$CONFIG" <<'PY'
import re, sys
lines = open(sys.argv[1]).read().split('\n')
i = 0
cur = None
while i < len(lines):
    l = lines[i]
    m = re.match(r'^(\s{4,})-\s*([a-z-]+):\s*$', l)
    if m:
        cur = m.group(2)
    me = re.match(r'^(\s{6,})exclude:\s*$', l)
    if me and cur:
        ind = len(me.group(1))
        i += 1
        while i < len(lines):
            nl = lines[i]
            if nl.strip() == '' or nl.strip().startswith('#'):
                i += 1
                continue
            if len(nl) - len(nl.lstrip()) <= ind:
                break
            mm = re.match(r'^\s*-\s*"([^"]+)"', nl)
            if mm:
                print(f"{cur}\t{mm.group(1)}")
            i += 1
        continue
    i += 1
PY
)"

TOTAL=0
CHECKED=0
MISSING=""

while IFS=$'\t' read -r rule path; do
  [ -n "$rule" ] || continue
  TOTAL=$((TOTAL + 1))
  case "$path" in
    *'*'*) continue ;;   # glob: legitimately matches zero files
  esac
  CHECKED=$((CHECKED + 1))
  if [ ! -f "$path" ]; then
    MISSING="${MISSING}    ${rule}: ${path}"$'\n'
  fi
done <<< "$ENTRIES"

if [ -n "$MISSING" ]; then
  echo "FAIL — dcm_options.yaml excludes path(s) that do not exist:"
  printf '%s' "$MISSING"
  echo
  echo "  An exclusion naming a missing file suppresses nothing today and"
  echo "  silently suppresses whatever lands at that path tomorrow. Its"
  echo "  comment also describes code that is not in the tree, which is worse"
  echo "  than no comment."
  echo
  echo "  Delete the entry. If the file was RENAMED and the rule still fires"
  echo "  at the new path, move the entry and re-verify the reason still holds."
  exit 1
fi

echo "PASS — $CHECKED concrete exclusion path(s) exist ($TOTAL entries, $((TOTAL - CHECKED)) globs skipped)."

if [ "$DEEP" = "1" ]; then
  echo
  echo "--deep: re-run DCM with exclusions stripped to find entries that hide"
  echo "        nothing. Requires DCM_CI_KEY and DCM_EMAIL."
  echo "        (Not implemented as an automated comparison yet: the one-shot"
  echo "        measurement is recorded in the 2026-09-15 sweep. Re-derive with"
  echo "        the transform in that commit if you need it again.)"
fi
