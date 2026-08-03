#!/usr/bin/env bash
# =============================================================================
# tool/check_wire_version.sh — the Rust and Dart wire-format versions agree
# =============================================================================
# The value encoding is versioned by WIRE_FORMAT_VERSION in native/src/convert.rs
# and asserted at init on both backends, so a stale committed asset fails loudly
# instead of mis-decoding values. Rust is the single source of truth: the C ABI
# exports it (native/src/lib.rs), and the JS worker reads it out of the wasm at
# runtime rather than restating it.
#
# One copy remains: `expectedWireFormatVersion` in lib/src/ffi/native_bindings.dart.
# It has to be a compile-time constant on the Dart side, so it cannot be read
# from the crate — which makes it the one place where the handshake depends on an
# author remembering to bump two files together. That is exactly the class of
# unenforced invariant the handshake was built to replace, so this checks it.
#
# It runs in the gate and in CI, and needs no toolchain: two greps.
#
# Usage: bash tool/check_wire_version.sh
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

RUST_FILE=native/src/convert.rs
DART_FILE=lib/src/ffi/native_bindings.dart

# A single capturing match per side, anchored on the trailing `;`.
#
# The semicolon is load-bearing. Without it the pattern takes the first number
# and ignores whatever follows, so `= 1 + 1` reads as 1 and the check reports
# agreement with a value nothing holds. Measured, not imagined: the first version
# of this script passed that exact mutation. Requiring the semicolon means any
# rewording fails the READ instead, which is handled below.
#
# Capturing rather than `grep -o` for the same reason in a different disguise:
# the Rust line contains `u32`, so extracting "the digits" from it yields 32 as
# well as the version.
rust=$(sed -nE 's/^pub const WIRE_FORMAT_VERSION: u32 = ([0-9]+);$/\1/p' \
       "$RUST_FILE")
dart=$(sed -nE 's/^const int expectedWireFormatVersion = ([0-9]+);$/\1/p' \
       "$DART_FILE")

# An empty capture means the declaration moved or was reworded, which would make
# this check silently vacuous — the failure mode it exists to prevent. Treat it
# as a failure and say which side could not be read.
if [ -z "$rust" ]; then
  echo "FAIL: could not read WIRE_FORMAT_VERSION from $RUST_FILE."
  echo "      The declaration moved or was reworded. Fix the pattern in this"
  echo "      script — do not delete the check."
  exit 1
fi
if [ -z "$dart" ]; then
  echo "FAIL: could not read expectedWireFormatVersion from $DART_FILE."
  echo "      The declaration moved or was reworded. Fix the pattern in this"
  echo "      script — do not delete the check."
  exit 1
fi

if [ "$rust" != "$dart" ]; then
  echo "FAIL: wire-format version mismatch between the crate and the Dart side."
  echo "  $RUST_FILE: WIRE_FORMAT_VERSION        = $rust"
  echo "  $DART_FILE: expectedWireFormatVersion = $dart"
  echo ""
  echo "These must move in the SAME commit. Bumping only the crate ships a"
  echo "package that rejects its own native library at init; bumping only Dart"
  echo "makes the handshake accept an encoding nothing produces."
  exit 1
fi

echo "OK: wire format v$rust in both $RUST_FILE and $DART_FILE"
