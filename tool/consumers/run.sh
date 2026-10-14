#!/usr/bin/env bash
# =============================================================================
# Consumer-startup probes: a real app, built the way a consumer builds it,
# starts the worker pool with no workerLocation and no init call, runs `1 + 1`
# in headless Chrome, and reads 2.
# =============================================================================
# Four builds, two layouts:
#   dart-js        dart compile js,    package layout  (packages/dart_monty_core/assets/)
#   dart-wasm      dart compile wasm,  package layout
#   flutter        flutter build web,         Flutter layout (assets/packages/dart_monty_core/lib/assets/)
#   flutter-wasm   flutter build web --wasm,  Flutter layout
# The Dart builds have no tool that lays out package assets, so this script
# copies core's lib/assets/ worker files to where `dart run webdev serve` and
# `dart test` serve them. The Flutter builds get theirs from core's own
# `flutter: assets:` declaration (the probe declares none).
#
# Before the cutover the apps import the internal pool, the entry point the
# parity adapter uses. The cutover PR switches the two imports to
# `package:dart_monty_core/dart_monty_core.dart` and the call to `Monty.start`.
#
# Usage:
#   bash tool/consumers/run.sh selftest
#   bash tool/consumers/run.sh <dart-js|dart-wasm|flutter|flutter-wasm|all>
#        [--negative remove-assets|remove-wasm|break-path]
# A negative run damages the build output after the build, and passes only if
# the driver FAILS (exit 1). Output goes to tool/consumers/build/ (ignored).
# CHROME=<path> picks the browser; otherwise it is looked up on PATH.
# =============================================================================
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
OUT_ROOT="$HERE/build"
PROTO_ASSETS=(dart_monty_core_proto_worker.js dart_monty_core_proto_worker.wasm)

fail() { echo "FAIL: $*"; exit 1; }

drive() { node "$HERE/drive.mjs" "$@"; }

# expect_reject <why-pattern> <driver args...>: the driver must exit 1 AND say
# why, so a driver that fails for another reason (a crash, Chrome missing)
# cannot pass as "rejected".
expect_reject() {
  local why=$1 log rc
  shift
  log=$(drive "$@" 2>&1)
  rc=$?
  [ "$rc" -eq 1 ] || fail "driver self-test: exited $rc, expected 1 ($*)"
  printf '%s\n' "$log" | grep -q "FAIL: .*$why" || fail "driver self-test: no '$why' in the verdict ($*)"
  printf '%s\n' "$log" | grep -q "driver error" && fail "driver self-test: a driver error, not a verdict ($*)"
  echo "  selftest: rejected for '$why' ($*)"
}

selftest() {
  drive --root "$HERE/selftest" --page ok.html --skip-assets >/dev/null || fail "driver self-test: a page that writes 2 was rejected"
  expect_reject "no result written" --root "$HERE/selftest" --page never.html --skip-assets --timeout 3000
  expect_reject "expected \"2\"" --root "$HERE/selftest" --page wrong.html --skip-assets --timeout 3000
  expect_reject "console.error: boom" --root "$HERE/selftest" --page error.html --skip-assets --timeout 3000
  # A page that writes 2 but never fetches the worker assets must fail the
  # asset check when one is asked for.
  expect_reject "was not served 200" --root "$HERE/selftest" --page ok.html --layout package --timeout 3000
  echo "PASS selftest"
}

build() { # build <name> <outdir>
  local name=$1 out=$2
  /bin/rm -rf "$out" && mkdir -p "$out" || return 1
  case "$name" in
    dart-js | dart-wasm)
      local app="$HERE/dart_web"
      (cd "$app" && dart pub get) || return 1
      if [ "$name" = dart-js ]; then
        (cd "$app" && dart compile js -O2 web/main.dart -o "$out/main.js") || return 1
        cp "$app/web/index.html" "$out/index.html"
      else
        (cd "$app" && dart compile wasm web/main.dart -o "$out/main.wasm") || return 1
        cp "$app/web/index_wasm.html" "$out/index.html"
      fi
      mkdir -p "$out/packages/dart_monty_core/assets"
      for f in "${PROTO_ASSETS[@]}"; do cp "$ROOT/lib/assets/$f" "$out/packages/dart_monty_core/assets/$f"; done
      ;;
    flutter | flutter-wasm)
      local app="$HERE/flutter_web" flags=(--release --no-web-resources-cdn)
      [ "$name" = flutter-wasm ] && flags+=(--wasm)
      (cd "$app" && flutter pub get && flutter build web "${flags[@]}" --output "$out") || return 1
      ;;
  esac
}

layout_of() { case "$1" in dart-*) echo package ;; *) echo flutter ;; esac; }
base_of() { case "$1" in dart-*) echo packages/dart_monty_core/assets ;; *) echo assets/packages/dart_monty_core/lib/assets ;; esac; }

damage() { # damage <name> <outdir> <mode>
  local base="$2/$(base_of "$1")"
  [ -f "$base/${PROTO_ASSETS[0]}" ] || fail "negative control: no worker script at $base (the build did not ship it)"
  case "$3" in
    remove-assets) /bin/rm -f "$base/${PROTO_ASSETS[0]}" "$base/${PROTO_ASSETS[1]}" ;;
    remove-wasm) /bin/rm -f "$base/${PROTO_ASSETS[1]}" ;;
    break-path) mv "$base" "${base}_moved" ;;
    *) fail "unknown --negative mode $3" ;;
  esac
}

run_one() { # run_one <name> <negative-mode|"">
  local name=$1 mode=$2 out="$OUT_ROOT/$1"
  echo "=== $name${mode:+ (negative: $mode)} ==="
  local t0=$SECONDS
  build "$name" "$out" || fail "$name: build failed"
  echo "  build: $((SECONDS - t0))s"
  [ -z "$mode" ] || damage "$name" "$out" "$mode"
  drive --root "$out" --layout "$(layout_of "$name")" --timeout 45000
  local rc=$?
  if [ -z "$mode" ]; then
    [ "$rc" -eq 0 ] || fail "$name: the probe did not read 2"
    echo "PASS $name"
  else
    [ "$rc" -eq 1 ] || fail "$name ($mode): the driver exited $rc, expected 1 (a damaged build must fail)"
    echo "PASS $name ($mode): failed as it must"
  fi
}

[ $# -ge 1 ] || fail "usage: run.sh selftest | <dart-js|dart-wasm|flutter|flutter-wasm|all> [--negative mode]"
target=$1; shift
mode=""
if [ "${1:-}" = "--negative" ]; then mode=${2:?--negative needs a mode}; fi

if [ "$target" = selftest ]; then selftest; exit $?; fi
if [ "$target" = all ]; then targets=(dart-js dart-wasm flutter flutter-wasm); else targets=("$target"); fi
rc=0
for t in "${targets[@]}"; do
  case "$t" in dart-js | dart-wasm | flutter | flutter-wasm) ;; *) fail "unknown target $t" ;; esac
  run_one "$t" "$mode" || rc=1
done
exit $rc
