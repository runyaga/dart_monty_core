#!/usr/bin/env bash
# =============================================================================
# DCM ratchet — fail on any NEW issue above the recorded baseline
# =============================================================================
# `dcm analyze` has been chronically red (206 issues at 0.18.1), which makes it
# useless as an upgrade gate: 5 new issues move the count 206 -> 211 and nobody
# notices, and *fixing* 10 old issues masks new ones behind a net improvement.
#
# This ratchets instead: any new rule, any per-rule increase, or any new file
# with issues fails. Reducing counts is always allowed and never required.
#
# Usage: bash tool/dcm_ratchet.sh [path/to/baseline.json]
# Baseline default: tool/dcm-baseline.json  (regenerate with --update)
# =============================================================================
set -uo pipefail

cd "$(git rev-parse --show-toplevel)"
BASELINE="${1:-tool/dcm-baseline.json}"
if [ "${1:-}" = "--update" ]; then BASELINE=tool/dcm-baseline.json; UPDATE=1; else UPDATE=0; fi

# THE BASELINE A PR IS MEASURED AGAINST MUST NOT BE ONE THE PR CAN EDIT.
# Same hole, same fix as tool/coverage_ratchet.sh -- see the long comment there.
# `--update` rewrites this file and exits 0, so a lowered baseline committed
# next to the regression it excuses passes CI. Reading the COMPARISON copy from
# the base branch means a PR cannot lower its own bar; the baseline it ships
# governs the next PR instead. RATCHET_BASE_REF unset (every local run) is
# unchanged behaviour.
if [ -n "${RATCHET_BASE_REF:-}" ] && [ "$UPDATE" = "0" ]; then
  # THE REF ITSELF MUST RESOLVE FIRST, or a failed fetch is indistinguishable
  # from "this PR introduces the baseline" and we silently compare the PR
  # against its own copy. Full reasoning in tool/coverage_ratchet.sh.
  if ! git rev-parse --verify --quiet "${RATCHET_BASE_REF}^{commit}" >/dev/null; then
    echo "FAIL: RATCHET_BASE_REF=${RATCHET_BASE_REF} does not resolve."
    echo "  The baseline a PR is measured against must come from the BASE branch,"
    echo "  and that ref is not present in this checkout. Refusing to fall back to"
    echo "  the working copy: falling back silently would report PASS while"
    echo "  measuring the PR against itself."
    echo "  Fix the fetch (CI: git fetch --no-tags --depth=1 origin \$GITHUB_BASE_REF),"
    echo "  or unset RATCHET_BASE_REF to run without a base comparison."
    exit 1
  fi
  BASE_COPY="$(mktemp)"
  if git show "${RATCHET_BASE_REF}:${BASELINE}" > "$BASE_COPY" 2>/dev/null; then
    # ...but ONLY if it was produced by the same dcm. A ratchet compares
    # per-rule counts, so a different analyzer version silently changes the
    # thing being compared -- the exact hazard the version pin below exists
    # for. A PR that legitimately bumps dcm AND regenerates the baseline would
    # otherwise be measured against the OLD baseline with the NEW analyzer,
    # which is a cross-version comparison this file already warns about.
    BASE_V=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('_dcm_version',''))" "$BASE_COPY" 2>/dev/null)
    CUR_V=$(python3 -c "import json;print(json.load(open('tool/dcm-baseline.json')).get('_dcm_version',''))" 2>/dev/null)
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
# caller opts in explicitly (local runs on a machine without dcm); anywhere the
# ratchet is relied upon — CI above all — a missing dcm must FAIL, because the
# alternative is a green tick that checked nothing.
if ! command -v dcm >/dev/null 2>&1; then
  if [ "${DCM_RATCHET_ALLOW_MISSING:-0}" = "1" ]; then
    echo "dcm not installed — SKIPPING (DCM_RATCHET_ALLOW_MISSING=1)"
    exit 77
  fi
  echo "FAIL: dcm is not installed, so the ratchet cannot run."
  echo "  Install:  brew tap CQLabs/dcm && brew install dcm"
  echo "  Note dcm is NOT a pub package — 'dart pub global activate dcm' does"
  echo "  not work. To skip deliberately on a machine without it:"
  echo "    DCM_RATCHET_ALLOW_MISSING=1 bash tool/dcm_ratchet.sh"
  exit 1
fi

