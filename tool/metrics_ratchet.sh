#!/usr/bin/env bash
# =============================================================================
# DCM metrics ratchet — fail on any NEW complexity violation above the baseline
# =============================================================================
# `dcm calculate-metrics` was run by NOTHING. Measured 2026-09-15: zero hits for
# "calculate-metrics" in tool/gate.sh and zero in .github/workflows/ci.yaml —
# the only subcommand either used was `dcm analyze`. So 35 threshold breaches in
# lib/ sat unenforced, including a 633-line function against a 50 threshold and
# a cyclomatic complexity of 70 against 10.
#
# WORSE, AND THE REASON THIS IS A SEPARATE GATE: the inline suppressions do not
# apply. `dcm analyze` honours `// ignore: lines-of-code`; `calculate-metrics`
# does NOT. Measured: wasm_core_bindings.dart:337 carries
# `// ignore: cyclomatic-complexity, lines-of-code` and the metrics report still
# flags that method at 72 lines. Fourteen of the repo's twenty-two inline DCM
# ignores name a metric, so they were annotations against a check that never
# ran — which reads to a maintainer as "handled".
#
# Same ratchet shape as tool/dcm_ratchet.sh, and the same two properties that
# make it hold:
#   - a PR cannot lower its own bar (RATCHET_BASE_REF)
#   - it clicks BOTH ways: an improvement must be captured, not pocketed
#
# Usage: bash tool/metrics_ratchet.sh [path/to/baseline.json]
# Baseline default: tool/metrics-baseline.json  (regenerate with --update)
# =============================================================================
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
BASELINE="${1:-tool/metrics-baseline.json}"
if [ "${1:-}" = "--update" ]; then
  BASELINE=tool/metrics-baseline.json; UPDATE=1
else
  UPDATE=0
fi

# THE BASELINE A PR IS MEASURED AGAINST MUST NOT BE ONE THE PR CAN EDIT.
# `--update` rewrites this file and exits 0, so a lowered baseline committed
# next to the regression it excuses would pass CI. Reading the COMPARISON copy
# from the base branch means a PR cannot lower its own bar. See the longer
# reasoning in tool/coverage_ratchet.sh.
if [ -n "${RATCHET_BASE_REF:-}" ] && [ "$UPDATE" = "0" ]; then
  # The ref must RESOLVE first: a failed fetch is otherwise indistinguishable
  # from "this PR introduces the baseline", and we would silently compare the
  # PR against its own copy while reporting PASS.
  if ! git rev-parse --verify --quiet "${RATCHET_BASE_REF}^{commit}" >/dev/null; then
    echo "FAIL: RATCHET_BASE_REF=${RATCHET_BASE_REF} does not resolve."
    echo "  Refusing to fall back to the working copy — that would measure the"
    echo "  PR against itself and report PASS."
    echo "  Fix the fetch (CI: git fetch --no-tags --depth=1 origin \$GITHUB_BASE_REF),"
    echo "  or unset RATCHET_BASE_REF to run without a base comparison."
    exit 1
  fi
  BASE_COPY="$(mktemp)"
  if git show "${RATCHET_BASE_REF}:${BASELINE}" > "$BASE_COPY" 2>/dev/null; then
    BASE_V=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('_dcm_version',''))" "$BASE_COPY" 2>/dev/null)
    CUR_V=$(python3 -c "import json;print(json.load(open('tool/metrics-baseline.json')).get('_dcm_version',''))" 2>/dev/null)
    if [ -n "$BASE_V" ] && [ "$BASE_V" != "$CUR_V" ]; then
      rm -f "$BASE_COPY"
      echo "note: ${RATCHET_BASE_REF} baseline was made by dcm $BASE_V, this tree"
      echo "      expects $CUR_V. Comparing across analyzer versions is meaningless,"
      echo "      so falling back to the working copy. REVIEW THE BASELINE DIFF."
    else
      echo "note: comparing against ${RATCHET_BASE_REF}:${BASELINE}, not the working copy."
      BASELINE="$BASE_COPY"
    fi
  else
    rm -f "$BASE_COPY"
    echo "note: no ${BASELINE} on ${RATCHET_BASE_REF} -- this PR introduces it."
  fi
