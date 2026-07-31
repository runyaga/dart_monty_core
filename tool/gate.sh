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
#   KEEP_WASM=1 bash tool/gate.sh      # keep a deliberately rebuilt .wasm
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
s  corpus_check  bash tool/check_fixture_corpus.sh
s  dart_analyze  dart analyze --fatal-infos
s  dart_format   dart format --line-length=80 --output=none --set-exit-if-changed lib/ test/ hook/ tool/
s  unit_tests    dart test --exclude-tags=ffi,wasm,integration,ladder,example
s  dcm_ratchet   bash tool/dcm_ratchet.sh
ns cargo_fmt     cargo fmt --check
ns cargo_clippy  cargo clippy --all-targets -- -D warnings
ns cargo_test    cargo test
ns cargo_deny    cargo deny check
# NOTE: ffi_with_cm_test.dart needs `--features test-hooks` (tool/test_cm.sh) and is
# excluded here; it is retired in P1b since monty 0.19 dropped `_test_cm()`.
s  ffi_features  dart test $(ls test/integration/ffi_*_test.dart | grep -v with_cm) --run-skipped --tags=ffi -p vm
s  oracle_ffi    dart test test/integration/oracle_ffi_test.dart test/integration/oracle_ffi_ext_test.dart -p vm --run-skipped --tags=ffi
s  wasm_full     bash tool/test_wasm.sh
# wasm_full drives the FIXTURE CORPUS through a bespoke fixtures.html harness.
# It does NOT run the package:test suites on chrome — those are a different
# mechanism (`dart test -p chrome --tags=wasm`, via tool/test_wasm_unit.sh) and
# were absent from this matrix entirely, so the chrome half of the standing
# "FFI and WASM both" rule was enforced only by CI. Added 2026-07-30 after two
# new 0.19 suites shipped with FFI runners and no WASM counterpart.
s  wasm_unit     bash tool/test_wasm_unit.sh
# Separate gate from wasm_full on purpose: different artefact (the assembled
# Pages site vs the test harness) and different failure modes (stale asset
# copies, COOP/COEP, relative paths under /repl/).
s  pages_render  bash tool/check_pages.sh

# tool/test_wasm.sh rebuilds lib/assets/*.wasm, and that build is NOT
# byte-reproducible (same size, different bytes from an unchanged tree — see
# issue #41). Left alone it dirties the repo on every matrix run, which fights
# the commit-per-gate rule (D8). Restore it unless the wasm was deliberately
# regenerated as part of the current gate (P4).
if [ "${KEEP_WASM:-0}" != "1" ] && ! git diff --quiet -- lib/assets/dart_monty_core_native.wasm 2>/dev/null; then
  git checkout -- lib/assets/dart_monty_core_native.wasm
  echo "" >> "$OUT/SUMMARY.txt"
  echo "note: restored lib/assets/*.wasm (non-reproducible rebuild; KEEP_WASM=1 to retain)" >> "$OUT/SUMMARY.txt"
fi

echo "" >> "$OUT/SUMMARY.txt"; echo "done $(date -u +%FT%TZ)" >> "$OUT/SUMMARY.txt"
cat "$OUT/SUMMARY.txt"
grep -q '^FAIL' "$OUT/SUMMARY.txt" && { echo; echo "GATE RED — do not commit. Logs: $OUT"; exit 1; }
echo; echo "GATE GREEN — safe to commit. Logs: $OUT"
