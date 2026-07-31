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

# --- what the repo RECORDS about the corpus -------------------------------
# Recorded provenance is the part that can be verified ANYWHERE -- CI, a fresh
# clone, another developer's machine. The symlink below cannot: it points at a
# monty checkout that exists only where someone put one, and treating a dangling
# target as fatal made this guard fail on every machine that was not the
# author's. That is how it broke CI the first time CI ever ran it.
RECORDED=tool/fixture-corpus.json
if [ ! -f "$RECORDED" ]; then
  echo "FAIL: $RECORDED is missing — cannot verify the corpus on this machine"
  exit 1
fi
REC_TAG=$(python3 -c "import json;print(json.load(open('$RECORDED'))['monty_tag'])")
REC_N=$(python3 -c "import json;print(json.load(open('$RECORDED'))['fixture_count'])")
EMBEDDED_N=$(grep -c "\.py':" "$EMBEDDED")

echo "crate builds against : $WANT_TAG   (native/Cargo.toml)"
echo "corpus generated from: $REC_TAG   (tool/fixture-corpus.json)"
echo "fixtures embedded    : $EMBEDDED_N   ($EMBEDDED)"
echo "fixtures recorded    : $REC_N"

# 1. The corpus must have been generated from the version we build against.
if [ "$REC_TAG" != "$WANT_TAG" ]; then
  echo
  echo "FAIL: the fixture corpus was generated from $REC_TAG but the crate builds"
  echo "  against $WANT_TAG. The suite would run $REC_TAG fixtures against a"
  echo "  $WANT_TAG interpreter and report a pass for fixtures it never saw."
  echo "  Regenerate:  dart tool/generate_fixture_corpus.dart"
  exit 1
fi

# 2. The embedded copy must match what was recorded when it was generated.
if [ "$EMBEDDED_N" != "$REC_N" ]; then
  echo
  echo "FAIL: the embedded corpus has $EMBEDDED_N fixtures, but"
  echo "  tool/fixture-corpus.json records $REC_N. One of them is stale."
  echo "  Regenerate:  dart tool/generate_fixture_corpus.dart"
  exit 1
fi

# --- OPTIONAL: cross-check against a local monty checkout ------------------
# Enrichment, not a requirement. When a developer has the upstream checkout
# symlinked, verify the recorded numbers against the real thing. Absent (CI, a
# fresh clone), the checks above still hold.
if [ -L "$CORPUS_LINK" ] && [ -d "$(readlink "$CORPUS_LINK")" ]; then
  TARGET=$(readlink "$CORPUS_LINK")
  HAVE_TAG=$(git -C "$TARGET" describe --tags --exact-match HEAD 2>/dev/null \
          || git -C "$TARGET" describe --tags 2>/dev/null || echo "unknown")
  ON_DISK=$(find "$CORPUS_LINK/" -maxdepth 1 -name '*.py' | wc -l | tr -d ' ')
  echo "local checkout       : $HAVE_TAG   ($TARGET)"

  if [ "$HAVE_TAG" != "$WANT_TAG" ]; then
    echo
    echo "FAIL: your local corpus checkout is $HAVE_TAG, crate wants $WANT_TAG."
    echo "  ln -sfn /path/to/monty-$WANT_TAG/crates/monty/test_cases $CORPUS_LINK"
    exit 1
  fi
  if [ "$ON_DISK" != "$EMBEDDED_N" ]; then
    echo
    echo "FAIL: $ON_DISK fixtures on disk vs $EMBEDDED_N embedded — regenerate."
    exit 1
  fi
else
  echo "local checkout       : absent (skipping cross-check; recorded values verified)"
fi

echo "OK: corpus matches $WANT_TAG and the embedded copy is in sync"