fi

# A gate that silently skips is not a gate. Skipping is allowed ONLY when the
# caller opts in explicitly; anywhere this is relied upon, a missing dcm must
# FAIL, because the alternative is a green tick that checked nothing.
if ! command -v dcm >/dev/null 2>&1; then
  if [ "${METRICS_RATCHET_ALLOW_MISSING:-0}" = "1" ]; then
    echo "dcm not installed — SKIPPING (METRICS_RATCHET_ALLOW_MISSING=1)"
    exit 77
  fi
  echo "FAIL: dcm is not installed, so the metrics ratchet cannot run."
  echo "  Install:  brew tap CQLabs/dcm && brew install dcm"
  echo "  To skip deliberately on a machine without it:"
  echo "    METRICS_RATCHET_ALLOW_MISSING=1 bash tool/metrics_ratchet.sh"
  exit 1
fi

# Thresholds live in dcm_options.yaml, so a baseline is only comparable to a
# report from the same dcm. Same pin as tool/dcm_ratchet.sh.
HAVE_V=$(dcm --version 2>&1 | tr -d '\r' | awk '{print $NF}')
WANT_V=$(python3 -c "import json;print(json.load(open('tool/metrics-baseline.json')).get('_dcm_version',''))" 2>/dev/null)
# `--update` MUST BE EXEMPT or the pin deadlocks: the mismatch message tells you
# to regenerate, and regeneration is what is being refused. Measured on the
# 1.37.0 -> 1.39.0 bump -- `--update` printed the same mismatch and changed
# nothing, so the baseline could never move forward.
if [ "$UPDATE" = "0" ] && [ -n "$WANT_V" ] && [ "$HAVE_V" != "$WANT_V" ]; then
  # THE DOCUMENTED OPT-OUT MUST REACH HERE, or this check is a DEADLOCK.
  # This test sits BEFORE the credentials test below, so when the baseline
  # version has drifted it fires first and METRICS_RATCHET_ALLOW_MISSING
  # never got a chance to act. The only remedy it names is `--update`, and
  # regenerating runs dcm, which needs a licence. Measured 2026-09-17 with the
  # CI-key quota exhausted: metrics-baseline.json pinned 1.37.0, the host had
  # 1.39.0, and BOTH METRICS_RATCHET_ALLOW_MISSING=1
  # and the advice dcm_host_gate.sh prints left it FAILING with no way out, so
  # `bash tool/dcm_host_gate.sh` could not go green by any means.
  #
  # A version mismatch means this check cannot compare anything meaningful --
  # which is exactly what the opt-out is for. It exits 77, so the gate records
  # SKIP "did not run, checked nothing" and it can never read as a pass.
  if [ "${METRICS_RATCHET_ALLOW_MISSING:-0}" = "1" ]; then
    echo "dcm version mismatch (baseline $WANT_V, have $HAVE_V) — SKIPPING (METRICS_RATCHET_ALLOW_MISSING=1)"
    echo "  This verified NOTHING. Regenerate with: bash tool/metrics_ratchet.sh --update"
    exit 77
  fi
  echo "FAIL: dcm version mismatch — baseline was generated by $WANT_V, this is $HAVE_V."
  echo "  Counts are not comparable across versions. Install $WANT_V, or bump the"
  echo "  pin AND regenerate in the same commit: bash tool/metrics_ratchet.sh --update"
  exit 1
fi

