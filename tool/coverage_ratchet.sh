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

BASELINE="$BASELINE" UPDATE="$UPDATE" TRACEFILE="$TRACEFILE" python3 - <<'PY'
import json, os, sys

root = os.getcwd()
baseline_path = os.environ['BASELINE']
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

if current['total']['pct'] > bt['pct']:
    print(f"PASS — and {current['total']['pct'] - bt['pct']:.2f} points above "
          f"baseline. Consider: bash tool/coverage_ratchet.sh {tracefile} "
          f"--update")
else:
    print('PASS — no file below its baseline')
PY
