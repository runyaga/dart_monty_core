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

# ---------------------------------------------------------------------------
# The same number, in the provenance record for the committed binary assets.
# ---------------------------------------------------------------------------
# tool/wasm-provenance.json records which monty produced lib/assets/*.wasm.
# tool/check_asset_freshness.sh opens that file but reads only source_sha256,
# so its `monty_tag` was decorative -- and it sat at v0.0.19 while Cargo.toml
# pinned v0.0.23, wrong for four upstream releases with nothing to notice.
#
# Snapshots are not portable across monty upgrades, so "which monty built this
# asset" is the one fact the file exists to state. A provenance record that is
# silently wrong is worse than no record: it is believed.
# Parsed as JSON, not by regex. The first attempt at this used
#   grep -oE '"monty_tag"..."v[0-9.]+"' | grep -oE '[0-9.]+$'
# which never matched, because the captured text ends in a QUOTE, not a digit.
# Under `set -euo pipefail` that emptied the variable and killed the script on a
# clean tree -- a gate that fails to run, which is the one failure mode this
# file exists to prevent. json.load cannot be fooled by punctuation.
PROV_TAG="$(python3 -c "import json;print(json.load(open('tool/wasm-provenance.json')).get('monty_tag','').lstrip('v'))")"

[ -n "$PROV_TAG" ] || { echo "FATAL: no monty_tag in tool/wasm-provenance.json"; exit 2; }

if [ "$PROV_TAG" != "$CARGO_TAG" ]; then
  echo "FAIL: provenance/pin drift."
  echo "      tool/wasm-provenance.json monty_tag: v$PROV_TAG"
  echo "      native/Cargo.toml pin              : v$CARGO_TAG"
  echo ""
  echo "  The provenance record names the monty that built the committed"
  echo "  lib/assets/*.wasm. Snapshots are not portable across monty upgrades,"
  echo "  so a wrong tag here misinforms anyone auditing the binary."
  echo ""
  echo "  Set monty_tag to v${CARGO_TAG}, and re-run tool/prebuild.sh if the"
  echo "  assets themselves were not rebuilt against this pin."
  exit 1
fi

echo "PASS — wasm-provenance monty_tag v$PROV_TAG tracks the pin."
