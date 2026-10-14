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
# vanished" must never read as "the file is fine". A file the change deletes
# (git says so, against RATCHET_BASE_REF) is DELETED instead, and passes.
# Improving is always allowed and never required.
#
# It also ratchets the lib-wide total, which is what stops the one case a
# per-file rule cannot see: a brand-new file at 0%. New files are not a failure
# on their own — you cannot land code and its tests in the same instant — but
# they cannot quietly drag the project down either.
#
# Usage:
#   bash tool/coverage_ratchet.sh TRACEFILE            # check
#   bash tool/coverage_ratchet.sh TRACEFILE --update   # regenerate the baseline
#   bash tool/coverage_ratchet.sh --self-test          # the controls
#
# TRACEFILE is coverage/honest.info from tool/coverage_report.sh. Feeding it a
# RAW lcov.info instead would be a silent downgrade — the raw file omits every
# unloaded library — so this script refuses a tracefile that does not account
# for every lib/**/*.dart.
#
# Baseline: tool/coverage-baseline.json, recorded on main after each merge by
# tool/record_coverage_baseline.sh. A PR does NOT commit it when coverage rises:
# the check fails only on a decrease, measured against the base branch's copy.
# =============================================================================
set -uo pipefail
SELF="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# --self-test: the controls, each against a throwaway repository whose base
# commit holds three lib/ files and the baseline recorded from them.
self_test() {
  local tmp rc=0
  tmp="$(mktemp -d)"; trap '/bin/rm -rf "$tmp"' RETURN
  tmp="$(cd "$tmp" && pwd -P)"
  local repo="$tmp/repo"
  mkdir -p "$repo/lib/src" "$repo/tool" || return 1
  # trace <path:hit/found>...: an lcov tracefile, lines 1..found, the first
  # `hit` of them hit.
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
  git init -q "$repo" && (
    cd "$repo" && git config user.email t@t && git config user.name t &&
    for f in a b c; do echo "// $f" > "lib/src/$f.dart"; done &&
    trace lib/src/a.dart:4/4 lib/src/b.dart:2/4 lib/src/c.dart:1/4 &&
    bash "$SELF" "$tmp/trace.info" --update >/dev/null &&
    git add -A && git commit -qm base
  ) || return 1
  local base
  base="$(git -C "$repo" rev-parse HEAD)"
  reset(){ git -C "$repo" checkout -q -f "$base" && git -C "$repo" clean -qfd; }
  commit(){ git -C "$repo" add -A && git -C "$repo" commit -qm x; }
  # run <name> <expected exit> <base ref or ''> [text the output must hold]
  run() {
    local name="$1" want="$2" ref="$3" grep_for="${4:-}" out got=0
    out="$(cd "$repo" && RATCHET_BASE_REF="$ref" bash "$SELF" "$tmp/trace.info" 2>&1)" || got=1
    if [ "$got" != "$want" ]; then
      echo "SELF-TEST FAIL: $name (expected exit $want, got $got)"; echo "$out"; rc=1
    elif [ -n "$grep_for" ] && ! printf '%s\n' "$out" | grep -qF -- "$grep_for"; then
      echo "SELF-TEST FAIL: $name (output lacks '$grep_for')"; echo "$out"; rc=1
    else echo "ok: $name"; fi
  }

  reset; trace lib/src/a.dart:4/4 lib/src/b.dart:2/4 lib/src/c.dart:1/4
  run "nothing changed" 0 "$base"
  reset; git -C "$repo" rm -q lib/src/a.dart; commit
  trace lib/src/b.dart:2/4 lib/src/c.dart:1/4
  run "deletes a 100% file, nothing else: passes" 0 "$base" "DELETED"
  run "the same deletion without a base ref: VANISHED" 1 "" "VANISHED"
  trace lib/src/b.dart:1/4 lib/src/c.dart:1/4
  run "deletes a file and lowers another: FILE DECREASE" 1 "$base" "FILE DECREASE"
  reset; echo '// d' > "$repo/lib/src/d.dart"; commit
  trace lib/src/a.dart:4/4 lib/src/b.dart:2/4 lib/src/c.dart:1/4 lib/src/d.dart:0/8
  run "keeps every file, lowers the total: TOTAL DECREASE" 1 "$base" "TOTAL DECREASE"
  reset; git -C "$repo" rm -q lib/src/a.dart; echo '// d' > "$repo/lib/src/d.dart"; commit
  trace lib/src/b.dart:2/4 lib/src/c.dart:1/4 lib/src/d.dart:0/8
  run "deletes a file, adds an untested one: TOTAL DECREASE" 1 "$base" "TOTAL DECREASE"
  reset; git -C "$repo" mv lib/src/a.dart lib/src/a2.dart; commit
  trace lib/src/a2.dart:4/4 lib/src/b.dart:2/4 lib/src/c.dart:1/4
  run "renames a file: the old path DELETED, the new one counted" 0 "$base" "DELETED"
  reset; trace lib/src/a.dart:4/4 lib/src/b.dart:2/4
  run "keeps a file the tracefile lacks: fails" 1 "$base"
  reset; /bin/rm "$repo/lib/src/a.dart"
  trace lib/src/b.dart:2/4 lib/src/c.dart:1/4
  run "removes a file the commit keeps (working tree only): VANISHED" 1 "$base" "VANISHED"
  reset; git -C "$repo" rm -q lib/src/a.dart; commit
  git -C "$repo" checkout -q "$base" -- lib/src/a.dart
  trace lib/src/a.dart:0/4 lib/src/b.dart:2/4 lib/src/c.dart:1/4
  run "deleted in the commit, restored in the tree: not DELETED" 1 "$base" "FILE DECREASE"
  [ "$rc" = 0 ] && echo "PASS: coverage ratchet self-test"
  return "$rc"
}
if [ "${1:-}" = --self-test ]; then self_test; exit $?; fi

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

