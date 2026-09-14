#!/usr/bin/env bash
# =============================================================================
# This package's MINOR version must equal the monty patch it pins.
# =============================================================================
# The convention, unbroken across every release until it broke silently:
#
#     monty v0.0.17  ->  dart_monty_core 0.17.x
#     monty v0.0.18  ->  dart_monty_core 0.18.1
#     monty v0.0.19  ->  dart_monty_core 0.19.0
#     monty v0.0.23  ->  dart_monty_core 0.23.x
#
# It is not decorative. Snapshots are NOT portable across monty upgrades (see
# CHANGELOG: 0.18.x snapshots cannot be restored on 0.19.0), so the version a
# consumer reads is how they know which snapshot format and which engine
# semantics they are getting. A package that pins v0.0.23 while calling itself
# 0.19.0 tells every consumer the wrong thing about compatibility.
#
# How it broke: e1e4eda ("SoL-Pi run 2 (clean): monty v0.0.19 -> v0.0.23")
# moved the pin and did not touch pubspec.yaml or the CHANGELOG. Nothing
# compared the two, so the package described itself as 0.19.0 for as long as it
# took a human to notice the version on the deployed demo page.
#
# This is the same shape as tool/check_fixture_links.sh, which exists because a
# crate bump would otherwise leave every fixture link pointing at the wrong
# upstream source. Same failure, same remedy: a check, not a comment.
# =============================================================================
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

PUB_VER="$(grep -m1 -E '^version:' pubspec.yaml | awk '{print $2}')"
CARGO_TAG="$(grep -m1 -oE 'tag = "v[0-9.]+"' native/Cargo.toml | grep -oE '[0-9.]+')"

[ -n "$PUB_VER" ]   || { echo "FATAL: no version: in pubspec.yaml"; exit 2; }
[ -n "$CARGO_TAG" ] || { echo "FATAL: no monty tag in native/Cargo.toml"; exit 2; }

# pubspec "0.23.0" -> minor "23";  monty tag "0.0.23" -> patch "23"
PUB_MINOR="$(printf '%s\n' "$PUB_VER"   | cut -d. -f2)"
MONTY_PATCH="$(printf '%s\n' "$CARGO_TAG" | cut -d. -f3)"

if [ "$PUB_MINOR" != "$MONTY_PATCH" ]; then
  echo "FAIL: version/pin drift."
  echo "      pubspec.yaml version : $PUB_VER      (minor = $PUB_MINOR)"
  echo "      native/Cargo.toml pin: v$CARGO_TAG   (patch = $MONTY_PATCH)"
  echo ""
  echo "  This package's minor version tracks the monty patch it pins, because"
  echo "  snapshots are not portable across monty upgrades and the version is"
  echo "  how a consumer knows which format they have."
  echo ""
  echo "  Bump pubspec.yaml to 0.${MONTY_PATCH}.0, retitle the unreleased"
  echo "  CHANGELOG section to match, and update the version badge on the five"
  echo "  published pages (tool/check_page_versions.sh will tell you which)."
  exit 1
fi

echo "PASS — pubspec $PUB_VER tracks the monty pin v$CARGO_TAG."
