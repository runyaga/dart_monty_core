#!/usr/bin/env bash
# =============================================================================
# tool/gate.sh — THE commit gate. Run this before every commit.
# =============================================================================
# Named to match dart_monty's tool/gate.sh: one word, one concept, same meaning
# in both repos. It was called "matrix.sh", which described its shape rather
# than its purpose and told you nothing about when to run it.
# Runs every verification mechanism in docs/contributor/testing-runbook.md and
# prints MATRIX GREEN or MATRIX RED. A red step means DO NOT COMMIT, including
# when the failing step looks unrelated to your change.
#
# This lives in the repo on purpose. It used to sit in a private planning
# directory, which meant the single most important gate could not be run by a
# new contributor, by CI, or by an agent -- the runbook told you to run a script
# that was not there.
#
# Usage:
#   bash tool/gate.sh [outdir]
#
# The gate is READ-ONLY: it validates the tree as it stands, including the
# committed binaries in lib/assets/. If you changed native/ or js/, run
# `bash tool/prebuild.sh` FIRST — the gate will not rebuild for you, and step 1
# (asset_fresh) fails if you forget.
#
# Logs land in <outdir> (default: .gate-logs/, gitignored), one file per step
# plus SUMMARY.txt.
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"
OUT="${1:-.gate-logs/gate-$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$OUT"; : > "$OUT/SUMMARY.txt"
echo "core $(git rev-parse --short HEAD) on $(git branch --show-current)" >> "$OUT/SUMMARY.txt"
echo "monty pin: $(grep -m1 '^monty = ' native/Cargo.toml)" >> "$OUT/SUMMARY.txt"
echo "" >> "$OUT/SUMMARY.txt"

# Snapshot the working tree so the read-only promise in the header can be
# CHECKED rather than merely asserted. Every past violation of that promise was
# a step that wrote a build artefact and was believed not to — the belief is
# what failed, so stop relying on it. Compared again at the foot of this file.
TREE_BEFORE="$(git status --porcelain)"

s(){ n="$1"; shift; t=$SECONDS
  if "$@" >"$OUT/$n.log" 2>&1; then echo "PASS  $n  ($((SECONDS-t))s)"; else echo "FAIL  $n  ($((SECONDS-t))s)"; fi >> "$OUT/SUMMARY.txt"; }
ns(){ n="$1"; shift; t=$SECONDS
  if (cd native && "$@") >"$OUT/$n.log" 2>&1; then echo "PASS  $n  ($((SECONDS-t))s)"; else echo "FAIL  $n  ($((SECONDS-t))s)"; fi >> "$OUT/SUMMARY.txt"; }

