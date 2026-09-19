#!/usr/bin/env bash
# =============================================================================
# Coverage ratchet — fail on any PER-FILE coverage decrease
# =============================================================================
# Same shape, same reasoning and the same discipline as tool/dcm_ratchet.sh,
# for the same reason: gating on a project total is useless. The total is
# dominated by files nobody is touching, so new native code can land, the FFI
# conformance corpus can fail to grow with it, and that file's coverage slides
# from 80% to 20% while the project number moves half a point and nobody looks.
#
# This ratchets per file instead. Any per-file percentage decrease fails. Any
# file that was in the baseline and is now ABSENT from the tracefile fails —
# absence is how Dart coverage lies (see tool/coverage_report.sh), so "the file
# vanished" must never read as "the file is fine". Improving is always allowed
# and never required.
#
# It also ratchets the lib-wide total, which is what stops the one case a
# per-file rule cannot see: a brand-new file at 0%. New files are not a failure
# on their own — you cannot land code and its tests in the same instant — but
# they cannot quietly drag the project down either.
#
# Usage:
#   bash tool/coverage_ratchet.sh TRACEFILE            # check
#   bash tool/coverage_ratchet.sh TRACEFILE --update   # regenerate the baseline
#
# TRACEFILE is coverage/honest.info from tool/coverage_report.sh. Feeding it a
# RAW lcov.info instead would be a silent downgrade — the raw file omits every
# unloaded library — so this script refuses a tracefile that does not account
# for every lib/**/*.dart.
#
# Baseline: tool/coverage-baseline.json. Regenerate it in the SAME commit that
# justifies the change, exactly as the DCM baseline is handled.
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

BASELINE=tool/coverage-baseline.json
UPDATE=0
TRACEFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --update) UPDATE=1; shift ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    -*) echo "FAIL: unknown option $1" >&2; exit 2 ;;
    *) TRACEFILE="$1"; shift ;;
  esac
done

if [ -z "$TRACEFILE" ]; then
  echo "FAIL: no tracefile given."
  echo "  Usage: bash tool/coverage_ratchet.sh coverage/honest.info [--update]"
  exit 2
fi

# A gate that cannot run has not passed. The whole failure class this repo has
# been bitten by — core#130's empty tracefile short-circuiting the patch gate to
# exit 0 — lives in this branch.
if [ ! -s "$TRACEFILE" ]; then
  echo "FAIL: coverage tracefile '$TRACEFILE' is missing or empty."
  echo "  This is the ratchet failing to RUN, which is not the same as the"
  echo "  ratchet passing. Produce it first:"
  echo "    bash tool/coverage_report.sh --out-dir coverage <hitmap-or-lcov>..."
  exit 1
fi

# ---------------------------------------------------------------------------
# THE BASELINE A PR IS MEASURED AGAINST MUST NOT BE ONE THE PR CAN EDIT.
# ---------------------------------------------------------------------------
# Independent review (agy, 2026-09-14) rated this Severity 4 and it was
# accepted: `--update` rewrites the baseline and exits 0, so a contributor can
# commit a lowered baseline ALONGSIDE the regression it excuses and CI goes
# green. Its phrasing was exact -- "a strict lock, but the key handed to the
# person trying to get past it". tool/dcm_ratchet.sh has the identical shape;
# this work inherited the pattern rather than inventing it.
#
# The fix is not to remove --update, which the commit that legitimately
# justifies a change still needs. It is to read the COMPARISON baseline from the
# BASE BRANCH. A PR then cannot lower its own bar: the baseline it ships governs
# the NEXT PR, not itself.
#
# RATCHET_BASE_REF selects it. CI sets it to origin/$GITHUB_BASE_REF on a pull
# request. Unset -- every local run -- behaves exactly as before, because a
# local run has no base to compare against and blocking it would just train
# people to skip the gate.
# Captured BEFORE the base-ref swap below reassigns BASELINE. The gain check
# needs the file this branch actually ships; the regression check needs the
# base branch's.
OWN_BASELINE="$BASELINE"

