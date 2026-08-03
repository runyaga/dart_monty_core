#!/usr/bin/env bash
# =============================================================================
# A harness that hides the diagnosis is not a diagnostic.
# =============================================================================
# A failing conformance fixture used to report exactly this:
#
#     oracle_ffi_ext datetime__core.py [E]
#       unexpected error in datetime__core.py
#
# while the real failure was `AssertionError` at line 17. `MontyException`
# carries message, excType, lineNumber, columnNumber, sourceCode and traceback,
# and every one was discarded to print the word "unexpected" (core#145).
#
# It matters past developer time. This package exists so an LLM can generate
# Monty Python and RETRY when it fails. "unexpected error" gives a model nothing
# to act on: it cannot localise the fault, see which assertion failed, or tell a
# syntax problem from a runtime one. Type, message and line are the difference
# between an informed retry and a guess.
#
# Six sites said the same thing, so fixing them one at a time would not have
# stopped the seventh. Hence a check.
#
# WHY A SHELL CHECK AND NOT A DART TEST. Scanning the repo needs directory
# enumeration. `dart:io` does not exist on dart2js/dart2wasm, and the gate's
# `unit_web` step runs the unit suite on both, so a dart:io test breaks the web
# compile outright — an unsatisfiable import is a compile error that takes the
# whole library down, which a `vm-only` tag cannot prevent. `package:cross_file`
# is the right answer when LIBRARY code must read a file on both backends, but
# its `XFile` is a single-file handle with no directory listing, so it cannot do
# this either. A source-tree invariant is not a unit test: it belongs with the
# six sibling `tool/check_*.sh` scripts, where it also runs in CI.
#
# The portable half — that `describeFixtureFailure` actually renders type,
# message and line — IS a Dart test, and runs on every backend:
# test/unit/conformance/failure_reporting_test.dart
#
# Usage: bash tool/check_no_vague_errors.sh
# =============================================================================
set -uo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

# `fixture_corpus.dart` is UPSTREAM'S PYTHON, baked verbatim. Some of it
# legitimately contains the phrase — args__errors.py asserts
#   "sort() got an unexpected keyword argument 'bogus'"
# which is CPython's exact wording and therefore a contract this engine must
# reproduce byte for byte. Scanning it would make this check demand a change to
# upstream's test suite, which is exactly backwards. The corpus is DATA;
# tool/check_fixture_corpus.sh already guards it against drift.
EXCLUDE_RE='(fixture_corpus\.dart|check_no_vague_errors\.sh)'

# Comment lines are exempt: explaining the defect is not committing it.
HITS="$(grep -rn --include='*.dart' 'unexpected error' \
          lib test packages example tool 2>/dev/null \
        | grep -vE "$EXCLUDE_RE" \
        | grep -vE ':[0-9]+:[[:space:]]*//' || true)"

if [ -n "$HITS" ]; then
  echo "FAIL: these report that something failed without reporting WHAT:"
  echo "$HITS" | sed 's/^/  /'
  echo
  echo "  Use describeFixtureFailure(fixture, exception) from"
  echo "  package:monty_conformance so the exception type, its message and its"
  echo "  line number survive to the reader. A caller — human or model — cannot"
  echo "  act on 'unexpected error'."
  exit 1
fi

echo "PASS — no harness reports a bare 'unexpected error'."
