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
#
#   Exit codes: 0 clean (or skipped for missing credentials), 1 dormant entry
#   found, 2 refused to run (config dirty, or dcm produced no output). Check
#   the code, not the text -- piping this through `tail` discards it.
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

[ "$DEEP" = "1" ] || exit 0

# ---------------------------------------------------------------------------
# --deep: an entry can name a real file and STILL hide nothing, because the
# violation it was written for has been fixed. `lib/src/repl/monty_repl.dart`
# was exactly that. Catching it needs DCM run with the exclusions stripped,
# so this is opt-in: a full `dcm analyze` plus the CI credentials.
#
# DCM has no `--config <path>` -- it reads dcm_options.yaml from --root-folder.
# So the file is SWAPPED and restored by a trap that fires on error and on
# interrupt, not only on the happy path. It refuses to start if that file is
# already dirty, so a kill can never eat uncommitted edits.
# ---------------------------------------------------------------------------
echo
if [ -z "${DCM_CI_KEY:-}" ] || [ -z "${DCM_EMAIL:-}" ]; then
  echo "SKIP --deep: needs DCM_CI_KEY and DCM_EMAIL. Without BOTH (and CI=true)"
  echo "             dcm reports a licence error and exits nonzero for a reason"
  echo "             that has nothing to do with exclusions."
  exit 0
fi
if ! git diff --quiet -- "$CONFIG" 2>/dev/null; then
  echo "REFUSING --deep: $CONFIG has uncommitted changes."
  echo "  This mode swaps that file and restores it from a trap. Starting dirty"
  echo "  risks losing your edits if the process is killed."
  exit 2
fi

BACKUP="$(mktemp)"
cp "$CONFIG" "$BACKUP"
restore() { cp "$BACKUP" "$CONFIG"; rm -f "$BACKUP"; }
trap restore EXIT INT TERM

# Strip rule-level excludes. A rule whose ONLY config was its exclude list must
# become `- rule`, NOT `- rule:` with an empty body -- DCM silently DROPS the
# latter, which under-reports and reads like a clean sweep. That mistake turned
# a real figure of 177 into 542 once already.
python3 - "$CONFIG" <<'PY_STRIP'
import re, sys
path = sys.argv[1]
lines = open(path).read().split('\n')
out, i = [], 0
while i < len(lines):
    l = lines[i]
    m = re.match(r'^(\s{4,})-\s*([a-z-]+):\s*$', l)
    if m:
        ind, rule = len(m.group(1)), m.group(2)
        j, body = i + 1, []
        while j < len(lines):
            nl = lines[j]
            if nl.strip() == '':
                body.append(nl); j += 1; continue
            if len(nl) - len(nl.lstrip()) <= ind:
                break
            body.append(nl); j += 1
        rest, k = [], 0
        while k < len(body):
            b = body[k]
            me = re.match(r'^(\s*)exclude:\s*$', b)
            if me:
                eind = len(me.group(1)); k += 1
                while k < len(body):
                    nb = body[k]
                    if nb.strip() == '':
                        k += 1; continue
                    if len(nb) - len(nb.lstrip()) <= eind:
                        break
                    k += 1
                continue
            rest.append(b); k += 1
        meaningful = [r for r in rest if r.strip() and not r.strip().startswith('#')]
        if meaningful:
            out.append(l); out.extend(rest)
        else:
            out.append(f'{m.group(1)}- {rule}')
        i = j; continue
    out.append(l); i += 1
open(path, 'w').write('\n'.join(out))
PY_STRIP

REPORT="$(mktemp)"
CI=true dcm analyze lib test --reporter=json \
  --ci-key="$DCM_CI_KEY" --email="$DCM_EMAIL" > "$REPORT" 2>/dev/null || true
restore
trap - EXIT INT TERM

if [ ! -s "$REPORT" ]; then
  echo "FAIL --deep: dcm produced no output. Config restored."
  rm -f "$REPORT"
  exit 2
fi

ENTRIES="$ENTRIES" python3 - "$REPORT" <<'PY_CHECK'
import json, os, sys, fnmatch, collections
d = json.load(open(sys.argv[1]))
hits = collections.Counter()
for r in d.get('analyzeResults', []):
    p = r.get('path') or ''
    for i in r.get('issues', []):
        hits[(i['id'], p)] += 1

def matches(pat, path):
    if pat.endswith('/**'):
        return path.startswith(pat[:-3] + '/')
    if '**' in pat:
        return fnmatch.fnmatch(path, pat.replace('**', '*'))
    return path == pat

dormant = []
for line in os.environ['ENTRIES'].split('\n'):
    if not line.strip():
        continue
    rule, pat = line.split('\t')
    if not any(v for (rid, p), v in hits.items() if rid == rule and matches(pat, p)):
        dormant.append((rule, pat))

total = sum(hits.values())
if dormant:
    print(f'FAIL --deep: {len(dormant)} exclusion(s) hide nothing '
          f'({total} issues surfaced with exclusions stripped):')
    for rule, pat in dormant:
        print(f'    {rule}: {pat}')
    print()
    print('  Each suppresses no violation today. Delete it -- and if the rule')
    print('  was FIXED rather than excluded, that is still a delete.')
    sys.exit(1)
print(f'PASS --deep: all {len(os.environ["ENTRIES"].strip().splitlines())} '
      f'exclusion(s) still hide at least one issue '
      f'({total} surfaced with exclusions stripped).')
PY_CHECK
DEEP_RC=$?
rm -f "$REPORT"
exit $DEEP_RC
