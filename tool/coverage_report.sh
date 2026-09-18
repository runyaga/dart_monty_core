#!/usr/bin/env bash
# =============================================================================
# tool/coverage_report.sh — the HONEST coverage tracefile
# =============================================================================
# Dart's coverage collector reports only libraries that were actually LOADED
# into the measured isolate. `format_coverage --report-on=lib` filters what was
# collected; it cannot add a file nobody imported. So a file no test touches is
# not 0% — it is ABSENT, and its lines never enter the denominator at all.
#
# Measured on this repo at 1e12e1c, before this script existed:
#   46 of lib/'s 68 .dart files appear in coverage/lcov.info. 22 do not.
#   The reported project number was 1233/3065 = 40.2%.
# That number is gameable in the wrong direction: DELETING an import RAISES it.
# The repo already half-knew this — ci.yaml's patch gate carries
# `--ignore-errors unused` with the comment "A file the unit tests never import
# has no entry in the tracefile" — but the consequence for the DENOMINATOR was
# never drawn.
#
# This script draws it. It emits a ZERO BASELINE covering every lib/**/*.dart
# and merges it UNDER the real tracefiles, so unloaded files enter at 0 instead
# of vanishing. THE REPORTED NUMBER GOES DOWN. That is the point, not a
# regression.
#
# HOW THE BASELINE GETS ITS LINE NUMBERS — this is the part that matters.
# It does NOT guess. It generates a throwaway Dart program that IMPORTS every
# lib file, runs it under the VM service, and collects coverage with
# `forceCompile`. The VM then reports every function in every imported library,
# all at zero hits, which is the collector's OWN notion of a coverable line —
# the same notion the real tracefile uses. Cross-checked against the real unit
# tracefile: of 3065 DA records the unit run produced, 3063 appear in the
# anchor's line set (the 2 that do not are closures the VM compiles only on
# execution). So the baseline and the measurement agree about what a coverable
# line is, and merging them is a union, not a reconciliation.
#
# Usage:
#   bash tool/coverage_report.sh [--out-dir DIR] INPUT [INPUT...]
#
# An INPUT is either an LCOV tracefile or a directory of `dart test --coverage`
# hitmap JSON, which is formatted here. Taking the raw hitmap directly is the
# preferred form locally: `dart test --coverage=DIR` from several suites can
# write into ONE directory and format_coverage unions them, with no LCOV merge
# and none of the absolute-path fragility an `lcov -a` merge has.
#
# Writes:
#   DIR/merged.info  — union of the inputs, exclusions removed. REAL lines only,
#                      no synthesised records. This is what diff-cover gets.
#   DIR/honest.info  — merged.info + the zero baseline. Every lib file present.
#                      This is what the coverage ratchet and humans get.
#
# Exits non-zero if any input is missing or empty, if the anchor fails to run,
# or if honest.info does not account for exactly the expected set of files.
# There is no `|| true` anywhere in here on purpose: a coverage report that
# cannot fail is a number nobody should quote.
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

OUT_DIR=coverage
# A precomputed zero baseline (a previous run's anchor.info). The anchor needs a
# Dart SDK and a native build; a job that only merges tracefiles has neither and
# should not grow them just to re-derive a file both jobs agree on. Passing it
# skips the anchor run -- and ONLY that: the per-file accounting and the
# every-lib-file assertion still run, so a stale baseline shows up as a missing
# file rather than as a quietly smaller denominator.
BASELINE=""
INPUTS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --baseline) BASELINE="$2"; shift 2 ;;
    -h|--help) sed -n '2,54p' "$0"; exit 0 ;;
    -*) echo "FAIL: unknown option $1" >&2; exit 2 ;;
    *) INPUTS+=("$1"); shift ;;
  esac
done