# The baseline is only meaningful against the dcm that produced it: a different
# version reports different counts, so a cross-version comparison compares two
# different things and the ratchet reports noise as signal. CI floated to 1.38.3
# against a 1.37.0 baseline and the gate died parsing the output.
HAVE_V=$(dcm --version 2>&1 | tr -d '\r' | awk '{print $NF}')
WANT_V=$(python3 -c "import json;print(json.load(open('tool/dcm-baseline.json')).get('_dcm_version',''))" 2>/dev/null)
# `--update` MUST BE EXEMPT or the pin deadlocks: the mismatch message tells you
# to regenerate, and regeneration is what is being refused. Measured on the
# 1.37.0 -> 1.39.0 bump -- `--update` printed the same mismatch and changed
# nothing, so the baseline could never move forward.
if [ "$UPDATE" = "0" ] && [ -n "$WANT_V" ] && [ "$HAVE_V" != "$WANT_V" ]; then
  # THE DOCUMENTED OPT-OUT MUST REACH HERE, or this check is a DEADLOCK.
  # This test sits BEFORE the credentials test below, so when the baseline
  # version has drifted it fires first and DCM_RATCHET_ALLOW_MISSING
  # never got a chance to act. The only remedy it names is `--update`, and
  # regenerating runs dcm, which needs a licence. Measured 2026-09-17 with the
  # CI-key quota exhausted: metrics-baseline.json pinned 1.37.0, the host had
  # 1.39.0, and BOTH DCM_RATCHET_ALLOW_MISSING=1
  # and the advice dcm_host_gate.sh prints left it FAILING with no way out, so
  # `bash tool/dcm_host_gate.sh` could not go green by any means.
  #
  # A version mismatch means this check cannot compare anything meaningful --
  # which is exactly what the opt-out is for. It exits 77, so the gate records
  # SKIP "did not run, checked nothing" and it can never read as a pass.
  if [ "${DCM_RATCHET_ALLOW_MISSING:-0}" = "1" ]; then
    echo "dcm version mismatch (baseline $WANT_V, have $HAVE_V) — SKIPPING (DCM_RATCHET_ALLOW_MISSING=1)"
    echo "  This verified NOTHING. Regenerate with: bash tool/dcm_ratchet.sh --update"
    exit 77
  fi
  echo "FAIL: dcm version mismatch — baseline was generated by $WANT_V, this is $HAVE_V."
  echo "  Counts are not comparable across versions. Either install $WANT_V, or"
  echo "  bump the pin in .github/workflows/ci.yaml AND regenerate in the same"
  echo "  commit:  bash tool/dcm_ratchet.sh --update"
  exit 1
fi

TMP=$(mktemp)
ERR=$(mktemp)
# stderr is CAPTURED, not discarded. It used to go to /dev/null, so when `dcm`
# produced no usable JSON in CI the script died on a bare
# `json.decoder.JSONDecodeError` with the actual reason thrown away. A gate that
# hides why it failed is barely better than one that cannot fail.
# DCM is commercial. It runs unlicensed LOCALLY for the free rule tier, but on
# CI it refuses with "Both CI key and purchase email should be provided to run
# on CI." and exits 64 -- which is why this gate never ran there. Pass the
# credentials when present; stay unlicensed when not, so local use is unchanged.
#
# AND `CI=true` MUST BE SET, or the credentials are ignored. Measured
# 2026-09-14 with a valid CI key in a local container: `dcm analyze --ci-key=...
# --email=...` printed "DCM is not activated ... run dcm activate" and exited 1,
# while the SAME command with `CI=true` prefixed analysed 67 files and emitted
# JSON. dcm only consults the CI credentials when it believes it is on CI, so
# passing them without the flag is a no-op that reports an unrelated reason.
# This gate therefore could not pass locally even when correctly configured --
# it always looked like a missing licence rather than a missing env var.
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
if [ -z "${DCM_CI_KEY:-}" ] || [ -z "${DCM_EMAIL:-}" ]; then
  if [ "${DCM_RATCHET_ALLOW_MISSING:-0}" = "1" ]; then
    echo "DCM credentials absent — SKIPPING (DCM_RATCHET_ALLOW_MISSING=1)"
    exit 77
  fi
  echo "FAIL: DCM_CI_KEY and DCM_EMAIL are not both set, so dcm cannot run."
  echo "  dcm only consults them when it believes it is on CI, so CI=true is"
  echo "  set alongside them, not instead of them."
  echo "    export DCM_CI_KEY=...   # the CI key, NOT a license-key"
  echo "    export DCM_EMAIL=...    # the purchase email"
  echo "  The key also has a MONTHLY RUN BUDGET. When it is exhausted dcm fails"
  echo "  with 'CI key limit for this month has been exceeded' and no DCM check"
  echo "  can run until it resets. To gate through that, knowing these steps"
  echo "  then verify nothing:"
  echo "    DCM_RATCHET_ALLOW_MISSING=1 bash tool/gate.sh"
  exit 1
fi

DCM_AUTH=()
DCM_CI_ENV=()
if [ -n "${DCM_CI_KEY:-}" ] && [ -n "${DCM_EMAIL:-}" ]; then
  DCM_AUTH=(--ci-key="$DCM_CI_KEY" --email="$DCM_EMAIL")
  DCM_CI_ENV=(env CI=true)
fi
"${DCM_CI_ENV[@]}" dcm analyze lib test --reporter=json "${DCM_AUTH[@]}" > "$TMP" 2>"$ERR"
DCM_RC=$?

