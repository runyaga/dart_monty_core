#!/usr/bin/env bash
# =============================================================================
# The demo's upstream fixture links must point at the monty version we build.
# =============================================================================
# The conformance panel links each fixture name to its source in pydantic/monty,
# pinned to a tag. Nothing but a comment coupled that tag to the one in
# native/Cargo.toml — so an upgrade that bumped the crate would leave every link
# silently showing the WRONG source. Silently-wrong is worse than absent: a
# reader who clicks through and sees different code has no reason to suspect
# the link rather than the package.
#
# This repo has been bitten by exactly this shape before (a stale corpus
# reporting all-green against the wrong fixture set), so it is a check, not a
# comment.
# =============================================================================
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

CARGO_TAG="$(grep -m1 -oE 'tag = "v[0-9.]+"' native/Cargo.toml | grep -oE 'v[0-9.]+')"
LINK_TAG="$(grep -m1 -oE 'monty/blob/v[0-9.]+/' \
  packages/dart_monty_web/web/feature_matrix.dart | grep -oE 'v[0-9.]+')"

[ -n "$CARGO_TAG" ] || { echo "FATAL: no monty tag in native/Cargo.toml"; exit 2; }
[ -n "$LINK_TAG" ]  || { echo "FATAL: no fixture-link tag in feature_matrix.dart"; exit 2; }

if [ "$CARGO_TAG" != "$LINK_TAG" ]; then
  echo "FAIL: the demo links at $LINK_TAG but native/Cargo.toml pins $CARGO_TAG."
  echo "      Every fixture link would show source from the wrong version."
  echo "      Update _fixtureSourceBase in feature_matrix.dart."
  exit 1
fi

echo "PASS — fixture links and the monty pin agree ($CARGO_TAG)."
