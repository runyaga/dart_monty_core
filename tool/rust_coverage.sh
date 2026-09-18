#!/usr/bin/env bash
# =============================================================================
# Rust line coverage, unioned across test binaries by FILE AND LINE.
# =============================================================================
# A single `cargo llvm-cov` invocation UNDERSTATES this crate, badly:
#
#     cargo llvm-cov --summary-only      lib.rs   2.23%    TOTAL 71.02%
#     cargo llvm-cov --test integration  lib.rs  36.50%    TOTAL 34.54%
#     cargo llvm-cov --lib               lib.rs   0.00%    TOTAL 70.34%
#
# Coverage is a union, so adding a test binary cannot LOWER a file's number.
# Here it does: lib.rs reads 2.23% combined and 36.50% from one binary alone.
#
# CAUSE, confirmed 2026-09-14 from the llvm-cov JSON report. lib.rs holds 63
# `#[unsafe(no_mangle)] pub extern "C"` functions. #[no_mangle] strips the hash
# disambiguator, so `monty_create` in the unit-test binary (compiled under
# cfg(test)) and `monty_create` in the integration binary are the SAME LLVM
# symbol name with DIFFERENT bodies. llvm-cov deduplicates by symbol, keeps one
# mapping, finds zero hits against it, and orphans the other binary's real hits.
#
# PROOF: in the combined run the only lib.rs functions with count>0 are mangled
# INNER CLOSURES -- `_RNCNvCs...monty_create0B3_`, 17 of them -- which keep
# their disambiguators and therefore union correctly. The bare `monty_create`
# symbol does not appear in the hit list at all. Ordinary Rust functions
# elsewhere (convert.rs 88.72%, repl_handle.rs 90.11%) are unaffected for
# exactly this reason: they still carry hashes.
#
# FIX: run each target SEPARATELY, export LCOV from each, union by file:line.
# Line numbers cannot collide the way symbol names do.
#
# Usage: bash tool/rust_coverage.sh [--summary] [--fail-under N]
# =============================================================================
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG/native"

FAIL_UNDER=""
SUMMARY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --summary)    SUMMARY=1; shift ;;
    --fail-under) FAIL_UNDER="${2:?--fail-under needs a number}"; shift 2 ;;
    *) echo "FAIL: unknown option $1" >&2; exit 2 ;;
  esac
done

command -v cargo-llvm-cov >/dev/null 2>&1 || {
  echo "FAIL: cargo-llvm-cov is not installed."
  echo "  It ships in the devtools image. Locally:"
  echo "    rustup component add llvm-tools-preview && cargo install cargo-llvm-cov --locked"
  exit 1
}

OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

IGNORE='src/bin/'

# Each target gets its OWN profile directory. Sharing one is the bug.
run_target() {
  local name="$1"; shift
  cargo llvm-cov clean --workspace >/dev/null 2>&1
  if ! cargo llvm-cov "$@" --lcov --output-path "$OUT/$name.info" \
        --ignore-filename-regex "$IGNORE" >"$OUT/$name.log" 2>&1; then
    echo "FAIL: coverage run '$name' did not complete. Tail of its output:"
    tail -30 "$OUT/$name.log"
    exit 1
  fi
  [ -s "$OUT/$name.info" ] || { echo "FAIL: '$name' produced an empty tracefile."; exit 1; }
}

run_target lib         --lib
run_target integration --test integration

# DERIVE the roots from the tracefiles; do not guess them.
#
# The same source file appears under more than one absolute root because the
# tree is bind-mounted and an rlib compiled on the host keeps the path it was
# compiled with. An earlier version hardcoded the candidates, which failed the
# moment it ran somewhere with a different $HOME: inside the container $HOME is
# /home/klangk, so the macOS spelling /Users/runyaga/... never matched and the
# paths stayed split -- 51.27% against a 74% floor, a false red.
#
# A prefix is accepted as a root ONLY if EVERY ONE of this crate's source files
# appears beneath it in the tracefiles. One shared filename is a coincidence;
# the complete set is this package. That is what stops a dependency's own
# native/src/lib.rs from being mistaken for ours and merged into it.
# Same exclusion as the coverage runs themselves ($IGNORE): a source the runs
# never instrument cannot appear in a tracefile, and requiring it here would
# reject every candidate root. These two must not drift apart.
mapfile -t SRC_FILES < <(cd "$PKG" && find native/src -name '*.rs' | grep -vE "$IGNORE" | sort)
[ "${#SRC_FILES[@]}" -gt 0 ] || { echo "FAIL: no native/src/*.rs found under $PKG."; exit 1; }

