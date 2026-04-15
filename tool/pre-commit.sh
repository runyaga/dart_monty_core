#!/usr/bin/env bash
# =============================================================================
# dart_monty_core — pre-commit checks (mirrors CI exactly)
#
# Checks run:
#   1. cargo fmt --check          (native/)
#   2. dart analyze --fatal-infos
#   3. dart format --set-exit-if-changed lib/ test/ hook/ tool/
#   4. FFI bindings staleness check (dart_monty.h → dart_monty_bindings.dart)
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
# 4. FFI bindings staleness check
# ---------------------------------------------------------------------------
echo "--- FFI bindings: staleness check ---"
# Only relevant when the C header is part of this commit.
if git diff --cached --name-only | grep -q "native/include/dart_monty.h"; then
  if command -v dart &>/dev/null; then
    # Regenerate in-place (ffigen writes to the path in ffigen.yaml).
    bash "$PKG/tool/generate_bindings.sh" > /dev/null 2>&1
    # If the bindings changed, they must also be staged.
    if ! git diff --quiet "$PKG/lib/src/ffi/generated/dart_monty_bindings.dart"; then
      git add "$PKG/lib/src/ffi/generated/dart_monty_bindings.dart"
      ok "FFI bindings regenerated and staged automatically"
    else
      ok "FFI bindings up-to-date"
    fi
  else
    echo "  SKIP: dart not found"
  fi
else
  echo "  SKIP: dart_monty.h not staged"
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
