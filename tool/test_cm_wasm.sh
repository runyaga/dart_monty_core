#!/usr/bin/env bash
# =============================================================================
# dart_monty_core — test-hooks conformance corpus on WASM (staged build)
# =============================================================================
# WASM counterpart to tool/test_cm.sh. Eight fixtures need monty's testing-only
# `test-hooks` cargo feature — five `with__cm_*` ones need the synthetic
# `_test_cm()` context manager, and three recursion ones need
# `sys.setrecursionlimit` (monty/src/modules/sys.rs) — so they are skipped by
# every shipped build. This script supplies the feature: it builds a STAGED
# test-hooks WASM engine, compiles the corpus runner with
# `-DMONTY_TEST_HOOKS=true` (so it stops skipping those eight), and runs the
# whole 531-fixture corpus in headless Chrome.
#
# The committed JS bridge (lib/assets/*.js) is reused as-is — only the wasm
# engine needs the feature.
#
# TWO DART TARGETS, ONE WASM ENGINE — exactly the split tool/test_wasm.sh makes,
# and for the same reason. Both variants drive the same test-hooks Rust engine;
# what --dart2wasm changes is the compiler used for the DART side:
#
#   default      dart compile js   test/integration/wasm_runner.dart
#   --dart2wasm  dart compile wasm test/integration/wasm_runner_wasm.dart
#
# They are not interchangeable. dart2js has a single number type, so `4.0 is
# int` is true and integral doubles collapse to ints, while dart2wasm has real
# doubles. Until --dart2wasm existed, these eight fixtures had NEVER executed on
# dart2wasm anywhere — not locally, not in CI — because this script was the only
# thing that could run them and it only ever ran dart2js.
#
# Usage: bash tool/test_cm_wasm.sh [--dart2wasm]
#
# NOTHING IS WRITTEN INTO THE WORKING TREE. Both variants stage into a temp dir,
# and that is load-bearing rather than tidiness:
#
#   * `dart compile wasm -o test/integration/web/wasm_runner.wasm` overwrites
#     three TRACKED files (wasm_runner.wasm, .mjs, .wasm.map) with output that
#     is not byte-reproducible, so it would leave a meaningless diff behind.
#   * The engine built here has test-hooks ON, which is NEVER shipped
#     (native/Cargo.toml — "NEVER enabled in shipped builds"). Leaving it inside
#     the repo is worse than untidy: a later step or a developer can load it as
#     if it were the shipped engine and get `sys.setrecursionlimit` in a build
#     that must not have it.
#
# For the same reason the cargo build uses its OWN target dir
# (native/target/test-hooks — inside the already-gitignored native/target/).
# Building test-hooks into the default target dir would both (a) thrash the
# cache against every non-test-hooks wasm32 build, since a feature change forces
# a full recompile, and (b) leave a test-hooks binary at exactly the path
# tool/test_wasm.sh copies into lib/assets/ when run without --skip-build.
#
# Output protocol (parsed from Chrome stderr):
#   FIXTURE_RESULT:{"name":"<file>","ok":<bool>}
#   FIXTURE_DONE:{"total":<n>,"passed":<n>,"failed":<n>,"skipped":<n>}
# =============================================================================
set -euo pipefail

PKG="$(cd "$(dirname "$0")/.." && pwd)"
INTEG_WEB="$PKG/test/integration/web"
WASI_PKG="$PKG/js/node_modules/@pydantic/monty-wasm32-wasi"
# Kept out of native/target/{debug,release,wasm32-*} so the test-hooks feature
# never invalidates the shipped build's cache (and vice versa).
CARGO_TARGET="$PKG/native/target/test-hooks"
DART2WASM=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dart2wasm) DART2WASM=true; shift ;;
    *) echo "Unknown flag: $1" >&2; exit 1 ;;
  esac
done

if [ "$DART2WASM" = true ]; then
  TARGET="dart2wasm"
  ENTRY="wasm_runner_wasm.html"
  PORT_BASE=8096
else
  TARGET="dart2js"
  ENTRY="fixtures.html"
  PORT_BASE=8095
fi

cd "$PKG"

echo "=== test-hooks conformance corpus on WASM ($TARGET) ==="

# Distinct base ports so a dart2js and a dart2wasm run can overlap without one
# silently serving the other's staging dir, then probed — a hardcoded port is
# not actually available, and a backgrounded server that dies on EADDRINUSE is
# invisible to `set -e`, so the run burns the whole Chrome timeout loading
# nothing and blames Chrome.
SERVE_PORT=""
for offset in 0 100 200 300 400 500; do
  candidate=$((PORT_BASE + offset))
  if python3 -c "
import socket, sys
s = socket.socket()
try:
    s.bind(('127.0.0.1', $candidate))
except OSError:
    sys.exit(1)
finally:
    s.close()
" 2>/dev/null; then
    SERVE_PORT="$candidate"
    break
  fi
  echo "  port $candidate busy, trying next"
done
[ -n "$SERVE_PORT" ] || { echo "ERROR: no free port near $PORT_BASE" >&2; exit 1; }