# DCM is commercial: on CI it refuses without credentials, and it only consults
# them when it believes it is on CI — so CI=true is required alongside them, not
# instead of them. Measured in tool/dcm_ratchet.sh's header.
# DCM IS COMMERCIAL, AND THE LICENCE CAN FAIL FOR REASONS THAT ARE NOT "ABSENT".
# Measured 2026-09-15: after heavy use the CI key returned
#   "Failed to verify DCM license. Bad state: CI key limit for this month has
#    been exceeded."
# and dcm exited 1 with empty stdout -- and running WITHOUT the key does not
# fall back to a free tier, it reports "DCM is not activated". So there are
# stretches where dcm cannot run at all, through no fault of the tree, and this
# gate previously had no way through them: three of its steps became a hard
# stop on an external monthly quota that nothing in the repo documents.
#
# Skipping is allowed ONLY when the caller opts in, the same rule as the
# missing-binary check above. A gate that decides on its own to check nothing
# is not a gate; a gate with no honest way to say "this could not run" is a
# gate people delete.
# LOCAL ACTIVATION IS THE PRIMARY PATH; CI CREDENTIALS ARE THE FALLBACK.
#
# `dcm activate --license-key=...` registers a SEAT on this machine, and an
# activated dcm needs no CI key, no email and no CI=true. That is the normal
# developer path and the only one this project uses: the GitHub CI path is not
# supported here.
#
# This precondition used to demand DCM_CI_KEY and DCM_EMAIL unconditionally, so
# a fully activated host was refused with a message about CI credentials it did
# not need. Measured 2026-09-16 on an activated host: this script exited 1 while
# `dcm analyze lib --reporter=json`, with DCM_CI_KEY, DCM_EMAIL and CI all
# explicitly unset, analysed 67 files and reported 18 issues.
#
# Order matters: prefer the local seat. The CI key carries a MONTHLY RUN BUDGET
# and fails with "CI key limit for this month has been exceeded" once spent;
# a seat does not.
dcm_activated() { dcm license 2>/dev/null | grep -q '^DCM License:'; }

if ! dcm_activated && { [ -z "${DCM_CI_KEY:-}" ] || [ -z "${DCM_EMAIL:-}" ]; }; then
  if [ "${METRICS_RATCHET_ALLOW_MISSING:-0}" = "1" ]; then
    echo "DCM credentials absent — SKIPPING (METRICS_RATCHET_ALLOW_MISSING=1)"
    exit 77
  fi
  echo "FAIL: dcm is not activated here and no CI credentials are set."
  echo "  PREFERRED — activate a seat on this machine:"
  echo "    dcm activate --license-key=\$DCM_KEY   # DCM_KEY lives in ~/dev/.env"
  echo "  dcm only consults them when it believes it is on CI, so CI=true is"
  echo "  set alongside them, not instead of them."
  echo "    export DCM_CI_KEY=...   # the CI key, NOT a license-key"
  echo "    export DCM_EMAIL=...    # the purchase email"
  echo "  The key also has a MONTHLY RUN BUDGET. When it is exhausted dcm fails"
  echo "  with 'CI key limit for this month has been exceeded' and no DCM check"
  echo "  can run until it resets. To gate through that, knowing these steps"
  echo "  then verify nothing:"
  echo "    METRICS_RATCHET_ALLOW_MISSING=1 bash tool/gate.sh"
  exit 1
fi

DCM_AUTH=()
DCM_CI_ENV=()
if [ -n "${DCM_CI_KEY:-}" ] && [ -n "${DCM_EMAIL:-}" ]; then
  DCM_AUTH=(--ci-key="$DCM_CI_KEY" --email="$DCM_EMAIL")
  DCM_CI_ENV=(env CI=true)
fi

TMP=$(mktemp)
ERR=$(mktemp)
# stderr is CAPTURED, not discarded: a gate that hides why it failed is barely
# better than one that cannot fail.
"${DCM_CI_ENV[@]}" dcm calculate-metrics lib --reporter=json "${DCM_AUTH[@]}" > "$TMP" 2>"$ERR"
DCM_RC=$?

