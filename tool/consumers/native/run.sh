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
FAILURE_LOG=
TEMP_ROOT=$(mktemp -d) || exit 2
CONSUMER_HOME="$TEMP_ROOT/consumer-home"
PUB_GET_HOME="$TEMP_ROOT/pub-get-home"
cleanup() { rm -rf "$TEMP_ROOT"; }
trap cleanup EXIT

flat() { tail -c 700 | tr '\r\n' ' ' | tr -s ' '; }
now_ms() {
  local value
  if value=$(python3 -c 'import time; print(int(time.time() * 1000))' 2>/dev/null | tr -d '\r') &&
    [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
    return
  fi
  value=$(date +%s 2>/dev/null) || return 1
  printf '%s000\n' "$value"
}
probe() {
  local name=$1 log output status
  shift
  FAILURE_LOG=
  log="$TEMP_ROOT/$name.log"
  if "$@" >"$log" 2>&1; then status=0; else status=$?; fi
  output=$(flat <"$log")
  if [ "$status" -eq 0 ]; then
    printf 'PROBE %s pass %s\n' "$name" "$output"
  else
    printf 'PROBE %s fail exit=%s %s\n' "$name" "$status" "$output"
    if [ -n "$FAILURE_LOG" ]; then
      printf 'PROBE %s failure-log\n' "$name"
      cat "$FAILURE_LOG"
    fi
    FAILED=1
  fi
}

consumer_environment() {
  local home=$1 environment_home=$1
  shift
  if [ "$OS" = windows ] && command -v cygpath >/dev/null 2>&1; then
    environment_home=$(cygpath -w "$home")
  fi
  env HOME="$environment_home" USERPROFILE="$environment_home" \
    LOCALAPPDATA="$environment_home" APPDATA="$environment_home" \
    PUB_CACHE="$environment_home/pub-cache" XDG_CACHE_HOME="$environment_home/cache" \
    XDG_DATA_HOME="$environment_home/data" HOMEDRIVE= HOMEPATH= "$@"
}

run_consumer() {
  local home=$1 start end status
  start=$(now_ms) || return 1
  if (cd "$HERE" && consumer_environment "$home" dart run bin/consumer.dart); then
    end=$(now_ms) || return 1
    printf 'wall-ms=%s\n' "$((end - start))"
    return
  else
    status=$?
  fi
  printf 'consumer command failed exit=%s\n' "$status"
  return "$status"
}

cold() {
  local pub_log="$TEMP_ROOT/cold-pub-get.log" status
  mkdir -p "$CONSUMER_HOME" "$PUB_GET_HOME"
  if (cd "$HERE" && consumer_environment "$PUB_GET_HOME" dart pub get >"$pub_log" 2>&1); then
    :
  else
    status=$?
    FAILURE_LOG="$pub_log"
    printf 'dart pub get failed exit=%s\n' "$status"
    return "$status"
  fi
  run_consumer "$CONSUMER_HOME"
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
  (cd "$ROOT" && consumer_environment "$CONSUMER_HOME" \
    dart run tool/consumers/native/bin/consumer.dart)
}

aot_bundle() {
  local temp="$TEMP_ROOT/aot" bundle home input executable pub_log pub_home status
  mkdir -p "$temp"
  bundle="$temp/bundle"
  input="$ROOT/tool/aot_worker/s10_external_call.json"
  pub_log="$temp/pub-get.log"
  pub_home="$temp/pub-get-home"
  mkdir -p "$pub_home"
  if (cd "$ROOT/tool/aot_worker" && consumer_environment "$pub_home" dart pub get >"$pub_log" 2>&1); then
    :
  else
    status=$?
    FAILURE_LOG="$pub_log"
    printf 'dart pub get failed exit=%s\n' "$status"
    return "$status"
  fi
  (cd "$ROOT/tool/aot_worker" && consumer_environment "$pub_home" dart build cli -o "$bundle") || return 1
  if [ ! -d "$bundle" ]; then
    printf 'aot bundle directory missing: %s\n' "$bundle"
    return 1
  fi
  executable="$bundle/bin/aot_worker${EXE#dart_monty_worker}"
  if [ ! -f "$executable" ]; then
    printf 'aot bundle executable missing: %s\n' "$executable"
    return 1
  fi
  "$executable" "$input" || return 1
  cp -R "$bundle" "$temp/relocated" || return 1
  mv "$bundle" "$temp/original-bundle-moved" || return 1
  home="$temp/empty-home"
  mkdir -p "$home" "$temp/relocated-cwd"
  (cd "$temp/relocated-cwd" && consumer_environment "$home" \
    "$temp/relocated/bin/aot_worker${EXE#dart_monty_worker}" "$input")
}

exec_bit() {
  local mode
  if [ "$OS" = macos ]; then mode=$(stat -f '%Lp' "$WORKER"); else mode=$(stat -c '%a' "$WORKER"); fi
  [ -x "$WORKER" ] && [ "$mode" = 755 ]
}
sizes() { wc -c "$WORKER" "$LIBRARY"; }

trust() {
  local line name detail output status seen=0 pub_log="$TEMP_ROOT/trust-pub-get.log" log="$TEMP_ROOT/trust.log"
  if (cd "$HERE" && dart pub get >"$pub_log" 2>&1); then
    :
  else
    status=$?
    printf 'PROBE trust-run unavailable exit=%s dart-pub-get-failed\n' "$status"
    cat "$pub_log"
    return
  fi
  if (cd "$HERE" && dart run trust_probe.dart "$@" >"$log" 2>&1); then status=0; else status=$?; fi
  output=$(<"$log")
  while IFS= read -r line; do
    case "$line" in
      *'TRUST '*)
        name=${line#*TRUST }
        detail=${name#* }
        name=${name%% *}
        case "$detail" in
          unavailable\ *) printf 'PROBE trust-%s unavailable %s\n' "$name" "${detail#unavailable }" ;;
          *) printf 'PROBE trust-%s pass %s\n' "$name" "$detail" ;;
        esac
        seen=1
        ;;
    esac
  done <<EOF
$output
EOF
  if [ "$status" -ne 0 ]; then
    printf 'PROBE trust-run unavailable exit=%s %s\n' "$status" "$(printf '%s' "$output" | flat)"
  elif [ "$seen" -eq 0 ]; then
    printf 'PROBE trust-run unavailable no-trust-facts %s\n' "$(printf '%s' "$output" | flat)"
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
trust "$WORKER"
exit "$FAILED"