ROOTS=()
while read -r prefix; do
  [ -n "$prefix" ] || continue
  all=1
  for f in "${SRC_FILES[@]}"; do
    grep -qF "SF:$prefix/$f" "$OUT/lib.info" "$OUT/integration.info" || { all=0; break; }
  done
  [ "$all" = "1" ] && ROOTS+=(--root "$prefix")
done < <(grep -h '^SF:' "$OUT/lib.info" "$OUT/integration.info" \
         | sed 's|^SF:||' | grep -oE '^.*(?=/native/src/)' -P 2>/dev/null \
         | sort -u || true)

# Fallback for greps without -P: strip the suffix textually.
if [ "${#ROOTS[@]}" -eq 0 ]; then
  while read -r prefix; do
    [ -n "$prefix" ] || continue
    all=1
    for f in "${SRC_FILES[@]}"; do
      grep -qF "SF:$prefix/$f" "$OUT/lib.info" "$OUT/integration.info" || { all=0; break; }
    done
    [ "$all" = "1" ] && ROOTS+=(--root "$prefix")
  done < <(grep -h '^SF:' "$OUT/lib.info" "$OUT/integration.info" \
           | sed 's|^SF:||; s|/native/src/.*$||' | sort -u)
fi

[ "${#ROOTS[@]}" -gt 0 ] || { echo "FAIL: no source root matched all ${#SRC_FILES[@]} crate sources."; exit 1; }
printf "source roots:"; for r in "${ROOTS[@]}"; do [ "$r" = "--root" ] || printf " %s" "$r"; done; echo

read -r HIT FOUND PCT < <(python3 "$PKG/tool/lcov_union.py" "${ROOTS[@]}" \
  "$OUT/merged.info" "$OUT/lib.info" "$OUT/integration.info")

[ -n "${PCT:-}" ] || { echo "FAIL: the union produced no percentage."; exit 1; }

# A union cannot be smaller than its largest input. If it is, the merge is
# broken -- which is the exact failure this script exists to correct, so it
# must not be able to reintroduce it silently.
for t in lib integration; do
  # stderr silenced: the duplicate-path warning is real, but the main union
  # above already printed it. Repeating it once per solo check is noise.
  read -r _ _ SOLO < <(python3 "$PKG/tool/lcov_union.py" "${ROOTS[@]}" \
    "$OUT/solo.info" "$OUT/$t.info" 2>/dev/null)
  if awk -v u="$PCT" -v s="$SOLO" 'BEGIN{exit !(u < s - 0.01)}'; then
    echo "FAIL: union (${PCT}%) is BELOW '$t' alone (${SOLO}%). The merge is wrong."
    exit 1
  fi
done

if [ "$SUMMARY" = "1" ]; then
  python3 - "$OUT/merged.info" <<'PY'
import sys
from collections import defaultdict
per = defaultdict(lambda: [0, 0])
cur = None
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if line.startswith("SF:"):
        cur = line[3:]
    elif line.startswith("DA:") and cur:
        _, _, c = line[3:].partition(",")
        per[cur][1] += 1
        per[cur][0] += 1 if int(c) > 0 else 0
print(f"{'file':<34}{'hit':>8}{'lines':>8}{'pct':>9}")
for sf in sorted(per):
    hit, found = per[sf]
    name = sf.split("/native/")[-1]
    print(f"{name:<34}{hit:>8}{found:>8}{100.0*hit/found:>8.2f}%")
PY
fi

echo "Rust line coverage, unioned across targets: ${PCT}%  (${HIT}/${FOUND} lines)"

if [ -n "$FAIL_UNDER" ]; then
  if awk -v p="$PCT" -v f="$FAIL_UNDER" 'BEGIN{exit !(p < f)}'; then
    echo "FAIL: ${PCT}% is below the ${FAIL_UNDER}% floor."
    exit 1
  fi
  echo "PASS: ${PCT}% >= ${FAIL_UNDER}%"
fi
