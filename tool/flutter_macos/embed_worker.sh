#!/usr/bin/env bash
# Embed dart_monty_core's macOS arm64 worker in a Flutter app bundle.
#
# Use this as an Xcode Run Script phase after Flutter builds the app:
#
#   bash "${SRCROOT}/tool/flutter_macos/embed_worker.sh" \
#     --worker "${SRCROOT}/lib/src/bin/macos-arm64/dart_monty_worker" \
#     --sha256 "<release-asset-sha256>"
#
# The script obtains the app from BUILT_PRODUCTS_DIR and
# CONTENTS_FOLDER_PATH in that form, or accepts --app <App.app> from a shell.
# It deliberately requires the worker's digest: core does not publish a
# package-relative macOS worker. A universal Flutter release build is fine;
# this arm64 helper is copied into Contents/Helpers, not made by a native-asset
# hook output.

set -euo pipefail

prefix='flutter_macos/embed_worker'

fail() {
  printf '%s: %s\n' "$prefix" "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
Usage:
  embed_worker.sh --worker <path> --sha256 <64-hex> [--app <App.app>] [--resign-app]
  embed_worker.sh --check <App.app>

--resign-app seals the app again after the copy. Use it when the helper is
added to an app that was already signed (a shell step after the build). An
Xcode Run Script phase placed before the code-sign phase does not need it.

Without --app, embedding reads BUILT_PRODUCTS_DIR and CONTENTS_FOLDER_PATH
as supplied by Xcode's Run Script build phase.
EOF
}

sha256_of() {
  shasum -a 256 < "$1" | awk '{print $1}'
}

app_from_xcode() {
  [ -n "${BUILT_PRODUCTS_DIR:-}" ] || \
    fail 'missing --app and BUILT_PRODUCTS_DIR is not set'
  [ -n "${CONTENTS_FOLDER_PATH:-}" ] || \
    fail 'missing --app and CONTENTS_FOLDER_PATH is not set'

  case "$CONTENTS_FOLDER_PATH" in
    *.app/Contents)
      printf '%s/%s\n' "$BUILT_PRODUCTS_DIR" \
        "${CONTENTS_FOLDER_PATH%/Contents}"
      ;;
    *)
      fail "CONTENTS_FOLDER_PATH is not an app Contents path: $CONTENTS_FOLDER_PATH"
      ;;
  esac
}

check_bundle() {
  local app=$1 helper
  helper="$app/Contents/Helpers/dart_monty_worker"

  [ -d "$app" ] || fail "app bundle does not exist: $app"
  [ -f "$helper" ] || fail "worker helper is missing: $helper"
  [ -x "$helper" ] || fail "worker helper is not executable: $helper"
  if ! codesign --verify --strict "$helper"; then
    fail "worker helper is not validly signed: $helper"
  fi

  printf '%s: helper is present, executable, and signed: %s\n' "$prefix" \
    "$helper"
}

mode=embed
app=''
worker=''
expected_sha256=''
resign=0
embed_option_seen=0

embedding_option() {
  [ "$mode" != check ] || \
    fail '--check cannot be combined with embedding options'
  embed_option_seen=1
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --app)
      [ "$#" -ge 2 ] || fail '--app needs an App.app path'
      app=$2
      shift 2
      ;;
    --worker)
      [ "$#" -ge 2 ] || fail '--worker needs a path'
      embedding_option
      worker=$2
      shift 2
      ;;
    --sha256)
      [ "$#" -ge 2 ] || fail '--sha256 needs a 64-hex digest'
      embedding_option
      expected_sha256=$2
      shift 2
      ;;
    --resign-app)
      embedding_option
      resign=1
      shift
      ;;
    --check)
      [ "$#" -ge 2 ] || fail '--check needs an App.app path'
      [ "$embed_option_seen" -eq 0 ] || \
        fail '--check cannot be combined with embedding options'
      [ "$mode" = embed ] || fail '--check cannot be combined with embedding options'
      mode=check
      app=$2
      shift 2
      ;;
    --help | -h)
      usage
      exit 0
      ;;
    *)
      fail "unknown argument: $1 (run with --help)"
      ;;
  esac
done

if [ "$mode" = check ]; then
  [ -n "$app" ] || fail '--check needs an App.app path'
  check_bundle "$app"
  exit 0
fi

[ -n "$worker" ] || fail '--worker is required'
[ -n "$expected_sha256" ] || fail '--sha256 is required'
[ -f "$worker" ] || fail "worker file does not exist: $worker"
if ! printf '%s\n' "$expected_sha256" | grep -Eq '^[[:xdigit:]]{64}$'; then
  fail "--sha256 must be exactly 64 hexadecimal characters: $expected_sha256"
fi
expected_sha256=$(printf '%s' "$expected_sha256" | tr '[:upper:]' '[:lower:]')

actual_sha256=$(sha256_of "$worker")
if [ "$actual_sha256" != "$expected_sha256" ]; then
  fail "worker SHA-256 mismatch for $worker: expected $expected_sha256, actual $actual_sha256"
fi

if ! architectures=$(lipo -archs "$worker" 2>&1); then
  fail "worker is not a Mach-O file: $worker ($architectures)"
fi
if [ "$architectures" != arm64 ]; then
  fail "worker must be a thin arm64 Mach-O: $worker has '$architectures'. A universal Flutter release build is fine because this helper is not a hook output."
fi
if ! mach_header=$(otool -hv "$worker" 2>&1); then
  fail "worker Mach-O header could not be read: $worker ($mach_header)"
fi
if ! printf '%s\n' "$mach_header" | awk '$5 == "EXECUTE" { found = 1 } END { exit !found }'; then
  fail "worker must be a Mach-O executable (file type EXECUTE), not a dylib or bundle: $worker"
fi

if [ -z "$app" ]; then
  app=$(app_from_xcode)
fi
[ -d "$app" ] || fail "app bundle does not exist: $app"

helpers="$app/Contents/Helpers"
helper="$helpers/dart_monty_worker"
mkdir -p "$helpers"
temporary="$helpers/.dart_monty_worker.$$.tmp"
cleanup() {
  rm -f "$temporary"
}
trap cleanup EXIT HUP INT TERM

cp "$worker" "$temporary"
chmod 755 "$temporary"
identity=${EXPANDED_CODE_SIGN_IDENTITY:-}
if [ -n "$identity" ] && [ "$identity" != '-' ]; then
  codesign --force --sign "$identity" --identifier io.dart-monty.worker \
    --options runtime "$temporary"
else
  codesign --force --sign - --identifier io.dart-monty.worker "$temporary"
fi
mv -f "$temporary" "$helper"
trap - EXIT HUP INT TERM

if [ "$resign" -eq 1 ]; then
  if [ -n "$identity" ] && [ "$identity" != '-' ]; then
    codesign --force --sign "$identity" --options runtime "$app"
  else
    codesign --force --sign - "$app"
  fi
fi

printf '%s: embedded signed arm64 worker at %s\n' "$prefix" "$helper"