# The native-assets build hook caches per-target and did NOT rebuild after
# native/Cargo.toml changed, so dart test silently loaded a stale 0.18 dylib
# against a 0.19 oracle. Clear the cache whenever native/ is newer than the
# cached artifact.
# BOTH EXTENSIONS. This searched only for `*.dylib`, which hook/build.dart:15
# produces on macOS ONLY — Linux gets `.so` (hook/build.dart:16). So on every
# Linux machine, including CI-shaped ones, `CACHED` was always empty and this
# guard NEVER FIRED. Measured in the workspace container: 0 dylib matches, 2
# .so matches.
#
# That is not theoretical. It cost an hour this session: after a fix to the
# class-uuid derivation the tests still failed identically, and the obvious
# reading was that the diagnosis was wrong. It was a hooks_runner dylib from
# the previous day. The guard written to prevent exactly that had been dead
# the whole time.
#
# IT COMPARES CONTENT, NOT MTIMES, and that is the whole of L4.
#
# The `find -newer` form this replaces fired on any mtime touch: a comment, a
# `dart format` pass, a rebase, a `git checkout` rewriting a file to identical
# bytes. Measured across four gate runs on an UNCHANGED tree: unit_tests 1s vs
# 151s, corpus_cm_js 3s vs 138s, whole gate 163s vs 459s -- a 2.8x swing with no
# source change. One trigger was reproduced exactly: bumping the version string
# in pubspec.yaml, which touches no Rust at all, printed "native/ is newer than
# the cached native library" and forced a full cold rebuild.
#
# `unit_tests` is PURE DART and was among the steps paying for it, which is the
# sharper half of the finding: a pure-Dart step should never wait on a Rust
# build. Clearing .dart_tool/hooks_runner made it re-resolve regardless.
#
# The hash is the same shape tool/check_asset_freshness.sh already uses over
# these very files, and for the same stated reason: mtimes lie, content does
# not. The stamp records WHICH SOURCE the cached library was built from, so the
# cache is cleared when that source actually changes and left alone otherwise.
STAMP=.dart_tool/.native-source-hash
native_source_hash() {
  {
    find native/src -type f -name '*.rs' -print0 2>/dev/null
    printf '%s\0' native/Cargo.toml native/Cargo.lock
  } | tr '\0' '\n' | sort | while read -r f; do
    [ -f "$f" ] && printf '%s ' "$(shasum -a 256 "$f" | awk '{print $1}')"
  done | shasum -a 256 | awk '{print $1}'
}
CACHED=$(find .dart_tool \
  \( -name 'libdart_monty_core_native*.dylib' \
     -o -name 'libdart_monty_core_native*.so' \) 2>/dev/null | head -1)
if [ -n "$CACHED" ]; then
  NATIVE_NOW=$(native_source_hash)
  NATIVE_WAS=$(cat "$STAMP" 2>/dev/null || echo '')
  if [ "$NATIVE_NOW" != "$NATIVE_WAS" ]; then
    # A missing stamp is treated as a miss ONCE, on the first run after this
    # change. That is deliberate: the alternative is trusting a cache whose
    # provenance is unknown, which is the exact bug the original guard was
    # written for after a day-old dylib cost an hour of misdiagnosis.
    echo "note: native/ SOURCE CHANGED (${NATIVE_WAS:0:8}… -> ${NATIVE_NOW:0:8}…) — clearing hook cache" >&2
    rm -rf .dart_tool/hooks_runner .dart_tool/lib
    dart pub get >/dev/null 2>&1
    printf '%s' "$NATIVE_NOW" > "$STAMP"
  fi
fi