if [ ! -s "$TMP" ] || ! python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$TMP" 2>/dev/null; then
  echo "FAIL: \`dcm calculate-metrics --reporter=json\` produced no parseable JSON (exit $DCM_RC)."
  echo "  This is the gate failing to RUN, which is not the same as the gate passing."
  echo "  dcm version: $(dcm --version 2>&1 | head -1)"
  echo "  --- first 20 lines of stderr ---"
  head -20 "$ERR" | sed 's/^/    /'
  rm -f "$TMP" "$ERR"
  exit 1
fi
rm -f "$ERR"

BASELINE="$BASELINE" UPDATE="$UPDATE" TMP="$TMP" HAVE_V="$HAVE_V" python3 - <<'PY'
import json, os, sys, collections

tmp = os.environ['TMP']
baseline_path = os.environ['BASELINE']
update = os.environ['UPDATE'] == '1'

d = json.load(open(tmp))
metrics, files = collections.Counter(), collections.Counter()
for r in d['metricResults']:
    path = r['path'].split('dart_monty_core/')[-1]
    for iss in r.get('issues', []):
        metrics[iss['id']] += 1
        files[path] += 1
current = {
    'total': sum(metrics.values()),
    'by_metric': dict(metrics),
    'by_file': dict(files),
    '_dcm_version': os.environ['HAVE_V'],
}

if update:
    json.dump(current, open(baseline_path, 'w'), indent=2, sort_keys=True)
    print(f"baseline updated: {current['total']} violation(s), "
          f"{len(metrics)} metric(s), {len(files)} file(s)")
    sys.exit(0)

if not os.path.exists(baseline_path):
    print(f"FAIL: no baseline at {baseline_path} — run: bash tool/metrics_ratchet.sh --update")
    sys.exit(1)

base = json.load(open(baseline_path))
bt, bm, bf = base['total'], base['by_metric'], base['by_file']

# A BASELINE THAT LIES IS WORSE THAN A HIGH ONE, because the gate agrees with
# it. tool/dcm_ratchet.sh measured exactly this: hand-editing `total` while
# by_rule still summed to the old figure reported PASS, since the total was
# never compared to anything.
if bt != sum(bm.values()):
    print(f"FATAL: {baseline_path} is inconsistent -- total {bt} but by_metric "
          f"sums to {sum(bm.values())}. Regenerate: "
          f"bash tool/metrics_ratchet.sh --update")
    sys.exit(2)

violations = []
for metric, n in sorted(metrics.items()):
    prev = bm.get(metric, 0)
    if prev == 0:
        violations.append(f"NEW METRIC      {metric}: {n} violation(s)")
    elif n > prev:
        violations.append(f"METRIC INCREASE {metric}: {prev} -> {n}")

for path, n in sorted(files.items()):
    prev = bf.get(path, 0)
    if prev == 0:
        violations.append(f"NEW FILE        {path}: {n} violation(s)")
    elif n > prev:
        violations.append(f"FILE INCREASE   {path}: {prev} -> {n}")

print(f"metrics: {current['total']} violation(s) vs baseline {bt}  "
      f"({len(metrics)} metrics / {len(files)} files vs {len(bm)} / {len(bf)})")

if violations:
    print(f"\nFAIL — {len(violations)} ratchet violation(s):")
    for v in violations:
        print(f"  {v}")
    print("\nSplit the declaration, or if intentional: "
          "bash tool/metrics_ratchet.sh --update")
    sys.exit(1)

# A RATCHET THAT ONLY CLICKS ONE WAY IS NOT A RATCHET. An improvement that is
# not CAPTURED lets the count drift straight back up with the gate still green.
if current['total'] < bt:
    print(f"\nFAIL — {bt - current['total']} fewer violation(s) than baseline, "
          f"and the baseline was not updated.")
    print("  An improvement has to be recorded or it is not held: the count can")
    print("  drift straight back to the old number with this gate still green.")
    print("  Capture it:  bash tool/metrics_ratchet.sh --update")
    sys.exit(1)

print("PASS — no new complexity violations above baseline")
PY
RC=$?
rm -f "$TMP"
exit $RC
