#!/usr/bin/env bash
# =============================================================================
# tool/check_no_dart_io_in_lib.sh — `lib/` does not import dart:io
# =============================================================================
# WHY THIS IS A GATE AND NOT A CONVENTION
#
# `lib/` has never imported `dart:io`, and nothing enforced it. It held only
# because the web suite would fail to compile — which is a real signal, but one
# a `dart.library.io` conditional arm bypasses completely: the io arm compiles
# on the VM, the web compilers take the other arm, every test stays green, and
# the invariant is gone with no failure anywhere. That is precisely the shape
# the worker-channel work (docs/adr/0001-ffi-crash-isolation.md) introduces, so
# the invariant needs a check before the code that can break it silently lands,
# not after.
#
# WHY THIS IS NOT `grep -rn 'dart:io' lib | wc -l`
#
# That was the check people ran by hand, and it is wrong in both directions.
# It counts PROSE: the moment a file documents "this file deliberately does not
# import dart:io", the naive grep reports a violation that does not exist —
# measured, three times over, in lib/src/pool/. And it would equally miss
# nothing-looking real cases, because it never distinguished an import from a
# mention in the first place. Anchor on the import, not on the token.
#
# WHEN THE ARM LANDS
#
# `package:dart_monty_core/pool.dart` will legitimately reach dart:io through a
# `dart.library.io` conditional arm. When it does, add the specific file to
# ALLOWED below WITH A REASON. Widening this to a directory, or deleting it,
# gives up the only thing standing between `lib/` and a web build that breaks
# for a consumer rather than in CI.
#
# Usage: bash tool/check_no_dart_io_in_lib.sh
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

# Files permitted to reach dart:io, each with the reason it is permitted.
# Empty today. Format: one path per line.
ALLOWED=""

# A check that inspects nothing passes trivially, which is the failure mode that
# makes a green gate meaningless. Prove there was something to inspect.
FILE_COUNT=$(find lib -name '*.dart' -type f | wc -l | tr -d ' ')
if [ "$FILE_COUNT" -lt 50 ]; then
  echo "FAIL: found only $FILE_COUNT .dart files under lib/."
  echo "      This check is meant to scan the whole library; that count means"
  echo "      the layout moved and the scan is no longer covering it."
  exit 1
fi

# Anchored on an import/export directive, so prose about the invariant does not
# trip it. Covers both the plain form and a conditional arm:
#   import 'dart:io';
#   export 'x.dart' if (dart.library.io) 'y.dart';
HITS=$(grep -rnE "^[[:space:]]*(import|export)[[:space:]]+'dart:io'|dart\.library\.io" \
       lib --include='*.dart' || true)

if [ -n "$ALLOWED" ]; then
  while IFS= read -r allowed; do
    [ -z "$allowed" ] && continue
    HITS=$(printf '%s\n' "$HITS" | grep -v "^$allowed:" || true)
  done <<< "$ALLOWED"
fi

if [ -n "$HITS" ]; then
  echo "FAIL: lib/ reaches dart:io."
  echo ""
  printf '%s\n' "$HITS"
  echo ""
  echo "lib/ is compiled by dart2js and dart2wasm as well as the VM. A dart:io"
  echo "import that is not behind a dart.library.io arm breaks the web build for"
  echo "a CONSUMER, not here. If this is the deliberate conditional arm for"
  echo "pool.dart, add the file to ALLOWED in this script with its reason."
  exit 1
fi

echo "OK: no dart:io import in lib/ ($FILE_COUNT files scanned)"
