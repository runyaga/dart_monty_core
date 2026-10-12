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

if [ "${1:-}" = "--print" ]; then
  echo "$dest"
  exit 0
fi

target_dir="${CARGO_TARGET_DIR:-native/worker/target}"
(cd native/worker && cargo build --locked --release --bin dart_monty_worker)

mkdir -p "$(dirname "$dest")"
cp "$target_dir/release/$exe" "$dest"
chmod +x "$dest"
echo "build_worker: $dest"
