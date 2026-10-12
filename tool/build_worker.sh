#!/usr/bin/env bash
#
# build_worker.sh — build the worker executable for this host.
#
# Builds native/worker's `dart_monty_worker` binary (release profile, the
# shipped codegen) and copies it to
#
#   lib/src/bin/<os>-<arch>/dart_monty_worker[.exe]
#
# which is where lib/src/worker/worker_locator.dart looks for it under
# `dart test` and `dart run`. The directory is gitignored and pubignored: in
# this release the worker is a contributor and CI artefact, not something
# consumers receive.
#
#   bash tool/build_worker.sh            # build, then copy
#   bash tool/build_worker.sh --print    # print the destination path only
#   bash tool/build_worker.sh --check    # fail unless the copy is fresh
#
# Next to the executable it writes <exe>.stamp: a hash of every build input
# (native/worker sources, manifest, lock, build script, toolchain file) and
# of the executable itself. --check recomputes both, so the gate's worker_vm
# step cannot pass against a stale build, or one whose source no longer
# compiles, or a binary swapped in by hand.
#
# Then: dart test test/integration/worker -p vm --tags=worker
#
# Requires: rustup (native/rust-toolchain.toml selects the toolchain).

set -euo pipefail

cd "$(dirname "$0")/.."

case "$(uname -s)" in
  Darwin) os=macos ;;
  Linux) os=linux ;;
  MINGW* | MSYS* | CYGWIN*) os=windows ;;
  *) echo "build_worker: unsupported OS $(uname -s)" >&2; exit 2 ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) arch=x64 ;;
  arm64 | aarch64) arch=arm64 ;;
  *) echo "build_worker: unsupported architecture $(uname -m)" >&2; exit 2 ;;
esac
exe=dart_monty_worker
[ "$os" = windows ] && exe=dart_monty_worker.exe
dest="lib/src/bin/$os-$arch/$exe"

stamp="$dest.stamp"

sha() { shasum -a 256 | awk '{print $1}'; }

# Every input of the build, by content: paths and bytes, sorted.
source_hash() {
  {
    find native/worker/src native/worker/upstream -type f -print
    # Cargo configuration native/worker inherits, as well as its own.
    find native/.cargo native/worker/.cargo -maxdepth 1 -type f \
      -name 'config*' -print 2>/dev/null || true
    printf '%s\n' native/worker/Cargo.toml native/worker/Cargo.lock \
      native/worker/build.rs native/rust-toolchain.toml
  } | LC_ALL=C sort | while read -r f; do
    printf '%s %s\n' "$f" "$(sha < "$f")"
  done | sha
}

stamp_line() { printf 'source %s exe %s\n' "$(source_hash)" "$(sha < "$dest")"; }

case "${1:-}" in
  --print)
    echo "$dest"
    exit 0
    ;;
  --check)
    if [ ! -f "$dest" ] || [ ! -f "$stamp" ]; then
      echo "build_worker: no worker at $dest. Run: bash tool/build_worker.sh" >&2
      exit 1
    fi
    if [ "$(stamp_line)" != "$(cat "$stamp")" ]; then
      echo "build_worker: $dest is STALE: native/worker changed since it was" >&2
      echo "  built, or the executable was replaced. Run: bash tool/build_worker.sh" >&2
      exit 1
    fi
    echo "build_worker: $dest is fresh"
    exit 0
    ;;
  "") ;;
  *) echo "usage: build_worker.sh [--print|--check]" >&2; exit 2 ;;
esac

# One absolute target directory for Cargo and for the copy: a relative
# CARGO_TARGET_DIR would resolve against native/worker for Cargo but against
# the repository root here.
target_dir="${CARGO_TARGET_DIR:-native/worker/target}"
case "$target_dir" in
  /*) ;;
  *) target_dir="$PWD/$target_dir" ;;
esac
# The executable Cargo reports for THIS build, not a path guessed from the
# target directory: with CARGO_BUILD_TARGET set it lands under
# <target>/<triple>/release/, and a guess would copy, and stamp as fresh, an
# older binary.
built="$(cd native/worker && CARGO_TARGET_DIR="$target_dir" \
  cargo build --locked --release --bin dart_monty_worker \
  --message-format=json-render-diagnostics |
  python3 -I -c 'import json, sys
paths = [m["executable"] for m in map(json.loads, sys.stdin)
         if m.get("reason") == "compiler-artifact" and m.get("executable")
         and m["target"]["name"] == "dart_monty_worker"]
sys.exit("build_worker: cargo reported no dart_monty_worker executable") if len(paths) != 1 else print(paths[0])')"

mkdir -p "$(dirname "$dest")"
cp "$built" "$dest"
chmod +x "$dest"
stamp_line > "$stamp"
echo "build_worker: $dest"
