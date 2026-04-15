#!/usr/bin/env bash
# =============================================================================
# dart_monty_core — pre-commit checks (mirrors CI exactly)
#
# Checks run:
#   1. cargo fmt --check          (native/)
#   2. dart analyze --fatal-infos
#   3. dart format --set-exit-if-changed lib/ test/ hook/ tool/
#              (excludes lib/src/ffi/generated/**)
#
# Install once:
#   bash tool/install-hooks.sh
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0
FAIL=0

ok()   { echo "  ✓ $*"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $*"; FAIL=$((FAIL + 1)); }

echo "=== pre-commit checks ==="
echo ""

# ---------------------------------------------------------------------------
# 1. cargo fmt --check
# ---------------------------------------------------------------------------
echo "--- Rust: cargo fmt --check ---"
if command -v cargo &>/dev/null; then
  if cargo fmt --check --manifest-path "$PKG/native/Cargo.toml" 2>&1; then
    ok "cargo fmt"
  else
    fail "cargo fmt: run 'cargo fmt' in native/ to fix"
  fi
else
  echo "  SKIP: cargo not found"
fi
echo ""

# ---------------------------------------------------------------------------
# 2. dart analyze --fatal-infos
# ---------------------------------------------------------------------------
echo "--- Dart: analyze --fatal-infos ---"
if command -v dart &>/dev/null; then
  if dart analyze --fatal-infos "$PKG" 2>&1; then
    ok "dart analyze"
  else
    fail "dart analyze: fix reported issues above"
  fi
else
  echo "  SKIP: dart not found"
fi
echo ""

# ---------------------------------------------------------------------------
# 3. dart format --set-exit-if-changed
# ---------------------------------------------------------------------------
echo "--- Dart: format check ---"
if command -v dart &>/dev/null; then
  # Note: --exclude is not supported in all Dart versions; the generated
  # bindings file is always pre-formatted by generate_bindings.sh, so it
  # is safe to include lib/ without any special exclusion.
  if dart format \
      --line-length=80 \
      --set-exit-if-changed \
      "$PKG/lib/" "$PKG/test/" "$PKG/hook/" "$PKG/tool/" \
      2>&1; then
    ok "dart format"
  else
    fail "dart format: run 'dart format --line-length=80 lib/ test/ hook/ tool/' to fix"
  fi
else
  echo "  SKIP: dart not found"
fi
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo "=== $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "Commit blocked. Fix the issues above and re-stage."
  exit 1
fi
