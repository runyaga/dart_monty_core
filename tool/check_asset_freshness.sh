#!/usr/bin/env bash
# =============================================================================
# Are the committed assets stale relative to their sources?
# =============================================================================
# lib/assets/{dart_monty_core_bridge.js,dart_monty_core_worker.js,
# dart_monty_core_native.wasm} are COMMITTED build artefacts. The wasm build is
# NOT byte-reproducible -- an unchanged tree yields different bytes -- so
# `git diff` on the blob can never tell you whether the asset matches the crate.
#
# Hashing the OUTPUT is therefore useless. Hashing the INPUT is not: native/src,
# native/Cargo.{toml,lock} and js/src are ordinary files and hash deterministically.
#
# This is the layer that needs no one to remember anything:
#
#   source hash    (here)          stale asset, mechanical, cannot be forgotten
#   WIRE_FORMAT_VERSION            deliberate format change, declared by hand
#   repr differential              wrong values, behavioural
#
# The middle layer alone is not enough: change the encoding, forget to bump the
# version, forget to rebuild, and both sides report v1 and agree. This catches
# that, because the hash is DERIVED rather than declared.
#
# Usage:
#   bash tool/check_asset_freshness.sh            # verify
#   bash tool/check_asset_freshness.sh --update   # re-record (tool/prebuild.sh does this)
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

RECORD=tool/wasm-provenance.json

# Everything the committed assets are built FROM. Order is fixed by `sort` so
# the hash is stable across machines and filesystems.
source_hash() {
  {
    find native/src -type f -name '*.rs' -print0 2>/dev/null
    printf '%s\0' native/Cargo.toml native/Cargo.lock
    find js/src -type f -name '*.js' -print0 2>/dev/null
  } | tr '\0' '\n' | sort | while read -r f; do
    [ -f "$f" ] && printf '%s ' "$(shasum -a 256 "$f" | awk '{print $1}')"
  done | shasum -a 256 | awk '{print $1}'
}

HAVE=$(source_hash)

if [ "${1:-}" = "--update" ]; then
  python3 - "$HAVE" <<'PY'
import json, sys
p = 'tool/wasm-provenance.json'
try:
    d = json.load(open(p))
except FileNotFoundError:
    d = {}
d['source_sha256'] = sys.argv[1]
d['_source_sha256_comment'] = (
    'sha256 over native/src/**.rs, native/Cargo.{toml,lock} and js/src/**.js -- '
    'the INPUTS to the committed assets. The assets themselves are not '
    'byte-reproducible, so hashing them proves nothing; hashing what they are '
    'built from proves everything that matters. Updated by tool/prebuild.sh.')
json.dump(d, open(p, 'w'), indent=2, sort_keys=True)
print(f"  recorded source_sha256 = {sys.argv[1][:16]}…")
PY
  exit 0
fi

if [ ! -f "$RECORD" ]; then
  echo "FAIL: $RECORD is missing — cannot tell whether the assets are current."
  exit 1
fi

WANT=$(python3 -c "import json;print(json.load(open('$RECORD')).get('source_sha256',''))")

if [ -z "$WANT" ]; then
  echo "FAIL: $RECORD has no source_sha256."
  echo "  Run: bash tool/prebuild.sh   (or: bash tool/check_asset_freshness.sh --update)"
  exit 1
fi

if [ "$HAVE" != "$WANT" ]; then
  echo "FAIL: the committed assets in lib/assets/ are STALE."
  echo "  asset sources hash to : $HAVE"
  echo "  assets were built from: $WANT"
  echo
  echo "  Something under native/src, native/Cargo.{toml,lock} or js/src changed"
  echo "  since the assets were last built, so the FFI path is running your"
  echo "  change and the WASM path is running the old one. That divergence is"
  echo "  invisible to \`git diff\` — the wasm build is not byte-reproducible."
  echo
  echo "  Fix:  bash tool/prebuild.sh   (rebuilds and re-records)"
  exit 1
fi

echo "OK: committed assets match their sources ($HAVE)"
