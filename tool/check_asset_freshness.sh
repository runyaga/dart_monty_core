#!/usr/bin/env bash
# =============================================================================
# Are the committed assets stale relative to their sources?
# =============================================================================
# lib/assets/{dart_monty_core_bridge.js,dart_monty_core_worker.js,
# dart_monty_core_native.wasm,dart_monty_core_proto_worker.wasm} are COMMITTED
# build artefacts. The wasm build is NOT byte-reproducible -- an unchanged tree
# yields different bytes -- so `git diff` on the blob can never tell you whether
# the asset matches the crate.
#
# Hashing the OUTPUT is therefore useless. Hashing the INPUT is not: native/src,
# native/Cargo.{toml,lock}, js/src and the build recipes are ordinary files and
# hash deterministically.
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
# TWO RECORDS, because there are two independent builds. `source_sha256` covers
# the in-process engine (native/, js/); `worker_source_sha256` covers the proto
# worker wasm (native/worker/, built by `tool/prebuild.sh --worker-only`). One
# combined hash would let a worker-only rebuild re-record the in-process assets
# as fresh without rebuilding them, and rebuilding them would rewrite committed
# bytes for no source change.
#
# It also fails if any committed lib/assets/*.wasm embeds a build-machine
# absolute path (see leaked_paths below). The recipes remap those away
# (tool/rust_remap.sh); a module built some other way and committed would carry
# the builder's home directory into every published copy of the package.
#
# Usage:
#   bash tool/check_asset_freshness.sh                   # verify both
#   bash tool/check_asset_freshness.sh --update [SCOPE]  # re-record; SCOPE is
#       all (default), native or worker. tool/prebuild.sh does this.
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

RECORD=tool/wasm-provenance.json

# Hashes the files named on stdin (NUL-separated). Order is fixed by
# `LC_ALL=C sort` so the hash is stable across machines: macOS and GNU sort
# collate differently.
hash_files() {
  tr '\0' '\n' | LC_ALL=C sort | while read -r f; do
    [ -f "$f" ] && printf '%s ' "$(shasum -a 256 "$f" | awk '{print $1}')"
  done | shasum -a 256 | awk '{print $1}'
}

# Everything the in-process assets are built FROM, recipe included.
source_hash() {
  {
    find native/src -type f -name '*.rs' -print0 2>/dev/null
    printf '%s\0' native/Cargo.toml native/Cargo.lock native/build.rs \
      tool/build_native_wasm.sh tool/rust_remap.sh js/build.js
    find js/src -type f -name '*.js' -print0 2>/dev/null
  } | hash_files
}

# Everything lib/assets/dart_monty_core_proto_worker.wasm is built FROM: every
# file under native/worker/ (sources, the verbatim upstream copy, manifest,
# lock, build.rs), the toolchain file it shares, and the build recipe (cargo
# profile, wasm-opt flags, path remapping). target/ is build output.
worker_source_hash() {
  {
    find native/worker -path native/worker/target -prune -o -type f -print0 \
      2>/dev/null
    printf '%s\0' native/rust-toolchain.toml tool/build_worker_wasm.sh \
      tool/rust_remap.sh
  } | hash_files
}

# Where build machines keep home directories: macOS, Linux, and Linux root
# (the usual user in a container).
HOME_ROOTS=(Users home root)

# Committed wasm that embeds a build-machine absolute path. Byte-level, so it
# sees panic-location strings inside data segments. Two rules:
#
#   denylist   no HOME_ROOTS directory anywhere, in / or \ form.
#   allowlist  every absolute Rust source path must start with a prefix the
#              recipe remaps to (tool/rust_remap.sh: /cargo/, /rustup/, /src/)
#              or rustc's own (/rustc/<hash>/, /rust/deps/). This catches a
#              toolchain outside any home, such as CARGO_HOME=/opt/rust/cargo,
#              and drive-letter paths.
#
# rustc stores panic-location file names NUL-terminated, so a "path" is a run
# of printable bytes that ends in .rs and starts with / or a drive letter.
leaked_paths() {
  python3 -I - "${HOME_ROOTS[@]}" <<'PY'
import glob, re, sys
deny = [s for r in sys.argv[1:] for s in (f"/{r}/".encode(), f"\\{r}\\".encode())]
allowed = (b"/cargo/", b"/rustup/", b"/src/", b"/rustc/", b"/rust/deps/")
rc = 0
for f in sorted(glob.glob("lib/assets/*.wasm")):
    try:
        data = open(f, "rb").read()
    except OSError as e:
        print(f"FAIL: cannot read {f}: {e}")
        rc = 1
        continue
    hits = sum(data.count(d) for d in deny)
    paths = [t for t in re.split(rb"[^\x20-\x7e]+", data) if t.endswith(b".rs")
             and (t.startswith(b"/") or re.match(rb"[A-Za-z]:[\\/]", t))]
    bad = [t for t in paths if not t.startswith(allowed)]
    if hits or bad:
        print(f"FAIL: {f} embeds build-machine absolute paths: {hits} under a "
              f"home-directory root, {len(bad)} of {len(paths)} source paths "
              "outside the remapped prefixes.")
        rc = 1
if rc:
    print("  Rebuild through the recipe, which remaps them: bash tool/prebuild.sh")
sys.exit(rc)
PY
}

