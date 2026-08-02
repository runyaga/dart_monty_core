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
s(){ n="$1"; shift; t=$SECONDS
  if "$@" >"$OUT/$n.log" 2>&1; then echo "PASS  $n  ($((SECONDS-t))s)"; else echo "FAIL  $n  ($((SECONDS-t))s)"; fi >> "$OUT/SUMMARY.txt"; }
ns(){ n="$1"; shift; t=$SECONDS
  if (cd native && "$@") >"$OUT/$n.log" 2>&1; then echo "PASS  $n  ($((SECONDS-t))s)"; else echo "FAIL  $n  ($((SECONDS-t))s)"; fi >> "$OUT/SUMMARY.txt"; }

# The native-assets build hook caches per-target and did NOT rebuild after
# native/Cargo.toml changed, so dart test silently loaded a stale 0.18 dylib
# against a 0.19 oracle. Clear the cache whenever native/ is newer than the
# cached artifact.
CACHED=$(find .dart_tool -name 'libdart_monty_core_native*.dylib' 2>/dev/null | head -1)
if [ -n "$CACHED" ] && [ -n "$(find native/src native/Cargo.toml -newer "$CACHED" 2>/dev/null)" ]; then
  echo "note: native/ is newer than the cached dylib — clearing hook cache" >&2
  rm -rf .dart_tool/hooks_runner .dart_tool/lib
  dart pub get >/dev/null 2>&1
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
s  corpus_check  bash tool/check_fixture_corpus.sh
# The record, checked the same way the code is. A `!` commit touching lib/ must
# reach the CHANGELOG; `43366ba fix(limits)!` did not, and the prose cross-check
# that should have caught it had been performed and gone stale within a day.
s  breaking_rec  bash tool/check_breaking_recorded.sh
s  dart_analyze  dart analyze --fatal-infos
s  dart_format   dart format --line-length=80 --output=none --set-exit-if-changed lib/ test/ hook/ tool/
s  unit_tests    dart test --exclude-tags=ffi,wasm,integration,ladder,example
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
# NOTE: ffi_with_cm_test.dart needs `--features test-hooks` (tool/test_cm.sh) and is
# excluded here; it is retired in P1b since monty 0.19 dropped `_test_cm()`.
s  ffi_features  dart test $(ls test/integration/ffi_*_test.dart | grep -v with_cm) --run-skipped --tags=ffi -p vm
s  oracle_ffi    dart test test/integration/oracle_ffi_test.dart test/integration/oracle_ffi_ext_test.dart -p vm --run-skipped --tags=ffi
# The examples are the DOCUMENTED surface, and `dart analyze` only type-checks
# them. CI has run this since forever; the gate did not, so a change that broke
# every example could pass here and fail there — which it just did. Tier 1 made
# a hand-built `{'__type': …}` map decode as a dict, and example/10 taught
# exactly that pattern.
s  examples      dart test test/integration/example_smoke_test.dart -p vm --run-skipped --tags=example
# --skip-build is deliberate and load-bearing: without it this step REBUILDS
# lib/assets/*.wasm, i.e. the gate would test an artefact that is not the one
# being committed. It cost us a red CI once already (see the note at the foot of
# this file). With it, the gate exercises the committed asset — the same thing
# CI and every web consumer load — and touches nothing.
s  wasm_full     bash tool/test_wasm.sh --skip-build
# wasm_full drives the FIXTURE CORPUS through a bespoke fixtures.html harness.
# It does NOT run the package:test suites on chrome — those are a different
# mechanism (`dart test -p chrome --tags=wasm`, via tool/test_wasm_unit.sh) and
# were absent from this matrix entirely, so the chrome half of the standing
# "FFI and WASM both" rule was enforced only by CI. Added 2026-07-30 after two
# new 0.19 suites shipped with FFI runners and no WASM counterpart.
s  wasm_unit     bash tool/test_wasm_unit.sh
# Same suite, same WASM ENGINE, different DART compile target. Two things get
# called "wasm" here: the Rust engine (driven by every test above regardless of
# compiler) and the Dart target. Only this step covers the second. CI already
# ran dart2wasm for the fixture corpus; the gate never did, so every local
# "green" was dart2js-only on the web side.
s  wasm_unit_w   bash tool/test_wasm_unit.sh --dart2wasm
# Separate gate from wasm_full on purpose: different artefact (the assembled
# Pages site vs the test harness) and different failure modes (stale asset
# copies, COOP/COEP, relative paths under /repl/).
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

echo "" >> "$OUT/SUMMARY.txt"; echo "done $(date -u +%FT%TZ)" >> "$OUT/SUMMARY.txt"
cat "$OUT/SUMMARY.txt"
grep -q '^FAIL' "$OUT/SUMMARY.txt" && { echo; echo "GATE RED — do not commit. Logs: $OUT"; exit 1; }
echo; echo "GATE GREEN — safe to commit. Logs: $OUT"
