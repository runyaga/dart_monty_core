#!/usr/bin/env bash
# =============================================================================
# Generate FFI bindings for dart_monty_core
# =============================================================================
# Runs dart run ffigen and post-formats the generated file.
# Output: lib/src/ffi/generated/dart_monty_bindings.dart
# Usage: bash tool/generate_bindings.sh
# =============================================================================
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

echo "--- dart pub get ---"
dart pub get

echo "--- dart run ffigen ---"
dart run ffigen --config ffigen.yaml

echo "--- dart format (generated) ---"
dart format --line-length=80 lib/src/ffi/generated/

echo "=== Bindings generated ==="