if [ -n "${RATCHET_BASE_REF:-}" ] && [ "$UPDATE" = "0" ]; then
  # THE REF ITSELF MUST RESOLVE FIRST, and this check is the difference between
  # a gate and a suggestion. CI fetches the base with `|| true`, so a fetch that
  # fails -- network, a shallow refspec that never creates origin/<base>, a
  # renamed base branch -- leaves the ref absent. `git show <missing-ref>:<file>`
  # and `git show <present-ref>:<missing-file>` BOTH just fail, so without this
  # the two are indistinguishable and a failed fetch silently takes the
  # "this PR introduces the baseline" path: the ratchet falls back to the PR's
  # OWN copy, which is exactly the laundering hole this block exists to close.
  # A guard that degrades open on infrastructure failure is worse than none,
  # because the log still says PASS.
  if ! git rev-parse --verify --quiet "${RATCHET_BASE_REF}^{commit}" >/dev/null; then
    echo "FAIL: RATCHET_BASE_REF=${RATCHET_BASE_REF} does not resolve."
    echo "  The baseline a PR is measured against must come from the BASE branch,"
    echo "  and that ref is not present in this checkout. Refusing to fall back to"
    echo "  the working copy: that is the hole this guard closes, and falling back"
    echo "  silently would report PASS while measuring the PR against itself."
    echo "  Fix the fetch (CI: git fetch --no-tags --depth=1 origin \$GITHUB_BASE_REF),"
    echo "  or unset RATCHET_BASE_REF to run without a base comparison."
    exit 1
  fi
  BASE_COPY="$(mktemp)"
  if git show "${RATCHET_BASE_REF}:${BASELINE}" > "$BASE_COPY" 2>/dev/null; then
    echo "note: comparing against ${RATCHET_BASE_REF}:${BASELINE}, not the"
    echo "      working copy -- a PR cannot lower its own bar."
    BASELINE="$BASE_COPY"
  else
    # A first PR that INTRODUCES the baseline has none on the base branch. That
    # is legitimate and must not fail; say so out loud rather than silently
    # falling back, because silence here is indistinguishable from the hole
    # this block exists to close.
    rm -f "$BASE_COPY"
    echo "note: no ${BASELINE} on ${RATCHET_BASE_REF} -- this PR introduces it."
    echo "      Comparing against the working copy. Review the baseline itself."
  fi
fi

BASELINE="$BASELINE" OWN_BASELINE="$OWN_BASELINE" UPDATE="$UPDATE" TRACEFILE="$TRACEFILE" python3 - <<'PY'
import json, os, sys

root = os.getcwd()
baseline_path = os.environ['BASELINE']
# The baseline the GAIN is measured against, which is NOT always the one the
# REGRESSION is measured against. See the long note at the gain check below.
own_baseline_path = os.environ.get('OWN_BASELINE') or baseline_path
update = os.environ['UPDATE'] == '1'
tracefile = os.environ['TRACEFILE']

# The two documented exclusions, kept in step with tool/coverage_report.sh.
EXCLUDE = ('lib/src/ffi/generated/', 'lib/src/platform/mock_monty_platform.dart')


def excluded(p):
    return any(p.startswith(e) or p == e for e in EXCLUDE)


cur, sf = {}, None
for raw in open(tracefile):
    line = raw.strip()
    if line.startswith('SF:'):
        sf = os.path.relpath(os.path.realpath(line[3:]), root)
        cur.setdefault(sf, {})
    elif line.startswith('DA:') and sf is not None:
        n, h = line[3:].split(',')[:2]
        cur[sf][int(n)] = cur[sf].get(int(n), 0) + int(h)

if not cur:
    print(f'FAIL: no SF records in {tracefile} — nothing to ratchet.')
    sys.exit(1)

# The tracefile must be the HONEST one. A raw lcov.info omits every library no
# test imported, so ratcheting against it would bless exactly the disappearance
# this whole mechanism exists to catch: delete an import, the file leaves the
# tracefile, and a per-file rule sees nothing to compare.
on_disk = sorted(
    os.path.join(d, n)
    for d, _, names in os.walk('lib')
    for n in names
    if n.endswith('.dart') and not excluded(os.path.join(d, n))
)
absent = sorted(set(on_disk) - set(cur))
if absent:
    print(f'FAIL: {tracefile} does not account for every lib/ file '
          f'({len(absent)} missing).')
    for a in absent[:10]:
        print(f'    {a}')
    if len(absent) > 10:
        print(f'    ... and {len(absent) - 10} more')
    print('  That is a RAW tracefile, not coverage/honest.info. Pass the output')
    print('  of tool/coverage_report.sh, or the ratchet is guarding a subset.')
    sys.exit(1)


def stats(lines):
    found = len(lines)
    hit = sum(1 for h in lines.values() if h > 0)
    # 2 dp: enough to catch one line in a 400-line file, coarse enough that
    # float noise cannot invent a violation.
    pct = round(100.0 * hit / found, 2) if found else 0.0
    return {'hit': hit, 'found': found, 'pct': pct}


