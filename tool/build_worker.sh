#!/usr/bin/env bash
#
# build_worker.sh — build the worker executable and host mount-service cdylib.
#
# Builds native/worker's executable and cdylib in one Cargo invocation
# (release profile, the shipped codegen) and copies both next to each other:
#
#   lib/src/bin/<os>-<arch>/dart_monty_worker[.exe]
#   lib/src/bin/<os>-<arch>/libdart_monty_worker.{dylib,so} (Windows: .dll)
#
# which is where lib/src/worker/worker_locator.dart looks for it under
# `dart test` and `dart run`. The directory is gitignored and pubignored: in
# this release the worker is a contributor and CI artefact, not something
# consumers receive.
#
#   bash tool/build_worker.sh            # build, then copy
#   bash tool/build_worker.sh --print    # print both destination paths
#   bash tool/build_worker.sh --check    # fail unless the copy is fresh
#
# Next to the executable it writes <exe>.stamp: a hash of every build input
# (native/worker sources, manifest, lock, build script, toolchain file) and
# of both binaries. --check recomputes all three, so the gate's worker_vm
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
case "$os" in
  macos) library=libdart_monty_worker.dylib ;;
  linux) library=libdart_monty_worker.so ;;
  windows) library=dart_monty_worker.dll ;;
esac
lib_dest="lib/src/bin/$os-$arch/$library"

stamp="$dest.stamp"

sha() { shasum -a 256 | awk '{print $1}'; }

# Every input of the build: source paths and bytes, sorted, then the
# compiler and its settings.
build_inputs() {
  {
    find native/worker/src native/worker/upstream -type f -print
    # Cargo configuration native/worker inherits, as well as its own. (A
    # CARGO_HOME config is hashed by content below: it lives outside the
    # repository, so its path would differ between machines.)
    find .cargo native/.cargo native/worker/.cargo -maxdepth 1 -type f \
      -name 'config*' -print 2>/dev/null || true
    printf '%s\n' native/worker/Cargo.toml native/worker/Cargo.lock \
      native/worker/build.rs native/rust-toolchain.toml tool/build_worker.sh
  } | LC_ALL=C sort | while read -r f; do
    printf '%s %s\n' "$f" "$(sha < "$f")"
  done
  # The compiler Cargo will use (RUSTC if set, else the toolchain file's,
  # which a floating `stable` moves) and every environment setting Cargo
  # reads that changes codegen: the tested binary must be the one these
  # settings build. CARGO_TARGET_DIR and CARGO_HOME are locations, not
  # settings, and stay out.
  (cd native/worker && "${RUSTC:-rustc}" -vV) || echo "rustc unavailable"
  env | LC_ALL=C sort | grep -E \
    '^(RUSTC(_WRAPPER|_WORKSPACE_WRAPPER)?|RUSTFLAGS|CARGO_ENCODED_RUSTFLAGS|CARGO_BUILD_[A-Z_]+|CARGO_PROFILE_[A-Z_]+|CARGO_TARGET_[A-Z0-9_]+_(RUSTFLAGS|LINKER))=' \
    || true
  for f in "${CARGO_HOME:-$HOME/.cargo}"/config "${CARGO_HOME:-$HOME/.cargo}"/config.toml; do
    [ -f "$f" ] && printf 'cargo-home %s\n' "$(sha < "$f")"
  done
  return 0
}

source_hash() { build_inputs | sha; }

stamp_line() {
  printf 'source %s exe %s lib %s\n' "$(source_hash)" "$(sha < "$dest")" "$(sha < "$lib_dest")"
}

case "${1:-}" in
  --print)
    printf '%s\n' "$dest" "$lib_dest"
    exit 0
    ;;
  --check)
    if [ ! -f "$dest" ] || [ ! -f "$lib_dest" ] || [ ! -f "$stamp" ]; then
      echo "build_worker: missing worker, library or stamp at $(dirname "$dest"). Run: bash tool/build_worker.sh" >&2
      exit 1
    fi
    if [ "$(stamp_line)" != "$(cat "$stamp")" ]; then
      echo "build_worker: $dest is STALE: a build input (source, Cargo config," >&2
      echo "  compiler, flags) changed, or a binary was replaced." >&2
      echo "  Run: bash tool/build_worker.sh" >&2
      exit 1
    fi
    echo "build_worker: $dest and $lib_dest are fresh"
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
  cargo build --locked --release --bin dart_monty_worker --lib \
  --message-format=json-render-diagnostics |
  python3 -I -c 'import json, sys
messages = [m for m in map(json.loads, sys.stdin)
            if m.get("reason") == "compiler-artifact"
            and m["target"]["name"] == "dart_monty_worker"]
exes = [m["executable"] for m in messages if m.get("executable")]
libs = [p for m in messages if "cdylib" in m["target"]["crate_types"]
        for p in m["filenames"] if p.endswith((".dylib", ".so", ".dll"))]
if len(exes) != 1 or len(libs) != 1:
    sys.exit("build_worker: expected exactly one executable and one cdylib")
print(exes[0])
print(libs[0])')"
built_exe="$(printf '%s\n' "$built" | sed -n '1p')"
built_lib="$(printf '%s\n' "$built" | sed -n '2p')"

mkdir -p "$(dirname "$dest")"
cp "$built_exe" "$dest"
cp "$built_lib" "$lib_dest"
chmod +x "$dest"
stamp_line > "$stamp"
printf 'build_worker: %s\n' "$dest" "$lib_dest"
