#!/usr/bin/env bash
# Host only: preinstalled Dart, Node >=22, Chrome and cached pub dependencies.
set -euo pipefail
[[ "${1:---offline}" == --offline && $# -le 1 ]] || { echo 'usage: bash tool/test_pages.sh [--offline]'; exit 2; }
export PUB_CACHE="${PUB_CACHE:-$PWD/.cache/pub}"
python3 -B tool/build_pages.py
rc=0
for compiler in js wasm; do
  for headers in on off; do
    args=()
    for entry in repl_demo feature_matrix; do
      if [[ "$compiler" == js ]]; then
        args+=(--require "/repl/$entry.js" --forbid "/repl/$entry.wasm")
      else
        args+=(--require "/repl/$entry.wasm" --require "/repl/$entry.mjs" --forbid "/repl/$entry.js")
      fi
    done
    if ! node tool/drive_pages.mjs --root site --layout package --page "repl/index_$compiler.html" --compiler "$compiler" --headers "$headers" --timeout 120000 "${args[@]}"; then
      rc=1
    fi
  done
done
exit "$rc"