# ---------------------------------------------------------------------------
# A FILE THE PR DELETES IS NOT A FILE THAT VANISHED.
# ---------------------------------------------------------------------------
# The comparison baseline is the base branch's, so it still lists every file
# the PR removes from lib/. Those are reported as DELETED rather than
# VANISHED, and the lib-wide total they are compared with is recomputed
# without them: otherwise deleting a well-covered file lowers the PR's total
# below a base figure that still counts it, and the PR cannot fix that by
# recording a baseline (it may not edit it). A deletion is read from git,
# never inferred from absence: a path counts only if `git diff` from the base
# to the COMMITTED head reports it deleted (renames as a delete plus an add)
# and it is not in the working tree either. A file removed from the working
# tree but still in HEAD is not deleted by the change, and stays VANISHED. Without RATCHET_BASE_REF there is no base to diff against,
# and every absent baseline file stays VANISHED.
DELETED=""
if [ -n "${RATCHET_BASE_REF:-}" ] && [ "$UPDATE" = "0" ]; then
  if ! DELETED="$(git diff --name-only --no-renames --diff-filter=D \
      "${RATCHET_BASE_REF}" HEAD -- lib/)"; then
    echo "FAIL: cannot list the files deleted since ${RATCHET_BASE_REF}."
    exit 1
  fi
fi

BASELINE="$BASELINE" UPDATE="$UPDATE" TRACEFILE="$TRACEFILE" DELETED="$DELETED" python3 - <<'PY'
import json, os, sys

root = os.getcwd()
baseline_path = os.environ['BASELINE']
update = os.environ['UPDATE'] == '1'
tracefile = os.environ['TRACEFILE']

# The documented exclusions, kept in step with tool/coverage_report.sh.
def _nonfinite(c):
    print(f'FAIL: non-finite number {c} in a baseline file; refusing it.')
    sys.exit(1)


