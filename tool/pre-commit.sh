#!/usr/bin/env bash
# =============================================================================
# dart_monty_core — FAST pre-commit subset (does NOT mirror CI)
#
# This header used to claim "mirrors CI exactly". It does not, and never did:
# it runs 4 checks while the real gate is 14 (tool/gate.sh). A git hook that
# claims parity it does not have is worse than no hook, because it buys
# confidence it cannot back.
#
# What this is: the fast checks worth blocking a commit on locally.
# What it is NOT: the gate. Run `bash tool/gate.sh` before you push.
#
# Checks run:
#   1. cargo fmt --check          (native/)
#   2. dart analyze --fatal-infos
#   3. dart format --set-exit-if-changed lib/ test/ hook/ tool/
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
  if cargo fmt --check --manifest-path "$PKG/native/worker/Cargo.toml" 2>&1; then
    ok "cargo fmt"
  else
    fail "cargo fmt: run 'cargo fmt' in native/worker/ to fix"
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
