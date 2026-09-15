#!/usr/bin/env bash
# =============================================================================
# WIRE-CONTRACT.md must exist, be cited truthfully, and match the code.
# =============================================================================
# Ten sites across Rust, Dart and the tests cite this document as normative —
# including test/integration/_wire_contract_test_body.dart, which prints
# "WIRE-CONTRACT.md row N requires ..." when it fails. The document DID NOT
# EXIST. A developer hitting that failure was told to consult something nobody
# had written.
#
# The risk in fixing that is fabrication: a plausible spec that does not match
# the encoder is WORSE than no spec, because the tests cite it as authority. So
# the document is DERIVED — its row table comes from the executed assertions in
# the test body — and this gate keeps it derived.
#
# Three directions, all required:
#   1. every `rule RN` cited in the code has a section here
#   2. every row in the document exists in the test body   (catches invention)
#   3. every row in the test body exists in the document   (catches omission)
#
# Direction 3 was added after review pointed out that 1+2 catch fabrication and
# nothing catches a silently incomplete document — the same shape as a corpus
# that reports green having lost a fixture.
#
# Usage: bash tool/check_wire_contract.sh
# =============================================================================
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

DOC=docs/WIRE-CONTRACT.md
BODY=test/integration/_wire_contract_test_body.dart

if [ ! -f "$DOC" ]; then
  echo "FAIL: $DOC does not exist, and $(grep -rl 'WIRE-CONTRACT' lib native/src test 2>/dev/null | wc -l | tr -d ' ') files cite it."
  exit 1
fi
[ -f "$BODY" ] || { echo "FATAL: $BODY is missing"; exit 2; }

rc=0

# --- 1. cited rules must be documented -------------------------------------
CITED=$(grep -rhoE 'rule R[0-9]+' lib native/src test 2>/dev/null \
  | grep -oE 'R[0-9]+' | sort -u || true)
for r in $CITED; do
  grep -qE "^### $r " "$DOC" || {
    echo "FAIL: the code cites '$r' and $DOC has no '### $r' section."
    rc=1
  }
done

# --- 2 & 3. the row table must match the executed rows ----------------------
python3 - "$DOC" "$BODY" <<'PYEOF'
import re, sys
doc  = open(sys.argv[1]).read()
body = open(sys.argv[2]).read()

executed = set()
for num, code, tag in re.findall(r"_Row\((\d+),\s*'((?:[^'\\]|\\.)*)',\s*'([a-z_]+)'", body):
    executed.add((int(num), code.replace('\\n', ' ; '), tag))

documented = set()
for num, code, tag in re.findall(r'^\|\s*(\d+)\s*\|\s*`(.*?)`\s*\|\s*`([a-z_]+)`\s*\|', doc, re.M):
    documented.add((int(num), code, tag))

invented = documented - executed
omitted  = executed - documented
bad = False
if invented:
    print("FAIL: rows documented that NO test executes (invented):")
    for n, c, t in sorted(invented):
        print(f"  row {n}: {c!r} -> {t}")
    bad = True
if omitted:
    print("FAIL: rows the tests execute that the document omits:")
    for n, c, t in sorted(omitted):
        print(f"  row {n}: {c!r} -> {t}")
    bad = True
if bad:
    print("")
    print("  The row table is DERIVED from the test body. Regenerate it rather")
    print("  than hand-editing: if a row disagrees with the test, the test wins.")
    sys.exit(1)
print(f"  {len(documented)} rows match the executed assertions exactly.")
PYEOF
[ $? -eq 0 ] || rc=1

[ "$rc" -eq 0 ] || exit 1
echo "PASS — WIRE-CONTRACT.md exists, its cited rules are documented, and its rows match the tests."