# The committed assets in lib/assets/ are build artefacts of native/src and
# js/src, and the wasm build is NOT byte-reproducible, so `git diff` on the blob
# cannot detect staleness. This hashes the SOURCES instead. It is the only layer
# here that needs no human discipline: WIRE_FORMAT_VERSION is hand-bumped, so it
# is blind to "encoding changed, nobody bumped, nobody rebuilt".
s  asset_fresh   bash tool/check_asset_freshness.sh
# The complement to asset_fresh: that one catches "sources moved, nobody
# rebuilt"; this one catches "the encoding was versioned on one side only".
s  wire_version  bash tool/check_wire_version.sh
# The third member of that family. asset_fresh catches "sources moved, nobody
# rebuilt" and wire_version catches "the encoding was versioned on one side
# only"; this catches the Worker and the .wasm disagreeing about a function's
# ARITY, which no compiler on either side can see. JS fills missing wasm
# arguments with 0 and drops extra ones instead of throwing, so a Rust signature
# change is a silent miscompile on the web backend -- measured 2026-09-14:
# monty_repl_restore went from 3 parameters to 5, the Worker kept passing 3,
# out_error bound to the limits_json slot, and every WASM restore failed with
# no cause while the whole FFI suite stayed green.
s  wasm_arity    node tool/check_wasm_arity.mjs
# The complement of wasm_arity, which reads the SHIPPED WASM EXPORTS and never
# opens the header -- so it can prove a call site matches the binary while the
# header says nothing at all. Measured: monty_alloc and monty_dealloc were
# exported, called 49 times by the Worker, and declared zero times.
s  exports_decl  bash tool/check_exports_declared.sh
# The inbound-forgery suite is the end-to-end proof of core#136/#139, and it was
# HAND-LISTED, so it drifted: 11 tags attacked against 25 emitted, and three of
# the gaps were types the wire-v5 work had added days earlier. Adding an encoder
# tag and adding a forgery row are separate edits in separate languages; this
# ties them together.
s  forgery_cov   bash tool/check_forgery_coverage.sh
s  hierarchy_reg bash tool/check_hierarchy_registry.sh
s  hook_deps     bash tool/check_hook_dependencies.sh
# WIRE-CONTRACT.md is cited as normative by ten sites -- including a test that
# prints "WIRE-CONTRACT.md row N requires ..." on failure -- and did not exist.
# The risk in writing one is fabrication: a plausible spec that does not match
# the encoder is worse than none, because the tests cite it as authority. Its
# row table is DERIVED from the executed assertions, and this keeps it derived.
s  wire_contract bash tool/check_wire_contract.sh
# A workflow GitHub cannot parse does not fail loudly: it records a 0-job run
# and STOPS MATCHING ITS TRIGGERS, so the PR checks quietly cease. A duplicate
# `env:` key took CI out for 13 commits here while `yaml.safe_load` passed the
# whole time -- PyYAML keeps the last duplicate, GitHub rejects the document.
s  workflows_ok bash tool/check_workflows_valid.sh
s  corpus_check  bash tool/check_fixture_corpus.sh
# The record, checked the same way the code is. A `!` commit touching lib/ must
# reach the CHANGELOG; `43366ba fix(limits)!` did not, and the prose cross-check
# that should have caught it had been performed and gone stale within a day.
s  breaking_rec  bash tool/check_breaking_recorded.sh
# The demo links every fixture to pydantic/monty at a pinned tag; a crate bump
# that missed the constant would show the wrong source with no error.
s  fixture_links bash tool/check_fixture_links.sh
# Same shape as fixture_links, one level up: the published pages state which
# build they are, and nothing compiles an HTML shell, so the string rots
# silently on the next version bump. The deployed site is the one artefact a
# reader meets without a pubspec in front of them.
s  page_versions bash tool/check_page_versions.sh
# The source of the number those pages print. The monty pin moved 0.19 -> 0.23
# in e1e4eda and pubspec.yaml did not follow, so the package called itself
# 0.19.0 while pinning v0.0.23 -- and since snapshots are not portable across
# monty upgrades, that told every consumer the wrong thing about compatibility.
# Nothing compared the two until a human read the version off the demo page.
s  version_pin   bash tool/check_version_pin.sh
s  vague_errors bash tool/check_no_vague_errors.sh
# The two backends implement one shared contract, so a consumer picks a backend
# without picking a feature set. `throw UnimplementedError` breaks that
# silently: at the call site it is indistinguishable from a real platform
# limit. Measured -- FfiCoreBindings.resumeNameLookupValue claimed the FFI
# backend did not support it while the Rust export, the header AND the
# generated binding all existed. The message was false and it reached a shipped
# example.
s  backend_parity bash tool/check_backend_parity.sh
s  dart_analyze  dart analyze --fatal-infos
s  dart_format   dart format --line-length=80 --output=none --set-exit-if-changed lib/ test/ hook/ tool/
# --coverage is not decoration: it is the input to cov_report below, and the
# collection is nearly free here -- measured in the build container, 457 tests
# in 5s with it on. (CI's 5m53s for the same step is the runner, not the
# instrumentation.) $OUT is under .gate-logs/, which is gitignored, so this
# still writes nothing the read-only check can see.
s  unit_tests    dart test --exclude-tags=ffi,wasm,integration,ladder,example --coverage="$OUT/cov"
# The SAME pure-Dart suite on both web compilers. Not redundant with unit_tests:
# dart2js has one number type, so `4.0 is int` is true and integral doubles
# collapse to ints, while dart2wasm has real doubles. A numeric bug can pass on
# the VM and be unreachable-or-wrong on the web -- measured: a fix for
# inputs_encoder compiled, analysed clean and passed on the VM while doing
# nothing at all, because the arm it added was dead on the only backend with the
# bug. `vm-only` is excluded because those files cannot COMPILE for the web.
s  unit_web      dart test --exclude-tags=ffi,wasm,integration,ladder,example,vm-only -p chrome -c dart2js -c dart2wasm
s  dcm_ratchet   bash tool/dcm_ratchet.sh
ns cargo_fmt     cargo fmt --check
ns cargo_clippy  cargo clippy --all-targets -- -D warnings
ns cargo_test    cargo test
ns cargo_deny    cargo deny check
# ffi_with_cm_test.dart is INCLUDED again. The note here said it needs
# `--features test-hooks` and was "retired in P1b since monty 0.19 dropped
# `_test_cm()`". The second half is right and the first half stopped being
# true because of it: with `_test_cm()` gone (0 hits in monty v0.0.23) the
# with__cm_* fixtures use a plain Python `class CM:`, and the test passes 5/5
# on a normal build. The exclusion outlived its reason on BOTH sides -- CI had
# the same one (ci.yaml) -- so the suite ran nowhere at all.
# test/integration/repros IS included now. CI's test-ffi job has globbed it in
# since the job was written (ci.yaml, alongside the ffi_*_test.dart glob); the
# gate named only the glob, so issue_32_listcomp_global_clobber_ffi_test.dart
# ran in CI and nowhere else locally -- the same CI-only-gap shape that
# `examples` and `corpus_wasm` were added to close. It also makes the gate's
# coverage set identical to CI's, which is what lets ONE tool/coverage-baseline
# .json serve both.
s  ffi_features  dart test $(ls test/integration/ffi_*_test.dart) test/integration/repros --run-skipped --tags=ffi -p vm --coverage="$OUT/cov"
s  oracle_ffi    dart test test/integration/oracle_ffi_test.dart test/integration/oracle_ffi_ext_test.dart -p vm --run-skipped --tags=ffi --coverage="$OUT/cov"
# The examples are the DOCUMENTED surface, and `dart analyze` only type-checks
# them. CI has run this since forever; the gate did not, so a change that broke
# every example could pass here and fail there — which it just did. Tier 1 made
# a hand-built `{'__type': …}` map decode as a dict, and example/10 taught
# exactly that pattern.
# No --coverage on this one, and the reason is not obvious: the suite runs each
# example with `Process.run('dart', ['run', ex])` (example_smoke_test.dart:59),
# a separate PROCESS, and --coverage instruments the TEST isolate. Measured: 11
# passing tests, one hitmap JSON, and format_coverage --report-on=lib writes a
# 0-byte tracefile. The planning document listed this suite as free coverage;
# it is free, and it is zero.
s  examples      dart test test/integration/example_smoke_test.dart -p vm --run-skipped --tags=example
# Every measured suite above wrote its hitmap into ONE directory, so format_coverage
# unions them and there is no LCOV merge to get wrong. That matters: the FFI
# suite is 1,356 tests that drive ffi_core_bindings, native_bindings_ffi,
# monty_repl and ffi_repl_bindings -- the four files the unit-only measurement
# reported at 0.0-3.1% -- and it has been running in CI, untracked, the whole
# time. This does not test anything new; it stops throwing away the record of
# what was already tested.
#
# It reports two numbers on purpose (loaded-files and lib-wide) so nobody can
# quietly switch to whichever flatters.
s  cov_report    bash tool/coverage_report.sh --out-dir "$OUT/coverage" "$OUT/cov"
# ...and a floor under them. Nothing else here stops the reclassified coverage
# decaying: new native code lands, the conformance corpus does not grow to
# match, and per-file coverage slides back invisibly because the project total
# is dominated by files nobody is changing. Same mechanism as dcm_ratchet, same
# rule about regenerating the baseline only in the commit that justifies it.
s  cov_ratchet   bash tool/coverage_ratchet.sh "$OUT/coverage/honest.info"
# --skip-build is deliberate and load-bearing: without it this step REBUILDS
# lib/assets/*.wasm, i.e. the gate would test an artefact that is not the one
# being committed. It cost us a red CI once already (see the note at the foot of
# this file). With it, the gate exercises the committed asset — the same thing
# CI and every web consumer load — and touches nothing.
#
# RENAMED from `wasm_full` on 2026-08-02. That name claimed the widest possible
# coverage ("full") for the NARROWER of the two web compilers, and the gap below
# hid behind it for as long as it existed: everything here runs on the WASM
# engine, so "wasm" in a step name never distinguished anything, and nobody
# reading a green `wasm_full` had a reason to ask which Dart target it used.
# The pair is now named after the axis that actually varies.
s  corpus_js     bash tool/test_wasm.sh --skip-build
# The SAME 531 fixtures, the same WASM engine, compiled with dart2wasm instead.
# This step is new (2026-08-02) and closes the last CI-only gap: CI has run the
# dart2wasm corpus since ci.yaml:583/:669, the gate never did, so every local
# "GATE GREEN" was dart2js-only on the corpus and a dart2wasm-only regression
# could only be caught after pushing. The compilers are not interchangeable —
# dart2js has one number type, dart2wasm has real doubles — which is the same
# reason `unit_web` runs both, and is exactly the class of bug that made
# `unit_web` necessary.
#
# It does NOT rebuild anything in the tree: the dart2wasm output is staged in a
# temp dir, because `dart compile wasm -o test/integration/web/wasm_runner.wasm`
# (what CI runs) writes three TRACKED files and the gate is read-only.
s  corpus_wasm   bash tool/test_wasm.sh --skip-build --dart2wasm
# The two steps above run the SHIPPED engine, which has test-hooks off, so they
# skip eight fixtures: five with__cm_* (they need monty's synthetic `_test_cm()`)
# and three recursion ones (they need `sys.setrecursionlimit`). Measured on
# dart2wasm: 520 passed / 11 skipped without the feature, 528 / 3 with it.
# Those eight are therefore covered by NO step above, on either compiler — the
# only thing that has ever run them is tool/test_cm_wasm.sh, which the gate did
# not call, and which until now only had a dart2js path. So the eight had never
# executed on dart2wasm anywhere, locally or in CI.
#
# Both variants are cheap here because they share one cargo cache: the pair adds
# ~30s warm. Cold (or after native/src changes) the first of them pays a
# test-hooks rebuild.
#
# Neither writes to the tree. The engine they build has test-hooks ON, which is
# NEVER shipped, so test_cm_wasm.sh stages it in a temp dir and builds it in its
# own target dir (native/target/test-hooks) — otherwise it would sit at exactly
# the path tool/test_wasm.sh copies into lib/assets/ without --skip-build, and
# the next reader would load a sandbox-escaping engine believing it was ours.
s  corpus_cm_js  bash tool/test_cm_wasm.sh
s  corpus_cm_w   bash tool/test_cm_wasm.sh --dart2wasm
# Neither corpus step runs the package:test suites on chrome — those are a
# different mechanism (`dart test -p chrome --tags=wasm`, via
# tool/test_wasm_unit.sh) and were absent from this matrix entirely, so the
# chrome half of the standing "FFI and WASM both" rule was enforced only by CI.
# Added 2026-07-30 after two new 0.19 suites shipped with FFI runners and no
# WASM counterpart.
s  wasm_unit     bash tool/test_wasm_unit.sh
# Same suite, same WASM ENGINE, different DART compile target — the unit-test
# counterpart of corpus_js/corpus_wasm above.
s  wasm_unit_w   bash tool/test_wasm_unit.sh --dart2wasm
# Separate gate from the corpus steps on purpose: different artefact (the
# assembled Pages site vs the test harness) and different failure modes (stale
# asset copies, COOP/COEP, relative paths under /repl/).
s  pages_render  bash tool/check_pages.sh