HAVE=$(source_hash)
HAVE_WORKER=$(worker_source_hash)

if [ "${1:-}" = "--update" ]; then
  SCOPE="${2:-all}"
  case "$SCOPE" in
    all|native|worker) ;;
    *) echo "FAIL: --update scope is all, native or worker (got '$SCOPE')"
       exit 2 ;;
  esac
  python3 - "$SCOPE" "$HAVE" "$HAVE_WORKER" <<'PY'
import hashlib, json, sys
scope, have, have_worker = sys.argv[1:4]
p = 'tool/wasm-provenance.json'
try:
    d = json.load(open(p))
except FileNotFoundError:
    d = {}
if scope in ('all', 'native'):
    d['source_sha256'] = have
    for name in ('dart_monty_core_native.wasm', 'dart_monty_core_bridge.js',
                 'dart_monty_core_worker.js'):
        blob = open(f'lib/assets/{name}', 'rb').read()
        d.setdefault('assets', {})[name] = {
            'bytes': len(blob), 'sha256': hashlib.sha256(blob).hexdigest()}
    d['_source_sha256_comment'] = (
        'sha256 over native/src/**.rs, native/Cargo.{toml,lock}, native/build.rs, js/src/**.js, '
        'js/build.js, tool/build_native_wasm.sh and tool/rust_remap.sh -- '
        'the INPUTS to the committed assets. The assets themselves are not '
        'byte-reproducible, so hashing them proves nothing; hashing what they are '
        'built from proves everything that matters. Updated by tool/prebuild.sh.')
    print(f"  recorded source_sha256 = {have[:16]}…")
if scope in ('all', 'worker'):
    name = 'dart_monty_core_proto_worker.wasm'
    blob = open(f'lib/assets/{name}', 'rb').read()
    d.setdefault('assets', {})[name] = {
        'bytes': len(blob), 'sha256': hashlib.sha256(blob).hexdigest()}
    d['worker_source_sha256'] = have_worker
    d['_worker_source_sha256_comment'] = (
        'sha256 over every file under native/worker/ (target/ excluded), '
        'native/rust-toolchain.toml, tool/build_worker_wasm.sh and tool/rust_remap.sh -- the INPUTS to '
        'lib/assets/dart_monty_core_proto_worker.wasm. Updated by '
        'tool/prebuild.sh, either scope.')
    print(f"  recorded worker_source_sha256 = {have_worker[:16]}…")
with open(p, 'w') as fh:
    json.dump(d, fh, indent=2, sort_keys=True)
    fh.write('\n')
PY
  exit $?
fi

PATHS_RC=0
leaked_paths || PATHS_RC=1

if [ ! -f "$RECORD" ]; then
  echo "FAIL: $RECORD is missing — cannot tell whether the assets are current."
  exit 1
fi

recorded() {
  python3 -c "import json,sys;print(json.load(open('$RECORD')).get(sys.argv[1],''))" "$1"
}
WANT=$(recorded source_sha256)
WANT_WORKER=$(recorded worker_source_sha256)

if [ -z "$WANT" ] || [ -z "$WANT_WORKER" ]; then
  echo "FAIL: $RECORD lacks source_sha256 or worker_source_sha256."
  echo "  Run: bash tool/prebuild.sh   (or: bash tool/check_asset_freshness.sh --update)"
  exit 1
fi

if [ "$HAVE" != "$WANT" ]; then
  echo "FAIL: the committed assets in lib/assets/ are STALE."
  echo "  asset sources hash to : $HAVE"
  echo "  assets were built from: $WANT"
  echo
  echo "  Something under native/src, native/Cargo.{toml,lock}, js/src or a recipe"
  echo "  (tool/build_native_wasm.sh, tool/rust_remap.sh, js/build.js) changed"
  echo "  since the assets were last built, so the FFI path is running your"
  echo "  change and the WASM path is running the old one. That divergence is"
  echo "  invisible to \`git diff\` — the wasm build is not byte-reproducible."
  echo
  echo "  Fix:  bash tool/prebuild.sh   (rebuilds and re-records)"
  exit 1
fi

if [ "$HAVE_WORKER" != "$WANT_WORKER" ]; then
  echo "FAIL: lib/assets/dart_monty_core_proto_worker.wasm is STALE."
  echo "  worker sources hash to : $HAVE_WORKER"
  echo "  the wasm was built from: $WANT_WORKER"
  echo
  echo "  Something under native/worker/, native/rust-toolchain.toml or the recipe"
  echo "  (tool/build_worker_wasm.sh, tool/rust_remap.sh) changed since the worker"
  echo "  wasm was last built, so the browser WorkerChannel runs a module that"
  echo "  recipe did not produce."
  echo
  echo "  Fix:  bash tool/prebuild.sh --worker-only   (rebuilds and re-records)"
  exit 1
fi

[ "$PATHS_RC" -eq 0 ] || exit 1

echo "OK: committed assets match their sources ($HAVE)"
echo "OK: proto worker wasm matches native/worker ($HAVE_WORKER)"
echo "OK: no committed wasm embeds a build-machine absolute path"
