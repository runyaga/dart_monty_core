#!/usr/bin/env bash
# =============================================================================
# Verify the fixture corpus matches the pinned monty version
# =============================================================================
# `test/fixtures/test_cases` is a SYMLINK into a monty checkout, so the
# conformance corpus silently changes whenever that checkout's HEAD moves. This
# has already produced a confidently wrong result: the corpus was pinned at
# v0.0.18 (482 fixtures) while the crate built against v0.0.19, so the suite
# reported "all green" having never seen the 49 fixtures upstream added for 0.19
# — precisely the ones covering user-defined classes, codecs and unicodedata.
#
# A corpus mismatch must fail loudly, because the failure mode is a PASS.
#
# Usage: bash tool/check_fixture_corpus.sh
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

CORPUS_LINK=test/fixtures/test_cases
EMBEDDED=test/integration/_fixture_corpus.dart

# --- what does the crate build against? --------------------------------------
WANT_TAG=$(grep -m1 '^monty = ' native/Cargo.toml | sed -E 's/.*tag = "([^"]+)".*/\1/')
if [ -z "$WANT_TAG" ]; then
  echo "FAIL: could not read the monty tag from native/Cargo.toml"
  exit 1
fi

# --- where does the corpus come from? ----------------------------------------
if [ ! -L "$CORPUS_LINK" ]; then
  echo "FAIL: $CORPUS_LINK is not a symlink — cannot determine the corpus version"
  exit 1
fi
TARGET=$(readlink "$CORPUS_LINK")
if [ ! -d "$TARGET" ]; then
  echo "FAIL: corpus symlink is dangling: $TARGET"
  exit 1
fi

# The corpus lives inside a monty checkout; ask git what it is checked out at.
HAVE_TAG=$(git -C "$TARGET" describe --tags --exact-match HEAD 2>/dev/null \
        || git -C "$TARGET" describe --tags 2>/dev/null \
        || echo "unknown")

echo "crate builds against : $WANT_TAG   (native/Cargo.toml)"
echo "corpus checked out at: $HAVE_TAG   ($TARGET)"

if [ "$HAVE_TAG" != "$WANT_TAG" ]; then
  echo
  echo "FAIL: fixture corpus does not match the pinned monty version."
  echo "  The suite would run $HAVE_TAG fixtures against a $WANT_TAG interpreter and"
  echo "  report a pass for fixtures it never saw. Repoint the symlink:"
  echo "    ln -sfn /path/to/monty-$WANT_TAG/crates/monty/test_cases $CORPUS_LINK"
  echo "    dart tool/generate_fixture_corpus.dart"
  exit 1
fi

# --- is the embedded copy in sync with the symlink? --------------------------
# WASM/JS tests cannot use dart:io, so the corpus is also embedded as Dart source.
# A stale embedded copy means the two backends test different corpora.
ON_DISK=$(find "$CORPUS_LINK/" -maxdepth 1 -name '*.py' | wc -l | tr -d ' ')
EMBEDDED_N=$(grep -c "\.py':" "$EMBEDDED")
echo "fixtures on disk     : $ON_DISK"
echo "fixtures embedded    : $EMBEDDED_N   ($EMBEDDED)"

if [ "$ON_DISK" != "$EMBEDDED_N" ]; then
  echo
  echo "FAIL: the embedded corpus is stale ($EMBEDDED_N vs $ON_DISK on disk)."
  echo "  FFI tests read the symlink while WASM tests read the embedded copy, so"
  echo "  the two backends would be testing different corpora. Regenerate:"
  echo "    dart tool/generate_fixture_corpus.dart"
  exit 1
fi

echo "OK: corpus matches $WANT_TAG and the embedded copy is in sync"
