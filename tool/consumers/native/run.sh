#!/usr/bin/env bash
# Native consumer and executable-trust probes. This intentionally has no hook
# opt-in: successful runs prove the locator used the package-relative worker.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../../.." && pwd)"
TRUST_ONLY=false
[ "${1:-}" = "--trust-only" ] && TRUST_ONLY=true

case "$(uname -s)" in
  Darwin) OS=macos ;;
  Linux) OS=linux ;;
  MINGW* | MSYS* | CYGWIN*) OS=windows ;;
  *) OS=unknown ;;
esac
case "$(uname -m)" in
  x86_64 | amd64) ARCH=x64 ;;
  arm64 | aarch64) ARCH=arm64 ;;
  *) ARCH=unknown ;;
esac
EXE=dart_monty_worker
LIB=libdart_monty_worker.so
[ "$OS" = macos ] && LIB=libdart_monty_worker.dylib
[ "$OS" = windows ] && { EXE=dart_monty_worker.exe; LIB=dart_monty_worker.dll; }
WORKER="$ROOT/lib/src/bin/$OS-$ARCH/$EXE"
LIBRARY="$ROOT/lib/src/bin/$OS-$ARCH/$LIB"
FAILED=0
CONSUMER_HOME=
cleanup() { [ -z "$CONSUMER_HOME" ] || rm -rf "$CONSUMER_HOME"; }
trap cleanup EXIT

flat() { tr '\r\n' ' ' | tr -s ' ' | cut -c1-700; }
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
probe() {
  local name=$1 output status
  shift
  output=$("$@" 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    printf 'PROBE %s pass %s\n' "$name" "$(printf '%s' "$output" | flat)"
  else
    printf 'PROBE %s fail exit=%s %s\n' "$name" "$status" "$(printf '%s' "$output" | flat)"
    FAILED=1
  fi
}

run_consumer() {
  local home=$1 start end
  start=$(now_ms)
  (cd "$HERE" && HOME="$home" USERPROFILE="$home" LOCALAPPDATA="$home" dart run bin/consumer.dart)
  local status=$?
  end=$(now_ms)
  printf 'wall-ms=%s exit=%s\n' "$((end - start))" "$status"
  return "$status"
}

cold() {
  local output status start end
  CONSUMER_HOME=$(mktemp -d)
  start=$(now_ms)
  output=$(cd "$HERE" && HOME="$CONSUMER_HOME" USERPROFILE="$CONSUMER_HOME" LOCALAPPDATA="$CONSUMER_HOME" dart pub get 2>&1)
  status=$?
  if [ "$status" -eq 0 ]; then
    output="$output $(run_consumer "$CONSUMER_HOME")"
    status=$?
  fi
  end=$(now_ms)
  printf 'wall-ms=%s %s\n' "$((end - start))" "$output"
  return "$status"
}

warm() {
  local times=() i value ordered
  [ -n "$CONSUMER_HOME" ] || return 1
  for i in 1 2 3 4 5; do
    value=$(run_consumer "$CONSUMER_HOME") || return 1
    value=$(printf '%s\n' "$value" | sed -n 's/^wall-ms=\([0-9][0-9]*\).*/\1/p')
    times+=("$value")
  done
  ordered=$(printf '%s\n' "${times[@]}" | sort -n)
  set -- $ordered
  printf 'min-ms=%s median-ms=%s max-ms=%s\n' "$1" "$3" "$5"
}

other_cwd() {
  [ -n "$CONSUMER_HOME" ] || return 1
  (cd "$ROOT" && HOME="$CONSUMER_HOME" USERPROFILE="$CONSUMER_HOME" LOCALAPPDATA="$CONSUMER_HOME" \
    dart run --directory=tool/consumers/native bin/consumer.dart)
}

aot_bundle() {
  local temp bundle home input status
  temp=$(mktemp -d)
  bundle="$temp/bundle"
  input="$ROOT/tool/aot_worker/s10_external_call.json"
  (cd "$ROOT/tool/aot_worker" && dart pub get && dart build cli -o "$bundle") || { rm -rf "$temp"; return 1; }
  "$bundle/bin/aot_worker${EXE#dart_monty_worker}" "$input" || { rm -rf "$temp"; return 1; }
  cp -R "$bundle" "$temp/relocated" || { rm -rf "$temp"; return 1; }
  home=$(mktemp -d)
  (cd "$temp" && HOME="$home" USERPROFILE="$home" LOCALAPPDATA="$home" \
    "$temp/relocated/bin/aot_worker${EXE#dart_monty_worker}" "$input")
  status=$?
  rm -rf "$home" "$temp"
  return "$status"
}

exec_bit() {
  local mode
  if [ "$OS" = macos ]; then mode=$(stat -f '%Lp' "$WORKER"); else mode=$(stat -c '%a' "$WORKER"); fi
  [ -x "$WORKER" ] && [ "$mode" = 755 ]
}
sizes() { wc -c "$WORKER" "$LIBRARY"; }

trust() {
  local line name detail output status seen=0
  output=$(cd "$HERE" && dart pub get >/dev/null && dart run trust_probe.dart "$@" 2>&1)
  status=$?
  while IFS= read -r line; do
    case "$line" in
      *'TRUST '*)
        name=${line#*TRUST }
        detail=${name#* }
        name=${name%% *}
        printf 'PROBE trust-%s pass %s\n' "$name" "$detail"
        seen=1
        ;;
    esac
  done <<EOF
$output
EOF
  if [ "$seen" -eq 0 ]; then
    printf 'PROBE trust-run pass exit=%s %s\n' "$status" "$(printf '%s' "$output" | flat)"
  fi
}

printf 'platform=%s-%s\n' "$OS" "$ARCH"
dart --version 2>&1
if command -v rustc >/dev/null 2>&1; then rustc --version; else echo 'rustc=unavailable'; fi
if [ "$OS" = windows ]; then
  powershell -NoProfile -Command '(Get-CimInstance Win32_OperatingSystem).Caption' 2>&1
else
  uname -a
fi

if [ "$TRUST_ONLY" = true ]; then
  trust --hook-only
  exit 0
fi
if [ ! -f "$WORKER" ] || [ ! -f "$LIBRARY" ]; then
  echo "worker missing at $WORKER; rerun after bash tool/build_worker.sh" >&2
  exit 2
fi

probe dart-run-cold cold
probe dart-run-warm warm
probe dart-run-other-cwd other_cwd
probe aot-bundle aot_bundle
if [ "$OS" != windows ]; then probe exec-bit exec_bit; fi
probe size sizes
trust
exit "$FAILED"