if [ ${#INPUTS[@]} -eq 0 ]; then
  echo "FAIL: no input tracefiles given."
  echo "  Usage: bash tool/coverage_report.sh [--out-dir DIR] TRACEFILE..."
  exit 2
fi

# An empty tracefile is the failure mode this repo has already been bitten by:
# core#130, where a wrong glob meant `format_coverage` wrote an EMPTY lcov every
# run and the 70% patch gate short-circuited to exit 0 for months. Treat an
# empty input as a hard failure, never as "0% coverage".
for f in "${INPUTS[@]}"; do
  if [ -d "$f" ]; then
    if [ -z "$(find "$f" -name '*.json' -print -quit)" ]; then
      echo "FAIL: input directory '$f' holds no coverage hitmap JSON."
      echo "  This is the report failing to RUN, which is not the same as 0%."
      echo "  A \`dart test --coverage=$f\` that registered zero tests looks"
      echo "  exactly like this and exits 0 — check the suite, not this script."
      exit 1
    fi
  elif [ ! -s "$f" ]; then
    echo "FAIL: input tracefile '$f' is missing or empty."
    echo "  This is the report failing to RUN, which is not the same as 0%."
    exit 1
  fi
done

# -----------------------------------------------------------------------------
# Exclusions. Two, both documented, both with a reason that is not "it is red".
#
#   lib/src/ffi/generated/**            ffigen output. Regenerated from
#                                       native/ on every CI run; testing it
#                                       tests ffigen. The patch gate at
#                                       ci.yaml already removes it.
#   lib/src/platform/mock_monty_platform.dart
#                                       363 lines of TEST SCAFFOLDING that
#                                       happens to ship in lib/. Covering it
#                                       would add ~71 lines of "coverage" and
#                                       zero confidence.
#
# Anything else stays in, including the files that can never be covered by a VM
# run. Hiding an uncoverable file is the same lie as losing an unloaded one.
# -----------------------------------------------------------------------------
EXCLUDE=(
  'lib/src/ffi/generated/'
  'lib/src/platform/mock_monty_platform.dart'
)

# -----------------------------------------------------------------------------
# Files the Dart VM cannot load AT ALL, so the anchor cannot ask the VM for
# their coverable lines. Both are browser-only: they resolve `.toJS` extension
# members from dart:js_interop, which do not exist off the web.
#
# The list is VERIFIED, not asserted — see the "vm_unloadable is still true"
# step below, which compiles each one alone and requires it to FAIL. A stale
# entry (the file became VM-loadable) is therefore caught, and so is the
# opposite (a NEW browser-only file), because the main anchor then fails to
# compile and this script exits 1 with the compiler's own message.
# -----------------------------------------------------------------------------
VM_UNLOADABLE=(
  'lib/src/wasm/wasm_bindings_js.dart'
  'lib/src/repl/repl_factory_web.dart'
)

READY_SENTINEL='coverage-anchor-compiled-and-ran'
if [ -n "$BASELINE" ] && [ ! -s "$BASELINE" ]; then
  echo "FAIL: --baseline '$BASELINE' is missing or empty."
  echo "  Without it every unloaded lib/ file silently leaves the denominator,"
  echo "  which is the exact defect this script exists to remove. Produce one"
  echo "  with a plain run of this script (it writes <out-dir>/anchor.info)."
  exit 1
fi

ANCHOR_DIR=.dart_tool/coverage_anchor
rm -rf "$ANCHOR_DIR"
mkdir -p "$ANCHOR_DIR/hitmap" "$OUT_DIR"

# `part of` files cannot be imported directly, and do not need to be: importing
# the library they are part of pulls them in and the collector still reports
# them under their OWN path. All four of monty_value_{scalars,collections,
# datetime,structured}.dart arrive this way.
mapfile -t ANCHOR_FILES < <(
  find lib -name '*.dart' \
    | grep -v '^lib/src/ffi/generated/' \
    | grep -v 'mock_monty_platform\.dart$' \
    | grep -vF -f <(printf '%s\n' "${VM_UNLOADABLE[@]}") \
    | xargs grep -L '^part of' \
    | sort
)

# MAIN() MUST STAY EMPTY, and that is a SAFETY invariant, not a style choice.
#
# This anchor runs BACKGROUNDED (:197) and is still alive when
# `dart run coverage:collect_coverage` starts (:226) -- it has to be, since
# collect_coverage attaches to its VM service. So two `dart` processes are live
# in the package root at once, and EVERY `dart run` re-bundles native assets,
# rewriting `.dart_tool/lib/libdart_monty_core_native.so` IN PLACE with an
# O_TRUNC copy (measured: same inode, new mtime, every invocation).
#
# Truncating a `dlopen`ed library is legal on Linux -- ETXTBSY guards only the
# running executable -- and the holder's next page touch dies with
# SIGBUS/BUS_ADRERR. Today the anchor is safe because importing a library does
# NOT dlopen it; only an FFI CALL does, and main() is empty (measured: 19 mapped
# .so in the anchor process, none of them ours).
#
# So: import freely, never CALL. If this ever executes an FFI function, the
# concurrent truncation at :226 becomes an intermittent SIGBUS that reproduces
# only under load. core#161; the real fix is upstream (dartbug.com/59668).
write_anchor() {  # $1 = output path, $2.. = lib/ paths to import
  local out="$1"; shift
  {
    echo '// GENERATED by tool/coverage_report.sh — do not edit, do not commit.'
    echo '// Imports every lib/ library so the VM will report its coverable'
    echo '// lines. Never executed for its behaviour; main() is empty.'
    echo '// ignore_for_file: unused_import, directives_ordering'
    echo '// ignore_for_file: lines_longer_than_80_chars, document_ignores'
    printf '%s\n' "$@" | sed "s|^lib/|import 'package:dart_monty_core/|; s|\$|';|"
    # The sentinel is load-bearing. `dart run --enable-vm-service` prints
    # "The Dart VM service is listening on ..." BEFORE it compiles the program,
    # so a URI in the log proves nothing: measured, an anchor that fails to
    # compile still advertises a service, and `collect_coverage --wait-paused`
    # then blocks forever on an isolate that will never pause. Waiting for a
    # line main() itself printed is the only signal that means "it compiled and
    # it ran".
    echo "void main() { print('$READY_SENTINEL'); }"
  } > "$out"
}

write_anchor "$ANCHOR_DIR/anchor.dart" "${ANCHOR_FILES[@]}"

# ---- run the anchor under the VM service and collect --------------------------
# Everything between here and the matching `fi` is the anchor run, skipped
# wholesale when --baseline hands us one that was produced earlier.
if [ -n "$BASELINE" ]; then
  cp "$BASELINE" "$ANCHOR_DIR/anchor.info"
else
# Port 0 = let the OS choose, then read the real URI back out of the log. A
# hard-coded port makes this script fight any other VM service on the machine,
# including a second copy of itself.
dart run --pause-isolates-on-exit --enable-vm-service=0/127.0.0.1 \
  --disable-service-auth-codes "$ANCHOR_DIR/anchor.dart" \
  > "$ANCHOR_DIR/run.log" 2>&1 &
ANCHOR_PID=$!

READY=0
for _ in $(seq 1 300); do
  if grep -q "$READY_SENTINEL" "$ANCHOR_DIR/run.log" 2>/dev/null; then READY=1; break; fi
  kill -0 "$ANCHOR_PID" 2>/dev/null || break
  sleep 1
done
URI=$(grep -om1 'http://127\.0\.0\.1:[0-9]*/' "$ANCHOR_DIR/run.log" || true)

if [ "$READY" -ne 1 ] || [ -z "$URI" ]; then
  kill "$ANCHOR_PID" 2>/dev/null
  wait "$ANCHOR_PID" 2>/dev/null; rc=$?
  echo "FAIL: the coverage anchor did not compile and run (exit $rc)."
  echo "  Every lib/ library is imported by .dart_tool/coverage_anchor/anchor.dart."
  echo "  A compile error below means a lib/ file is NOT VM-loadable and must be"
  echo "  added to VM_UNLOADABLE in this script, with a reason. Do not delete the"
  echo "  file from the anchor any other way: an unmeasurable file still belongs"
  echo "  in the denominator."
  echo "  --- anchor output ---"
  sed 's/^/    /' "$ANCHOR_DIR/run.log"
  exit 1
fi

# Watchdog, in bash rather than `timeout(1)`, because coreutils' timeout is not
# on a stock macOS and this gate has to be runnable everywhere gate.sh is.
dart run coverage:collect_coverage --uri="$URI" \
  -o "$ANCHOR_DIR/hitmap/anchor.json" --resume-isolates --wait-paused \
  > "$ANCHOR_DIR/collect.log" 2>&1 &
COLLECT_PID=$!
for _ in $(seq 1 300); do
  kill -0 "$COLLECT_PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$COLLECT_PID" 2>/dev/null; then
  echo "FAIL: collect_coverage did not finish within 300s; killing it."
  kill "$COLLECT_PID" "$ANCHOR_PID" 2>/dev/null
  sed 's/^/    /' "$ANCHOR_DIR/collect.log"
  exit 1
fi
wait "$COLLECT_PID"; COLLECT_RC=$?
wait "$ANCHOR_PID"; ANCHOR_RC=$?

if [ $COLLECT_RC -ne 0 ] || [ $ANCHOR_RC -ne 0 ] || [ ! -s "$ANCHOR_DIR/hitmap/anchor.json" ]; then
  echo "FAIL: coverage collection from the anchor isolate failed"
  echo "  (collect exit $COLLECT_RC, anchor exit $ANCHOR_RC)."
  sed 's/^/    /' "$ANCHOR_DIR/collect.log"
  sed 's/^/    /' "$ANCHOR_DIR/run.log"
  exit 1
fi

dart run coverage:format_coverage --lcov --in="$ANCHOR_DIR/hitmap" \
  --out="$ANCHOR_DIR/anchor.info" --report-on=lib --package=. \
  > "$ANCHOR_DIR/format.log" 2>&1
if [ ! -s "$ANCHOR_DIR/anchor.info" ]; then
  echo "FAIL: format_coverage produced no baseline tracefile."
  sed 's/^/    /' "$ANCHOR_DIR/format.log"
  exit 1
fi

# ---- the VM_UNLOADABLE list is CHECKED, not believed ---------------------------
# Each listed file is compiled on its own and must FAIL. Without this the list
# is a comment: a file could become VM-loadable (or be renamed) and we would
# keep feeding it synthesised line numbers forever, which is precisely the
# fabricated-denominator problem this script exists to remove.
for f in "${VM_UNLOADABLE[@]}"; do
  if [ ! -f "$f" ]; then
    echo "FAIL: VM_UNLOADABLE lists '$f', which does not exist. Update the list."
    exit 1
  fi
  write_anchor "$ANCHOR_DIR/probe.dart" "$f"
  if dart run "$ANCHOR_DIR/probe.dart" > "$ANCHOR_DIR/probe.log" 2>&1; then
    echo "FAIL: VM_UNLOADABLE lists '$f', but it loads on the VM just fine."
    echo "  Remove it from the list — the anchor can measure its real coverable"
    echo "  lines, and synthesising them instead understates coverage."
    exit 1
  fi
done
rm -f "$ANCHOR_DIR/probe.dart" "$ANCHOR_DIR/probe.log"
fi  # end of the anchor run

# ---- hitmap directories become tracefiles -------------------------------------
ORIG_INPUTS="$(printf '%s\n' "${INPUTS[@]}")"
RESOLVED=()
i=0
for f in "${INPUTS[@]}"; do
  if [ -d "$f" ]; then
    lcov="$ANCHOR_DIR/in-$i.info"
    dart run coverage:format_coverage --lcov --in="$f" --out="$lcov" \
      --report-on=lib --package=. > "$ANCHOR_DIR/format-in-$i.log" 2>&1
    if [ ! -s "$lcov" ]; then
      echo "FAIL: format_coverage produced nothing from hitmap dir '$f'."
      sed 's/^/    /' "$ANCHOR_DIR/format-in-$i.log"
      exit 1
    fi
    RESOLVED+=("$lcov")
  else
    RESOLVED+=("$f")
  fi
  i=$((i + 1))
done
INPUTS=("${RESOLVED[@]}")

# -----------------------------------------------------------------------------
OUT_DIR="$OUT_DIR" ANCHOR="$ANCHOR_DIR/anchor.info" \
EXCLUDE="$(printf '%s\n' "${EXCLUDE[@]}")" \
UNLOADABLE="$(printf '%s\n' "${VM_UNLOADABLE[@]}")" \
INPUTS="$(printf '%s\n' "${INPUTS[@]}")" ORIG_INPUTS="$ORIG_INPUTS" \
python3 - <<'PY'
import os, re, shutil, sys

root = os.getcwd()
out_dir = os.environ['OUT_DIR']
exclude = [e for e in os.environ['EXCLUDE'].split('\n') if e]
unloadable = [e for e in os.environ['UNLOADABLE'].split('\n') if e]
inputs = [e for e in os.environ['INPUTS'].split('\n') if e]
named = [e for e in os.environ['ORIG_INPUTS'].split('\n') if e]


def rel(p):
    return os.path.relpath(os.path.realpath(p), root)


def parse(path):
    """LCOV -> {relative source path: {line: hits}}. Hits are SUMMED."""
    out, sf = {}, None
    for raw in open(path):
        line = raw.strip()
        if line.startswith('SF:'):
            sf = rel(line[3:])
            out.setdefault(sf, {})
        elif line.startswith('DA:') and sf is not None:
            n, h = line[3:].split(',')[:2]
            n, h = int(n), int(h)
            out[sf][n] = out[sf].get(n, 0) + h
    return out


def excluded(path):
    return any(path.startswith(e) or path == e for e in exclude)


# --- the real measurement: union of every tracefile handed to us --------------
merged = {}
for path in inputs:
    for f, lines in parse(path).items():
        if excluded(f):
            continue
        tgt = merged.setdefault(f, {})
        for n, h in lines.items():
            tgt[n] = tgt.get(n, 0) + h

# --- the zero baseline: what the VM says is coverable, all at zero ------------
baseline = {f: {n: 0 for n in lines}
            for f, lines in parse(os.environ['ANCHOR']).items()
            if not excluded(f)}

# --- synthesised lines, for the files the VM cannot load ----------------------
# Every non-blank, non-comment, non-directive, non-declaration-header line
# counts. That OVER-counts: measured against the 55 files where the VM gives
# ground truth, this filter yields 5994 candidate lines against 3632 real ones,
# a factor of 1.65. The over-count is deliberate and is the conservative
# direction — it can only make the reported number LOWER, never flattering —
# and every line number emitted is a real line in the file, so diff-cover and a
# human reading the report both land somewhere meaningful. It is still an
# estimate: treat the honest percentage as a floor for these two files.
DECL = re.compile(r'^(abstract\s+|final\s+|base\s+|interface\s+|sealed\s+|'
                  r'mixin\s+|)(class|enum|extension|mixin|typedef)\b')
DIRECTIVE = re.compile(r'^(import|export|library|part)\b')
PUNCT = re.compile(r'^[\s{}()\[\];,]*$')


def synthesise(path):
    src = re.sub(r'/\*.*?\*/', '', open(path).read(), flags=re.S)
    lines = {}
    for i, raw in enumerate(src.split('\n'), start=1):
        s = re.sub(r'//.*$', '', raw).strip()
        if not s or s.startswith('@'):
            continue
        if DIRECTIVE.match(s) or DECL.match(s) or PUNCT.match(s):
            continue
        lines[i] = 0
    return lines


synth = {f: synthesise(f) for f in unloadable}

# --- every lib/ file, no exceptions -------------------------------------------
# The FILESYSTEM, not `git ls-files`: a file that exists is a file the anchor
# imports and the suites can load, tracked or not. Enumerating from the index
# would silently drop a brand-new source file — exactly the "absent, not 0%"
# hole this script exists to close, reintroduced one layer up.
all_lib = sorted(
    os.path.join(dirpath, name)
    for dirpath, _, names in os.walk('lib')
    for name in names
    if name.endswith('.dart') and not excluded(os.path.join(dirpath, name))
)

honest = {}
for f in all_lib:
    lines = dict(baseline.get(f) or synth.get(f) or {})
    for n, h in merged.get(f, {}).items():
        lines[n] = lines.get(n, 0) + h
    honest[f] = lines

# A file the real tracefile knows about but `git ls-files lib` does not is an
# untracked source file being measured. Say so rather than dropping it.
strays = sorted(set(merged) - set(honest))
if strays:
    print('FAIL: tracefile covers files that do not exist under lib/:')
    for s in strays:
        print(f'    {s}')
    sys.exit(1)


def write(path, data):
    with open(path, 'w') as fh:
        for f in sorted(data):
            lines = data[f]
            fh.write(f'SF:{os.path.join(root, f)}\n')
            for n in sorted(lines):
                fh.write(f'DA:{n},{lines[n]}\n')
            fh.write(f'LF:{len(lines)}\n')
            fh.write(f'LH:{sum(1 for h in lines.values() if h > 0)}\n')
            fh.write('end_of_record\n')


# anchor.info travels with the report so a later job can merge more tracefiles
# in without a Dart SDK. See --baseline.
shutil.copyfile(os.environ['ANCHOR'], os.path.join(out_dir, 'anchor.info'))

write(os.path.join(out_dir, 'merged.info'), merged)
write(os.path.join(out_dir, 'honest.info'), honest)


def rate(data):
    found = sum(len(v) for v in data.values())
    hit = sum(1 for v in data.values() for h in v.values() if h > 0)
    return hit, found, (100.0 * hit / found if found else 0.0)

mh, mf, mp = rate(merged)
hh, hf, hp = rate(honest)
synth_lines = sum(len(honest[f]) for f in unloadable if f in honest)

print('coverage report')
print(f'  inputs                 : {", ".join(named)}')
print(f'  LOADED-FILES number    : {mh}/{mf} = {mp:.1f}%  '
      f'({len(merged)} files the suites actually imported)')
print(f'  LIB-WIDE number        : {hh}/{hf} = {hp:.1f}%  '
      f'({len(honest)} files — every .dart under lib/ minus '
      f'{len(exclude)} documented exclusions)')
print(f'  of which synthesised   : {synth_lines} lines in '
      f'{len(unloadable)} VM-unloadable file(s) — an over-estimate, see '
      f'tool/coverage_report.sh')
print(f'  wrote {out_dir}/merged.info (real lines only, for diff-cover)')
print(f'  wrote {out_dir}/honest.info (every lib/ file, for humans and the ratchet)')
print(f'  wrote {out_dir}/anchor.info (the zero baseline, for --baseline)')

# --- M0's exit criterion, asserted mechanically -------------------------------
missing = sorted(set(all_lib) - set(honest))
if missing or len(honest) != len(all_lib):
    print('\nFAIL: honest.info does not account for every lib/ file.')
    for m in missing:
        print(f'    missing: {m}')
    sys.exit(1)

empty = sorted(f for f in honest if not honest[f])
print(f'  OK: {len(honest)} of {len(honest)} expected files present '
      f'({len(empty)} have no coverable lines at all: '
      f'export barrels and pure abstract interfaces)')
PY
rc=$?
[ $rc -ne 0 ] && { echo "COVERAGE REPORT FAILED"; exit $rc; }
exit 0