if [ ! -s "$TMP" ] || ! python3 -c "import json,sys;json.load(open(sys.argv[1]))" "$TMP" 2>/dev/null; then
  echo "FAIL: \`dcm analyze --reporter=json\` produced no parseable JSON (exit $DCM_RC)."
  echo "  This is the gate failing to RUN, which is not the same as the gate passing."
  echo "  dcm version: $(dcm --version 2>&1 | head -1)"
  echo "  --- first 20 lines of stdout ---"
  head -20 "$TMP" | sed 's/^/    /'
  echo "  --- first 20 lines of stderr ---"
  head -20 "$ERR" | sed 's/^/    /'
  echo
  echo "  If stderr mentions a CI key: DCM is commercial and will not run on CI"
  echo "  unlicensed. Set DCM_CI_KEY and DCM_EMAIL in the environment (both"
  echo "  already exist as repository secrets)."
  rm -f "$TMP" "$ERR"
  exit 1
fi
rm -f "$ERR"

BASELINE="$BASELINE" UPDATE="$UPDATE" TMP="$TMP" python3 - <<'PY'
import json, os, sys, collections

tmp = os.environ['TMP']
baseline_path = os.environ['BASELINE']
update = os.environ['UPDATE'] == '1'

d = json.load(open(tmp))
rules, files = collections.Counter(), collections.Counter()
for r in d['analyzeResults']:
    for iss in r.get('issues', []):
        rules[iss['id']] += 1
        files[r['path']] += 1
current = {'total': sum(rules.values()), 'by_rule': dict(rules), 'by_file': dict(files)}

if update:
    json.dump(current, open(baseline_path, 'w'), indent=2, sort_keys=True)
    print(f"baseline updated: {current['total']} issues, {len(rules)} rules, {len(files)} files")
    sys.exit(0)

if not os.path.exists(baseline_path):
    print(f"FAIL: no baseline at {baseline_path} — run: bash tool/dcm_ratchet.sh --update")
    sys.exit(1)

base = json.load(open(baseline_path))
bt, br, bf = base['total'], base['by_rule'], base['by_file']

# THE BASELINE MUST BE INTERNALLY CONSISTENT, or every check below it is
# reasoning about a number nobody produced. MEASURED while falsifying this
# file: hand-editing `total` to 170 while by_rule still summed to 171 reported
# PASS -- the per-rule and per-file checks were all satisfied, and the TOTAL
# was never compared to anything. A baseline that lies is worse than a high
# one, because the gate agrees with it.
if bt != sum(br.values()):
    print(f"FATAL: {baseline_path} is inconsistent -- total {bt} but by_rule "
          f"sums to {sum(br.values())}. Regenerate it: "
          f"bash tool/dcm_ratchet.sh --update")
    sys.exit(2)

violations = []

for rule, n in sorted(rules.items()):
    prev = br.get(rule, 0)
    if prev == 0:
        violations.append(f"NEW RULE      {rule}: {n} issue(s)")
    elif n > prev:
        violations.append(f"RULE INCREASE {rule}: {prev} -> {n}")

for path, n in sorted(files.items()):
    prev = bf.get(path, 0)
    if prev == 0:
        violations.append(f"NEW FILE      {path}: {n} issue(s)")
    elif n > prev:
        violations.append(f"FILE INCREASE {path}: {prev} -> {n}")

print(f"dcm: {current['total']} issues vs baseline {bt}  "
      f"({len(rules)} rules / {len(files)} files vs {len(br)} / {len(bf)})")

if violations:
    print(f"\nFAIL — {len(violations)} ratchet violation(s):")
    for v in violations:
        print(f"  {v}")
    print("\nFix them, or if intentional: bash tool/dcm_ratchet.sh --update")
    sys.exit(1)

# A RATCHET THAT ONLY CLICKS ONE WAY IS NOT A RATCHET.
#
# This used to print "PASS — and N fewer than baseline. Consider: --update"
# and exit 0. So an improvement was never CAPTURED: the baseline stayed where
# it was, and the count could drift straight back up to it with the gate still
# green. It blocked going above the number and permitted everything below --
# which is how 171 issues sat unchanged while every run reported PASS.
#
# Now a drop FAILS, with the fix being to lower the baseline in the same
# commit. That makes progress permanent: whatever you fixed can never come
# back without a new violation.
if current['total'] < bt:
    print(f"\nFAIL — {bt - current['total']} FEWER issues than the baseline.")
    print("  That is good news, and it has to be recorded or it is not kept:")
    print("  a baseline left high lets these exact issues return with the gate")
    print("  still green. Lower it IN THIS COMMIT:")
    print("      bash tool/dcm_ratchet.sh --update")
    sys.exit(1)

print("PASS — no new issues above baseline")
PY
rc=$?
rm -f "$TMP"
exit $rc
