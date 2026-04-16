#!/usr/bin/env bash
# =============================================================================
# dart_monty_core — run the Flutter REPL demo locally
#
# Usage:
#   bash tool/run_flutter_demo.sh [--device <device-id>]
#
# Prerequisites:
#   - Flutter SDK installed and in PATH
#   - For native (macOS/Linux/Windows): Rust toolchain for FFI build
#   - For web: npm + Node.js for JS bridge build
#
# The script runs the Flutter app in packages/dart_monty_flutter/ using
# the platform selected by --device (defaults to the first available device).
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
FLUTTER_PKG="$PKG/packages/dart_monty_flutter"
DEVICE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --device) DEVICE="$2"; shift 2 ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if ! command -v flutter &>/dev/null; then
  echo "ERROR: flutter not found. Install Flutter SDK first."
  echo "  See: https://docs.flutter.dev/get-started/install"
  exit 1
fi

echo "=== dart_monty_core Flutter REPL demo ==="
echo ""

cd "$FLUTTER_PKG"

echo "--- flutter pub get ---"
flutter pub get

echo ""
echo "--- flutter run ---"
if [ -n "$DEVICE" ]; then
  flutter run -d "$DEVICE"
else
  flutter run
fi