# -------------------------------------------------------
# Step 1: Build a test-hooks WASM engine (own target dir, never lib/assets)
# -------------------------------------------------------
echo "--- Building test-hooks WASM (cargo wasm32-wasip1 --features test-hooks) ---"
(cd native && CARGO_TARGET_DIR="$CARGO_TARGET" \
  cargo build --target wasm32-wasip1 --release --features test-hooks)
WASM_SRC="$CARGO_TARGET/wasm32-wasip1/release/dart_monty_core_native.wasm"
[ -f "$WASM_SRC" ] || { echo "FATAL: missing $WASM_SRC"; exit 1; }

# -------------------------------------------------------
# Step 2: Stage everything OUTSIDE the repo
# -------------------------------------------------------
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dmc-cm-corpus.XXXXXX")"

# Installed BEFORE the first write, so an aborted compile cannot strand a
# test-hooks engine on disk under a name something else might pick up.
SERVE_PID=""
cleanup() {
  if [ -n "$SERVE_PID" ]; then
    kill "$SERVE_PID" 2>/dev/null || true
    wait "$SERVE_PID" 2>/dev/null || true
  fi
  rm -rf "$STAGE"
}
trap cleanup EXIT

echo "--- Staging into $STAGE (test-hooks wasm + committed JS bridge) ---"
cp "$WASM_SRC"                                   "$STAGE/dart_monty_core_native.wasm"
cp "$PKG/lib/assets/dart_monty_core_bridge.js"   "$STAGE/"
cp "$PKG/lib/assets/dart_monty_core_worker.js"   "$STAGE/"
cp "$INTEG_WEB/$ENTRY"                           "$STAGE/"

# WASI runtime (esbuild doesn't copy it; mirror tool/test_wasm.sh).
if [ ! -f "$WASI_PKG/wasi-worker-browser.mjs" ]; then
  echo "--- Installing WASI runtime (npm install --force in js/) ---"
  (cd js && npm install --force --silent)
fi
mkdir -p "$STAGE/@pydantic/monty-wasm32-wasi"
cp "$WASI_PKG/wasi-worker-browser.mjs" "$STAGE/@pydantic/monty-wasm32-wasi/"

# -------------------------------------------------------
# Step 3: Compile the corpus runner with MONTY_TEST_HOOKS=true
# -------------------------------------------------------
dart pub get >/dev/null
if [ "$DART2WASM" = true ]; then
  # `dart compile wasm` takes -D/--define with the same spelling as
  # `dart compile js`; verified by compiling a probe both ways and diffing the
  # const-folded `bool.fromEnvironment` literal in the output. Losing the define
  # here would not fail the compile — the runner would just quietly skip the
  # eight fixtures this script exists to run, so step 6 asserts they executed.
  echo "--- Compiling wasm_runner_wasm.dart -> WASM (-DMONTY_TEST_HOOKS=true) ---"
  dart compile wasm \
    -DMONTY_TEST_HOOKS=true \
    test/integration/wasm_runner_wasm.dart \
    -o "$STAGE/wasm_runner.wasm"
else
  echo "--- Compiling wasm_runner.dart -> JS (-DMONTY_TEST_HOOKS=true) ---"
  dart compile js \
    -DMONTY_TEST_HOOKS=true \
    test/integration/wasm_runner.dart \
    -o "$STAGE/wasm_runner.dart.js" \
    --no-source-maps
fi
echo "  Compile: OK"

# -------------------------------------------------------
# Step 4: COOP/COEP server
# -------------------------------------------------------
echo "--- Starting COOP/COEP server on :$SERVE_PORT ---"
python3 - "$STAGE" "$SERVE_PORT" <<'PYEOF' &
import sys, http.server, functools
directory = sys.argv[1]; port = int(sys.argv[2])
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header('Cross-Origin-Opener-Policy', 'same-origin')
        self.send_header('Cross-Origin-Embedder-Policy', 'require-corp')
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Cache-Control', 'no-store')
        super().end_headers()
    def guess_type(self, path):
        if path.endswith('.mjs'):  return 'application/javascript'
        if path.endswith('.wasm'): return 'application/wasm'
        return super().guess_type(path)
    def log_message(self, fmt, *args): pass
handler = functools.partial(H, directory=directory)
http.server.HTTPServer(('127.0.0.1', port), handler).serve_forever()
PYEOF
SERVE_PID=$!

# Confirm the server is actually serving the entry point before handing the URL
# to Chrome; otherwise a bind failure is invisible for the whole timeout and
# then gets reported as "Chrome crashed".
READY=false
for _ in $(seq 1 20); do
  if curl -fsS -o /dev/null "http://127.0.0.1:$SERVE_PORT/$ENTRY" 2>/dev/null; then
    READY=true; break
  fi
  sleep 0.5
done
[ "$READY" = true ] || { echo "ERROR: server on :$SERVE_PORT never served /$ENTRY" >&2; exit 1; }