# -----------------------------------------------------------------------------
# THE GATE DOES NOT WRITE TO THE WORKING TREE. Why that rule exists:
#
# This step used to rebuild lib/assets/*.wasm (test_wasm.sh with no flag), and
# because that build is NOT byte-reproducible (identical tree, different bytes —
# issue #41) every gate run left the repo dirty, fighting the commit-per-gate
# rule. The fix at the time was for the gate to `git checkout --` the wasm
# afterwards. That restore then silently reverted a DELIBERATE rebuild — the one
# that added the monty_wire_format_version export — the stale binary got
# committed, and CI went red across every web job.
#
# A local gate structurally cannot catch that: the FFI path compiles from
# source, so only the web path ever loads the committed asset, and the gate's
# own web steps ran BEFORE the restore. Any smarter restore heuristic has the
# same shape — an export-surface check would pass right through Phase 2, which
# changes what convert.rs emits without adding a symbol.
#
# So the two responsibilities are split instead of threaded:
#   tool/prebuild.sh   writes lib/assets/. A human runs it and commits the result.
#   tool/gate.sh       reads lib/assets/. Never rebuilds, never restores.
# Staleness is caught by tool/check_asset_freshness.sh (step 1), which hashes
# the SOURCES — the one layer that needs no discipline.
#
# KEEP_WASM is gone: there is nothing left to keep or discard.
if ! git diff --quiet -- lib/assets/ 2>/dev/null; then
  echo "" >> "$OUT/SUMMARY.txt"
  echo "note: lib/assets/ is dirty and was NOT touched — the gate tested exactly" >> "$OUT/SUMMARY.txt"
  echo "      these bytes, so commit them with this change or CI will load others." >> "$OUT/SUMMARY.txt"