def load_json(path):
    with open(path) as fh:
        d = json.load(fh, parse_constant=_nonfinite)
    # 1e999 overflows to inf without going through parse_constant.
    pcts = [d['total']['pct']] + [v['pct'] for v in d['by_file'].values()]
    if not all(isinstance(p, (int, float)) and 0 <= p <= 100 for p in pcts):
        print(f'FAIL: {path} has a coverage percentage outside 0..100.')
        sys.exit(1)
    return d


EXCLUDE = ('lib/src/ffi/generated/', 'lib/src/worker/proto/',
           'lib/src/platform/mock_monty_platform.dart')


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

base = load_json(baseline_path)
bt, bf = base['total'], base['by_file']
violations = []

deleted = sorted(p for p in os.environ['DELETED'].splitlines()
                 if p in bf and not os.path.exists(p))
# The base total over the baseline files this PR keeps (F3). Unchanged when
# it deletes none, so every other PR is compared exactly as before.
if deleted:
    kept = [v for p, v in bf.items() if p not in deleted]
    k_hit = sum(v['hit'] for v in kept)
    k_found = sum(v['found'] for v in kept)
    cmp_total = {'hit': k_hit, 'found': k_found,
                 'pct': round(100.0 * k_hit / k_found, 2) if k_found else 0.0}
else:
    cmp_total = bt

for path, prev in sorted(bf.items()):
    now = by_file.get(path)
    if path in deleted:
        continue
    if now is None:
        violations.append(
            f"VANISHED      {path}: was {prev['pct']}% "
            f"({prev['hit']}/{prev['found']}), now absent from the tracefile")
    elif now['pct'] < prev['pct']:
        violations.append(
            f"FILE DECREASE {path}: {prev['pct']}% -> {now['pct']}% "
            f"({prev['hit']}/{prev['found']} -> {now['hit']}/{now['found']})")

new_files = sorted(set(by_file) - set(bf))
ct = cmp_total
if current['total']['pct'] < ct['pct']:
    violations.append(
        f"TOTAL DECREASE lib-wide: {ct['pct']}% -> {current['total']['pct']}% "
        f"({ct['hit']}/{ct['found']} -> {tot_hit}/{tot_found})")

print(f"coverage: {current['total']['pct']}% ({tot_hit}/{tot_found}) "
      f"vs baseline {bt['pct']}% ({bt['hit']}/{bt['found']}), "
      f"{len(by_file)} files vs {len(bf)}")
if deleted:
    print(f"  compared with the baseline over the files kept: {ct['pct']}% "
          f"({ct['hit']}/{ct['found']}), {len(deleted)} deleted file(s) "
          f"excluded")
for d in deleted:
    print(f"  DELETED       {d}: was {bf[d]['pct']}% "
          f"({bf[d]['hit']}/{bf[d]['found']}), removed by this change")
for n in new_files:
    print(f"  new file: {n} at {by_file[n]['pct']}% "
          f"({by_file[n]['hit']}/{by_file[n]['found']})")

if violations:
    print(f'\nFAIL — {len(violations)} ratchet violation(s):')
    for v in violations:
        print(f'  {v}')
    print('\nFix them. A drop that is intentional and justified needs a')
    print('maintainer to lower the baseline on the base branch first:')
    print(f'  bash tool/coverage_ratchet.sh {tracefile} --update')
    sys.exit(1)

# A GAIN IS NOT A FAILURE, AND NO PR HAS TO RECORD ONE.
#
# This block used to FAIL when lib-wide coverage was above the branch's own
# baseline, forcing every PR that raised coverage to also commit a regenerated
# tool/coverage-baseline.json. That put the baseline in every PR's diff, a
# guaranteed rebase conflict between sibling PRs. The baseline is now recorded
# on main after merge (tool/record_coverage_baseline.sh), so the ratchet only
# fails on decreases, against the BASE branch's copy, above. That a PR does not
# edit the baseline file at all is checked on its diff against the merge-base
# (tool/check_changelog_fragments.sh), which stays correct when main's baseline
# moves while the PR is open; comparing file contents here would not.

print('PASS — no file below its baseline')
PY
