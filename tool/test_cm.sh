#!/usr/bin/env bash
# =============================================================================
# dart_monty_core — with__cm_* conformance (test-hooks build)
# =============================================================================
# The `with__cm_*` fixtures exercise the `with` machinery through monty's
# synthetic `_test_cm()` context manager, which only exists when the native
# crate is built with the `test-hooks` cargo feature. That feature is
# testing-only and is NEVER in the shipped binaries, so these fixtures are
# skipped by the normal suites (see test/integration/_unsupported_wasm_fixtures.dart).
#
# This script builds a test-hooks oracle binary AND a test-hooks FFI dylib
# (via DART_MONTY_TEST_HOOKS=1, honored by hook/build.dart), then runs the
# dedicated FFI conformance test that compares the two.
#
# Usage: bash tool/test_cm.sh
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

echo "=== with__cm_* conformance (test-hooks) ==="

echo "--- Building oracle with --features test-hooks ---"
(cd native && cargo build --bin oracle --features test-hooks)

# The FFI dylib is produced by hook/build.dart on `dart test`. It adds
# --features test-hooks when the native/.test-hooks marker file exists (a file,
# not an env var, because native-assets hooks run hermetically). The hook
# caches by input hash and won't notice the marker, so drop its cache to force
# a fresh build. Always clean up the marker on exit.
MARKER="$PKG/native/.test-hooks"
cleanup() { rm -f "$MARKER"; rm -rf "$PKG/.dart_tool/hooks_runner"; }
trap cleanup EXIT

echo "--- Enabling test-hooks marker + clearing hook cache ---"
touch "$MARKER"
rm -rf .dart_tool/hooks_runner

echo "--- Running ffi_with_cm_test ---"
dart test \
  test/integration/ffi_with_cm_test.dart \
  -p vm --run-skipped --tags=test-hooks

echo ""
echo "=== PASSED: with__cm_* conformance ==="
# The EXIT trap removes the marker and the hook cache, so the next normal FFI
# run rebuilds the stock (no-test-hooks) dylib automatically.