fi

# The read-only promise, enforced. This compares the tree to the snapshot taken
# before step 1: it flags what THIS RUN changed, not what was already dirty when
# you started, so it stays quiet on a work-in-progress tree and speaks only when
# the gate itself wrote something.
#
# The trap it exists for: `dart compile wasm -o test/integration/web/wasm_runner.wasm`
# — the command CI runs and the one wasm_runner_wasm.dart's header tells you to
# run — overwrites three TRACKED files. Add the dart2wasm corpus the obvious way
# and every gate run leaves a meaningless diff behind; worse, the same shape of
# mistake with a test-hooks build (tool/test_cm_wasm.sh) would leave a dylib
# that is NOT the shipped one for the next `dart test` to load silently.
# corpus_wasm stages into a temp dir for exactly this reason. This check is what
# notices if some future step forgets.
TREE_AFTER="$(git status --porcelain)"
if [ "$TREE_BEFORE" != "$TREE_AFTER" ]; then
  {
    echo ""
    echo "FAIL  read_only_tree  (the gate MODIFIED the working tree)"
    echo "      The gate must validate the tree as it stands. Paths that changed"
    echo "      during this run:"
    diff <(printf '%s\n' "$TREE_BEFORE") <(printf '%s\n' "$TREE_AFTER") \
      | grep -E '^[<>]' | sed 's/^/        /'
    echo "      Fix the step that wrote them — stage build output outside the repo."
  } >> "$OUT/SUMMARY.txt"
fi

echo "" >> "$OUT/SUMMARY.txt"; echo "done $(date -u +%FT%TZ)" >> "$OUT/SUMMARY.txt"
cat "$OUT/SUMMARY.txt"
grep -q '^FAIL' "$OUT/SUMMARY.txt" && { echo; echo "GATE RED — do not commit. Logs: $OUT"; exit 1; }
echo; echo "GATE GREEN — safe to commit. Logs: $OUT"