# -------------------------------------------------------
# Step 5: Detect Chrome + run headless
# -------------------------------------------------------
CHROME=""
for c in "google-chrome-stable" "google-chrome" \
  "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  "chromium" "chromium-browser"; do
  if command -v "$c" &>/dev/null 2>&1 || [ -f "$c" ]; then CHROME="$c"; break; fi
done
[ -n "$CHROME" ] || { echo "WARN: Chrome not found; cannot run WASM tests."; exit 0; }

echo "--- Running corpus (test-hooks, $TARGET, $ENTRY) in headless Chrome ---"
CHROME_LOG=$(mktemp)

# Poll for FIXTURE_DONE rather than waiting on Chrome. Headless Chrome does NOT
# exit when the page finishes, so a plain `timeout 120` burned the full two
# minutes on every run, pass or fail. The ceiling below is the real timeout, and
# a run that never prints FIXTURE_DONE still fails at step 6.
CHROME_TIMEOUT=240
"$CHROME" --headless=new --disable-gpu --no-sandbox \
  --disable-dev-shm-usage --enable-logging=stderr --v=0 \
  "http://127.0.0.1:$SERVE_PORT/$ENTRY" 2>"$CHROME_LOG" &
CHROME_PID=$!

ELAPSED=0
while [ "$ELAPSED" -lt "$CHROME_TIMEOUT" ]; do
  if grep -q 'FIXTURE_DONE:' "$CHROME_LOG" 2>/dev/null; then break; fi
  if ! kill -0 "$CHROME_PID" 2>/dev/null; then break; fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done
kill "$CHROME_PID" 2>/dev/null || true
wait "$CHROME_PID" 2>/dev/null || true
echo "  Chrome run: ${ELAPSED}s"

# -------------------------------------------------------
# Step 6: Parse — require the test-hooks fixtures to have RUN and passed
# -------------------------------------------------------
RESULTS=$(grep -o 'FIXTURE_RESULT:{.*}' "$CHROME_LOG" 2>/dev/null || true)
DONE=$(grep -o 'FIXTURE_DONE:{.*}' "$CHROME_LOG" 2>/dev/null | head -1 || true)
FAILURES=$(echo "$RESULTS" | grep -c '"ok":false' || true)
CM_RUN=$(echo "$RESULTS" | grep -c 'with__cm_' || true)
REC_RUN=$(echo "$RESULTS" \
  | grep -cE 'recursion__deep_repr|recursion__limit_depth|json__dumps_recursion' || true)
rm -f "$CHROME_LOG"

echo ""
echo "$DONE"
echo "with__cm fixtures executed: $CM_RUN (expected 5)"
echo "test-hooks recursion fixtures executed: $REC_RUN (expected 3)"

if [ -z "$DONE" ]; then echo "FAILED: no FIXTURE_DONE (Chrome crashed/timed out)"; exit 1; fi
if [ "$FAILURES" -gt 0 ]; then
  echo "FAILED: $FAILURES fixture(s) failed:"
  echo "$RESULTS" | grep '"ok":false' | sed 's/^.*FIXTURE_RESULT:/  /'
  exit 1
fi

# "0 failed" is not the same as "the corpus ran": a runner that registered
# nothing prints total:0 and every check above is happy. Pin the total to the
# provenance file, which is regenerated with the corpus and already verified by
# tool/check_fixture_corpus.sh.
EXPECTED_TOTAL=$(python3 -c \
  "import json;print(json.load(open('tool/fixture-corpus.json'))['fixture_count'])")
ACTUAL_TOTAL=$(echo "$DONE" | sed -n 's/.*"total":\([0-9]*\).*/\1/p')
if [ "$ACTUAL_TOTAL" != "$EXPECTED_TOTAL" ]; then
  echo "FAILED: corpus size mismatch — provenance says $EXPECTED_TOTAL, $TARGET ran $ACTUAL_TOTAL"
  exit 1
fi

# FIVE, not six. `with__cm_behaviors.py` was in the skip list but does NOT
# exist in the 0.19 corpus (531 fixtures; that is not one of them), so it could
# never run and the guard could never be satisfied. The dead name also crashed
# ffi_with_cm_test.dart on `fixtureCorpus[name]!` — that is B3, and why CI
# excluded that file.
if [ "$CM_RUN" -lt 5 ]; then
  echo "FAILED: expected 5 with__cm fixtures to run, saw $CM_RUN"
  echo "  (is the runner compiled with -DMONTY_TEST_HOOKS=true?)"
  exit 1
fi

# The three recursion fixtures are gated only by test-hooks, so this build is
# the one place they run. Guard them the same way, or a silent re-bucketing
# would take them out of circulation again.
if [ "$REC_RUN" -lt 3 ]; then
  echo "FAILED: expected 3 recursion fixtures to run, saw $REC_RUN"
  echo "  (is the runner compiled with -DMONTY_TEST_HOOKS=true?)"
  exit 1
fi

echo ""
echo "=== PASSED: test-hooks conformance corpus on WASM ($TARGET) ==="
