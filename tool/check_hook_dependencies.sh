#!/usr/bin/env bash
# =============================================================================
# The build hook must declare every input that changes the artefact
# =============================================================================
# MEASURED 2026-09-15, with the hook's `.rs` dependency loop removed and the
# hook cache cleared between arms so a stale artefact could not be mistaken for
# the defect:
#
#     deps DECLARED -> edit a .rs -> the change reaches the dylib
#     deps REMOVED  -> edit a .rs -> IT DOES NOT. The dylib is stale, and
#                      `dart test` passes 30/30 against it.
#
# That is the stale-dylib class this repo has already spent an hour
# misdiagnosing (a hooks_runner dylib from the previous day, while the fix
# under test looked wrong).
#
# NOTHING CAUGHT IT, which is why this file exists:
#   - the test suites pass against the stale binary, by construction
#   - tool/check_asset_freshness.sh FAILS, but does not DISCRIMINATE: measured,
#     it also fails with the CORRECT hook on any edited .rs, because it compares
#     committed assets to source hashes. It cannot tell "the hook stopped
#     declaring dependencies" from "you edited Rust and have not re-run
#     prebuild".
#   - tool/gate.sh's L4 content stamp DOES save the local flow, but by an
#     entirely separate mechanism added for a different reason. A bare
#     `dart test` has neither layer.
#
# SCOPE, stated so a green here is not read as more than it is. This is a
# STRUCTURAL check: it asserts the declarations are present in the source. It
# does NOT re-run the measurement above, because that costs two full native
# builds with a cache clear between them -- minutes, in a gate that must stay
# under a few seconds. A structural check cannot see a declaration that is
# present but wrong; it can see one that is gone, which is the regression that
# actually happened.
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

HOOK=hook/build.dart
FAIL=0
[ -f "$HOOK" ] || { echo "FATAL: no $HOOK"; exit 2; }

# COMMENT-STRIPPED, and that is not fastidiousness. Measured while falsifying
# this file: with a plain `grep -F`, commenting out
# `// output.dependencies.addAll(deps);` left the gate GREEN -- the declaration
# was gone and the check could not tell. A gate that accepts a commented-out
# declaration is the same defect class it was written to catch.
CODE=$(sed 's://.*::' "$HOOK")

need() {  # need <pattern> <what it guards>
  if printf '%s' "$CODE" | grep -qF "$1"; then
    echo "  ok  declares $2"
  else
    echo "FAIL: $HOOK no longer declares $2"
    echo "      missing: $1"
    FAIL=1
  fi
}

# The four fixed inputs.
for f in Cargo.toml Cargo.lock build.rs rust-toolchain.toml; do
  need "nativeDir.resolve('$f')" "native/$f"
done

# The .rs traversal -- the one whose removal was measured to serve a stale
# dylib. Both halves are required: walking src/ and ADDING what it finds.
need "srcDir.listSync(recursive: true)" "a recursive walk of native/src/"
need "deps.add(e.uri)" "each .rs file found by that walk"
need "output.dependencies.addAll(deps)" "the collected list to the runner"

# `native/.test-hooks` must be declared ONLY when it exists. Declaring it
# unconditionally was a REGRESSION: the runner records an absent declared
# dependency with a sentinel hash that never compares equal, so the hook re-ran
# on EVERY invocation. Caching was not degraded, it was off.
if printf '%s' "$CODE" | grep -qF "if (testHooksMarker.existsSync()) {"; then
  echo "  ok  declares native/.test-hooks only when present"
else
  echo "FAIL: the .test-hooks marker must be declared ONLY when it exists."
  echo "      Declaring it unconditionally turns hook caching OFF entirely."
  FAIL=1
fi

# ---------------------------------------------------------------------------
# The published artefact must be swapped, never truncated in place.
# ---------------------------------------------------------------------------
# `File.copySync` opens the destination O_TRUNC, shortening the EXISTING inode.
# Linux permits that even for a `dlopen`ed library -- ETXTBSY guards only the
# running executable -- so a concurrent reader sees a half-written file.
# `rename(2)` swaps the directory entry instead.
#
# MEASURED 2026-09-15, by inode across a forced republish:
#     temp + renameSync (shipped)  ->  inode 508038 -> 509596   CHANGED
#     direct copySync   (mutant)   ->  inode 509596 -> 509596   UNCHANGED
# and BOTH arms passed the test suite, so nothing else catches the mutant.
if printf '%s' "$CODE" | grep -qF "tmp.renameSync(dest.path);" &&
   printf '%s' "$CODE" | grep -qF "src.copySync(tmp.path);"; then
  echo "  ok  publishes via a temp file + renameSync, not copy-over-dest"
else
  echo "FAIL: the hook no longer publishes atomically."
  echo "      It must copy to a TEMP path then renameSync onto the destination."
  echo "      A direct copySync onto the destination truncates the existing"
  echo "      inode, which a concurrent reader can observe half-written."
  FAIL=1
fi

[ "$FAIL" = 0 ] && echo "PASS — the hook declares every input, and publishes atomically." || exit 1