by_file = {f: stats(l) for f, l in sorted(cur.items())}
tot_found = sum(v['found'] for v in by_file.values())
tot_hit = sum(v['hit'] for v in by_file.values())
current = {
    '_note': 'Per-file coverage floor. Regenerate ONLY in the commit that '
             'justifies the change: bash tool/coverage_ratchet.sh '
             'coverage/honest.info --update',
    'total': {'hit': tot_hit, 'found': tot_found,
              'pct': round(100.0 * tot_hit / tot_found, 2) if tot_found else 0.0},
    'by_file': by_file,
}

if update:
    with open(baseline_path, 'w') as fh:
        json.dump(current, fh, indent=2, sort_keys=True)
        fh.write('\n')
    print(f"baseline updated: {current['total']['pct']}% "
          f"({tot_hit}/{tot_found}) across {len(by_file)} files")
    sys.exit(0)

if not os.path.exists(baseline_path):
    print(f'FAIL: no baseline at {baseline_path} — run:')
    print(f'  bash tool/coverage_ratchet.sh {tracefile} --update')
    sys.exit(1)

base = json.load(open(baseline_path))
bt, bf = base['total'], base['by_file']
violations = []

for path, prev in sorted(bf.items()):
    now = by_file.get(path)
    if now is None:
        violations.append(
            f"VANISHED      {path}: was {prev['pct']}% "
            f"({prev['hit']}/{prev['found']}), now absent from the tracefile")
    elif now['pct'] < prev['pct']:
        violations.append(
            f"FILE DECREASE {path}: {prev['pct']}% -> {now['pct']}% "
            f"({prev['hit']}/{prev['found']} -> {now['hit']}/{now['found']})")

new_files = sorted(set(by_file) - set(bf))
if current['total']['pct'] < bt['pct']:
    violations.append(
        f"TOTAL DECREASE lib-wide: {bt['pct']}% -> {current['total']['pct']}% "
        f"({bt['hit']}/{bt['found']} -> {tot_hit}/{tot_found})")

print(f"coverage: {current['total']['pct']}% ({tot_hit}/{tot_found}) "
      f"vs baseline {bt['pct']}% ({bt['hit']}/{bt['found']}), "
      f"{len(by_file)} files vs {len(bf)}")
for n in new_files:
    print(f"  new file: {n} at {by_file[n]['pct']}% "
          f"({by_file[n]['hit']}/{by_file[n]['found']})")

if violations:
    print(f'\nFAIL — {len(violations)} ratchet violation(s):')
    for v in violations:
        print(f'  {v}')
    print('\nFix them, or if the drop is intentional and justified, regenerate')
    print('the baseline IN THE SAME COMMIT and say why in the commit body:')
    print(f'  bash tool/coverage_ratchet.sh {tracefile} --update')
    sys.exit(1)

# Same one-way-ratchet defect as tool/dcm_ratchet.sh, same fix. Printing
# "Consider: --update" and exiting 0 means a coverage GAIN is never captured:
# the baseline stays low and the percentage can slide back down to it with the
# gate green. A gain now FAILS until the baseline records it.
# THE TWO DIRECTIONS READ DIFFERENT BASELINES, AND THAT IS THE WHOLE POINT.
#
# REGRESSION is measured against the BASE BRANCH's baseline, above: a PR must
# not be able to lower its own bar.
#
# A RECORDED GAIN is measured against THIS BRANCH's baseline. Measured
# 2026-09-19 on PR #169: with RATCHET_BASE_REF set, `bt` is origin/main's copy,
# so a PR that raised coverage 66.57% -> 66.64% failed here, ran the `--update`
# the failure prints, and FAILED AGAIN IDENTICALLY -- the updated file is never
# read. There was no edit that could pass. A gate that demands an action, and
# then ignores that action, is worse than no gate: it teaches people the check
# is broken and to look for the override.
own = json.load(open(own_baseline_path)) if os.path.exists(own_baseline_path) \
    else base
if current['total']['pct'] > own['total']['pct']:
    gain = current['total']['pct'] - own['total']['pct']
    print(f"\nFAIL — coverage is {gain:.2f} points ABOVE this branch's "
          f"baseline ({own['total']['pct']}%).")
    print("  Good news that has to be recorded or it is not kept: a baseline")
    print("  left low lets coverage slide back with the gate still green.")
    print("  Raise it IN THIS COMMIT:")
    print(f"      bash tool/coverage_ratchet.sh {tracefile} --update")
    sys.exit(1)

if own['total']['pct'] > bt['pct']:
    print(f"note: this branch raises the recorded baseline "
          f"{bt['pct']}% -> {own['total']['pct']}%.")

print('PASS — no file below its baseline')
PY
