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

# need_in <function> <pattern> <what>: like `need`, but only inside the named
# top-level function. Two functions now declare dependencies (_declareInputs
# for native/, _declareWorkerInputs for native/worker/), so a whole-file match
# for a statement they share is satisfied by either one, and deleting it from
# the other stays green (found in review, by mutation).
fn_body() { printf '%s\n' "$CODE" | awk -v h="void $1(" 'index($0, h) == 1 {f=1} f {print} f && /^}$/ {exit}'; }
need_in() {
  if fn_body "$1" | grep -qF "$2"; then
    echo "  ok  $1 declares $3"
  else
    echo "FAIL: $1 in $HOOK no longer declares $3"
    echo "      missing: $2"
    FAIL=1
  fi
}

# The four fixed inputs.
# THE LIST IS A JUDGEMENT, SO IT IS WRITTEN DOWN AS ONE. native/ holds eight
# tracked config files and only these affect the BUILT ARTEFACT:
#
#   Cargo.toml  Cargo.lock  build.rs  rust-toolchain.toml  .cargo/config.toml
#
# Excluded deliberately: clippy.toml, rustfmt.toml and deny.toml configure
# linting, formatting and licence auditing. None of them changes a byte of the
# dylib, and declaring them would make the hook re-run on a lint-config edit.
#
# `.cargo/config.toml` WAS MISSING from this list and from the hook until
# 2026-09-17. It is where rustflags, the linker and target settings live, so a
# change to it changes the artefact while every declared dependency stays
# identical. It was found by asking which checks report HOW MUCH they examined
# and then auditing the ones that enumerate rather than discover.
for f in Cargo.toml Cargo.lock build.rs rust-toolchain.toml .cargo/config.toml; do
  need "nativeDir.resolve('$f')" "native/$f"
done

# The .rs traversal -- the one whose removal was measured to serve a stale
# dylib. Both halves are required: walking src/ and ADDING what it finds.
need_in _declareInputs "srcDir.listSync(recursive: true)" "a recursive walk of native/src/"
need_in _declareInputs "deps.add(e.uri)" "each .rs file found by that walk"
need_in _declareInputs "output.dependencies.addAll(deps)" "the collected list to the runner"

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
# The worker library (self-relaunch): opt-in only, and its inputs declared.
# ---------------------------------------------------------------------------
# Built only when the root package sets the `build_worker` user_define, so a
# consumer without it runs no second cargo build. When it IS built, its own
# crate's inputs must reach the runner for the reason at the top of this file:
# otherwise an edit under native/worker/ leaves a self-relaunching app on a
# stale worker library.
need "input.userDefines['build_worker']" "the build_worker opt-in read"
need "if (_wantsWorker(input)) {" "the worker build behind that opt-in"
for f in Cargo.toml Cargo.lock build.rs; do
  need_in _declareWorkerInputs "workerDir.resolve('$f')" "native/worker/$f"
done
# The toolchain file, declared by the worker itself: with native/Cargo.toml
# gone, _declareInputs (which also declares it) no longer runs.
# A list element of its own line: the parameter declaration
# (`required Uri toolchain,`) must not satisfy it.
if fn_body _declareWorkerInputs | grep -qE '^[[:space:]]*toolchain,$'; then
  echo "  ok  _declareWorkerInputs declares its toolchain parameter"
else
  echo "FAIL: _declareWorkerInputs in $HOOK no longer declares its toolchain"
  echo "      parameter (native/rust-toolchain.toml) in its deps list"
  FAIL=1
fi
need "toolchain: nativeDir.resolve('rust-toolchain.toml')," "native/rust-toolchain.toml as the worker's toolchain"
# The Cargo configuration native/worker inherits (its own, native/'s and the
# package root's): _declareInputs declares native/'s only when it runs.
need_in _declareWorkerInputs "const ['', '../', '../../']" "the .cargo configs of native/worker and its parents"
need_in _declareWorkerInputs "const ['.cargo/config.toml', '.cargo/config']" "both Cargo config file names"
need_in _declareWorkerInputs "deps.add(config);" "each Cargo config found"
need_in _declareWorkerInputs "const ['src/', 'upstream/']" "a walk of native/worker/src and upstream/"
need_in _declareWorkerInputs "dir.listSync(recursive: true)" "a recursive walk of each"
need_in _declareWorkerInputs "deps.add(e.uri)" "each .rs file found by that walk"
need_in _declareWorkerInputs "output.dependencies.addAll(deps)" "the collected list to the runner"
need "_declareWorkerInputs(" "the worker's inputs, after its build"
# Exactly one call site of the worker build, and it is the gated one: a
# second, ungated call would build it for every consumer.
WORKER_CALLS=$(printf '%s' "$CODE" | grep -cF "await _buildWorker(")
if [ "$WORKER_CALLS" = 1 ]; then
  echo "  ok  builds the worker library from exactly one (gated) call"
else
  echo "FAIL: expected exactly 1 call of _buildWorker, found $WORKER_CALLS"
  FAIL=1
fi

# ...and that call is NOT inside the in-process crate's
# `if (cargoToml.existsSync()) {` branch, so the worker still builds when
# native/Cargo.toml is gone (the old engine's removal). Brace depth from that
# `if` to its closing brace, on the comment-stripped source.
INSIDE=$(printf '%s\n' "$CODE" | awk '
  index($0, "if (cargoToml.existsSync()) {") { inb = 1; d = 0 }
  inb {
    if (index($0, "await _buildWorker(")) hit = 1
    d += gsub(/\{/, "{"); d -= gsub(/\}/, "}")
    if (d <= 0) inb = 0
  }
  END { print hit ? "yes" : "no" }')
if [ "$INSIDE" = no ] && printf '%s' "$CODE" | grep -qF "if (cargoToml.existsSync()) {"; then
  echo "  ok  builds the worker outside the in-process crate's branch"
else
  echo "FAIL: the worker build sits inside if (cargoToml.existsSync()) { ... }"
  echo "      (or that branch is gone): without native/Cargo.toml the opted-in"
  echo "      worker library would not build."
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
