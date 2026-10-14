#!/usr/bin/env bash
# =============================================================================
# One Dart SDK everywhere: every workflow pin, and the SDK running this check
# =============================================================================
# `dart format` output depends on the SDK that runs it: dart_style ships style
# fixes that are NOT language-versioned, even in SDK patch releases. A file
# formatted locally with one SDK can fail CI's format check under another
# ("format wars"). So every `setup-dart` pin in .github/workflows must name the
# same exact version, and the `dart` on PATH must be that version too.
#
# In CI the second half holds by construction (setup-dart installed the pin).
# Locally it is the check that tells you to switch SDKs BEFORE you format.
#
# Usage: bash tool/check_sdk_pin.sh
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

PINS=$(grep -hE '^[[:space:]]*sdk:[[:space:]]*[0-9]' .github/workflows/*.y*ml \
  | sed -E 's/^[[:space:]]*sdk:[[:space:]]*([^[:space:]#]+).*/\1/' | sort -u)
N=$(printf '%s\n' "$PINS" | grep -c . || true)
if [ "$N" -eq 0 ]; then
  echo "FAIL: no exact setup-dart 'sdk:' pins found in .github/workflows."
  exit 1
fi
if [ "$N" -ne 1 ]; then
  echo "FAIL: workflows pin different Dart SDKs:"
  grep -nE '^[[:space:]]*sdk:[[:space:]]*[0-9]' .github/workflows/*.y*ml | sed 's/^/    /'
  exit 1
fi
PIN=$PINS

LOCAL=$(dart --version 2>&1 | sed -nE 's/^Dart SDK version: ([^ ]+).*/\1/p')
if [ "$LOCAL" != "$PIN" ]; then
  echo "FAIL: dart on PATH is ${LOCAL:-unknown}; CI pins $PIN."
  echo "  dart format output differs between SDK releases, so formatting with"
  echo "  this SDK can fail CI's format check. Switch to $PIN before formatting."
  exit 1
fi

# The Flutter pin: `flutter-version:` in the consumer workflow names a Flutter
# release, and that release must bundle the Dart pinned above, or the Flutter
# consumer probe builds with a different compiler than every other job.
# Flutter releases are not queryable offline, so the check is on the Flutter
# that is installed: when `flutter` is on PATH and is the pinned release, its
# bundled Dart must be $PIN. A different Flutter on a developer machine is
# only a note; in CI (the consumer job installs the pinned release) it fails.
FPINS=$(grep -hE '^[[:space:]]*flutter-version:[[:space:]]*[0-9]' .github/workflows/*.y*ml \
  | sed -E 's/^[[:space:]]*flutter-version:[[:space:]]*([^[:space:]#]+).*/\1/' | sort -u)
FN=$(printf '%s\n' "$FPINS" | grep -c . || true)
if [ "$FN" -ne 1 ]; then
  echo "FAIL: expected exactly one exact flutter-version pin in .github/workflows, found $FN."
  exit 1
fi
if command -v flutter >/dev/null 2>&1; then
  FMACHINE=$(flutter --version --machine 2>/dev/null)
  FLOCAL=$(printf '%s' "$FMACHINE" | sed -nE 's/.*"frameworkVersion": *"([^"]+)".*/\1/p')
  FDART=$(printf '%s' "$FMACHINE" | sed -nE 's/.*"dartSdkVersion": *"([^"]+)".*/\1/p')
  if [ "$FLOCAL" = "$FPINS" ]; then
    if [ "$FDART" != "$PIN" ]; then
      echo "FAIL: Flutter $FPINS bundles Dart ${FDART:-unknown}; the repo pins Dart $PIN."
      echo "  Move flutter-version to a release that bundles $PIN, or move the Dart pin."
      exit 1
    fi
    echo "PASS — Flutter $FPINS bundles Dart $FDART"
  elif [ -n "${CI:-}" ]; then
    echo "FAIL: flutter on PATH is ${FLOCAL:-unknown}; the workflow pins $FPINS."
    exit 1
  else
    echo "note: flutter on PATH is ${FLOCAL:-unknown}, not the pinned $FPINS; Flutter's bundled Dart not checked."
  fi
fi

echo "PASS — workflows and local dart all on $PIN"
