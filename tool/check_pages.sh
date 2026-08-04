#!/usr/bin/env bash
# =============================================================================
# GitHub Pages gate — build the published site and prove it renders in Chrome
# =============================================================================
# https://runyaga.github.io/dart_monty_core/ is assembled by
# .github/workflows/deploy-pages.yml from docs/index.html plus the dart2js and
# dart2wasm builds of the web REPL. That REPL loads the SAME committed
# lib/assets/ bundle that ships to consumers, so this is the only end-to-end
# check that the published artefacts actually work in a real browser.
#
# Nothing else covers it: the WASM fixture corpus exercises the engine through a
# test harness, not through the deployed page, and a green corpus says nothing
# about whether the site loads, finds its assets, or initialises.
#
# Deliberately a SEPARATE gate from tool/test_wasm.sh: different artefact (the
# assembled site vs the test harness), different failure modes (missing/stale
# asset copies, COOP/COEP headers, relative-path breakage under /repl/).
#
# Usage: bash tool/check_pages.sh [--skip-build]
# =============================================================================
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

WEB=packages/dart_monty_web/web
SKIP_BUILD=0
[ "${1:-}" = "--skip-build" ] && SKIP_BUILD=1

fail() { echo "FAIL: $*"; exit 1; }

# ---------------------------------------------------------------- concurrency
# This script MUTATES SHARED PATHS in the working tree: it stages assets into
# packages/dart_monty_web/web, writes four compiler outputs there, and does
# `rm -rf site` before reassembling. None of that is per-run state, so two
# concurrent runs in one clone corrupt each other.
#
# Measured 2026-08-03, two agent sessions running the gate in this repo:
#   - run B could not bind 8231 and died instantly (loud, obviously bogus);
#   - run B's `rm -rf site` deleted run A's server cwd mid-flight, so
#     `os.getcwd()` raised FileNotFoundError inside the handler and every
#     asset request after that point failed. Run A reported
#     "index_js.html was never fetched with 200 — the page did not wire up",
#     which reads exactly like a real wiring defect in the published site.
# The second one is the dangerous shape: a red that names the wrong cause.
#
# A lock, not per-run temp dirs, because the paths above are what the gate is
# meant to test — staging elsewhere would test something that never ships.
# Serialising costs a wait; getting a phantom red costs an investigation.
LOCK_TIMEOUT=${PAGES_LOCK_TIMEOUT:-900}
LOCKDIR="${TMPDIR:-/tmp}/dmc-check-pages-$(git rev-parse --show-toplevel \
  | shasum -a 256 | cut -c1-12).lock"
LOCK_HELD=""

# mkdir is the atomic primitive available everywhere; macOS has no flock(1).
acquire_lock() {
  local waited=0 other announced=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    other=$(cat "$LOCKDIR/pid" 2>/dev/null || true)
    # A crashed run must not block the repo forever.
    if [ -n "$other" ] && ! kill -0 "$other" 2>/dev/null; then
      echo "  note: clearing stale lock left by dead pid $other"
      rm -rf "$LOCKDIR"
      continue
    fi
    if [ "$announced" = 0 ]; then
      echo "--- waiting for another check_pages.sh (pid ${other:-?}) ---"
      announced=1
    fi
    sleep 5
    waited=$((waited + 5))
    [ "$waited" -ge "$LOCK_TIMEOUT" ] \
      && fail "waited ${LOCK_TIMEOUT}s for $LOCKDIR — is a run wedged?"
  done
  LOCK_HELD=1
  echo $$ > "$LOCKDIR/pid"
}

# One cleanup, one trap. There used to be two `trap ... EXIT` lines and the
# second silently replaced the first, so whichever resources the first owned
# were only ever freed by luck. Killing $! also missed the python server: `$!`
# of `( cd site && python3 … ) &` is the SUBSHELL, so the grandchild survived
# and held the port until something noticed.
SERVER_PID=""
CDP_PID=""
cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null
  [ -n "$CDP_PID" ] && kill "$CDP_PID" 2>/dev/null
  [ -n "$LOCK_HELD" ] && rm -rf "$LOCKDIR"
  return 0
}
trap cleanup EXIT

acquire_lock

# Ask the kernel for a free port rather than hardcoding one. The lock already
# stops US colliding with ourselves; this also stops us colliding with whatever
# else happens to hold 8231/9334 on a developer machine. Both stay overridable.
free_port() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}
PORT=${PAGES_PORT:-$(free_port)}
CDP_PORT=${PAGES_CDP_PORT:-$(free_port)}

# ---------------------------------------------------------------- build
if [ "$SKIP_BUILD" = "0" ]; then
  echo "--- Staging committed assets into $WEB ---"
  ( cd packages/dart_monty_web && dart pub get >/dev/null ) || fail "pub get in dart_monty_web"
  for a in dart_monty_core_bridge.js dart_monty_core_worker.js dart_monty_core_native.wasm; do
    cp "lib/assets/$a" "$WEB/" || fail "missing lib/assets/$a — run tool/prebuild.sh"
  done
  mkdir -p "$WEB/@pydantic/monty-wasm32-wasi"
  cp js/node_modules/@pydantic/monty-wasm32-wasi/wasi-worker-browser.mjs \
     "$WEB/@pydantic/monty-wasm32-wasi/" 2>/dev/null \
     || echo "  note: wasi-worker-browser.mjs not staged (npm not installed?)"

  # BOTH entry points, both compilers. feature_matrix was omitted here, and
  # `packages/dart_monty_web/**` is excluded in analysis_options.yaml, so
  # nothing in the gate looked at it: it sat broken — `files:` still being
  # handed the old `Map<String, String>` seed — through a green 22/22 gate.
  # A file no tool compiles is a file with no coverage, whatever the summary
  # says.
  for entry in repl_demo feature_matrix; do
    echo "--- dart2js: $entry ---"
    dart compile js "$WEB/$entry.dart" -o "$WEB/$entry.dart.js" --no-source-maps \
      >/dev/null || fail "dart2js build ($entry)"
    echo "--- dart2wasm: $entry ---"
    dart compile wasm "$WEB/$entry.dart" -o "$WEB/$entry.wasm" \
      >/dev/null || fail "dart2wasm build ($entry)"
  done

  echo "--- Assembling site/ (mirrors deploy-pages.yml) ---"
  rm -rf site 2>/dev/null; mkdir -p site/repl
  cp -r "$WEB/." site/repl/ || fail "copy web -> site/repl"
  cp docs/index.html site/index.html || fail "docs/index.html missing"
fi

[ -f site/index.html ] || fail "site/index.html not built (drop --skip-build)"

# ---------------------------------------------------------------- serve
# PRODUCTION-FAITHFUL: no COOP/COEP headers.
#
# GitHub Pages cannot set custom response headers, so anything that depends on the
# server sending COOP/COEP does not work in production. An earlier version of this
# gate sent them, which meant it was testing a configuration that never ships —
# it could not have detected a page that only works with headers present.
#
# Verified empirically that this is the right configuration: with headers absent,
# index_js.html works because dart2js does not need SharedArrayBuffer, and
# index_wasm.html works because it registers a COI service worker (the supported
# way to get cross-origin isolation without server headers). So the invariant this
# gate now enforces is the correct one: a page that needs isolation must ship the
# service worker rather than assume headers.
#
# tool/serve_demo.sh still sends headers for local development; that is fine, it is
# not a release gate.
SRV=$(mktemp -d)/coi.py
cat > "$SRV" <<'PY'
import http.server, socketserver, sys
# Chrome's stderr at --v=0 does NOT report failed subresource fetches, so an
# earlier version of this gate passed with the WASM asset deleted. The server is
# the one component we fully control, so it records what was actually requested
# and with what status; the assertions below are made against that.
ACCESS = sys.argv[2]
# Serve an ABSOLUTE root instead of inheriting the cwd. SimpleHTTPRequestHandler
# calls os.getcwd() per request when it has no `directory=`, so a run whose cwd
# was removed underneath it raised FileNotFoundError inside the handler and
# answered nothing further -- the assertions then blamed the PAGE for not
# wiring up. Pinning the root makes the server survive churn beneath it and
# report the truth: 404s for files that are genuinely absent.
ROOT = sys.argv[3]
class H(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)
    def send_response(self, code, message=None):
        super().send_response(code, message)
        with open(ACCESS, 'a') as f:
            f.write(f"{code} {self.path}\n")
    def log_message(self, *a): pass
socketserver.TCPServer.allow_reuse_address = True
with socketserver.TCPServer(("127.0.0.1", int(sys.argv[1])), H) as s:
    s.serve_forever()
PY
ACCESS_LOG=$(mktemp)
python3 "$SRV" "$PORT" "$ACCESS_LOG" "$PWD/site" &
SERVER_PID=$!
sleep 2

for path in "/" "/repl/"; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT$path")
  [ "$code" = "200" ] || fail "$path returned HTTP $code"
  echo "  HTTP 200  $path"
done

# ---------------------------------------------------------------- Chrome
CHROME=""
for c in "google-chrome-stable" "google-chrome" \
         "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
         "chromium" "chromium-browser"; do
  if command -v "$c" &>/dev/null 2>&1 || [ -f "$c" ]; then CHROME="$c"; break; fi
done
[ -n "$CHROME" ] || fail "Chrome not found — this gate cannot run (do not skip it silently)"
echo "  Chrome: $CHROME"

# Uses its own throwaway profile so it never contends with a developer's running
# Chrome or with chrome-devtools-mcp.
run_page() {
  local url="$1" log="$2"
  timeout 90 "$CHROME" --headless=new --disable-gpu --no-sandbox \
    --disable-dev-shm-usage --enable-logging=stderr --v=0 \
    --user-data-dir="$(mktemp -d)" \
    --virtual-time-budget=20000 \
    "$url" 2>"$log" || true
}

STATUS=0
for page in "" "repl/"; do
  LOG=$(mktemp)
  echo "--- Chrome: /$page ---"
  run_page "http://127.0.0.1:$PORT/$page" "$LOG"
  if grep -qiE 'Uncaught|"SEVERE"' "$LOG"; then
    echo "  FAIL: uncaught JS error"
    grep -iE 'Uncaught|"SEVERE"' "$LOG" | head -5 | sed 's/^/    /'
    STATUS=1
  fi
done

# The real assertions: what did the browser actually fetch, and did it succeed?
echo "--- Request log assertions ---"
if [ ! -s "$ACCESS_LOG" ]; then
  echo "  FAIL: the server logged no requests at all"
  STATUS=1
fi

# Any non-2xx/3xx response means the page referenced something that is not there.
# favicon.ico is excluded: browsers request it unprompted and the site does not
# ship one, so it is noise rather than a defect.
BAD=$(grep -E '^(4|5)[0-9][0-9] ' "$ACCESS_LOG" | grep -v 'favicon.ico' | wc -l | tr -d ' ')
if [ "$BAD" -gt 0 ]; then
  echo "  FAIL: $BAD request(s) returned an error status:"
  grep -E '^(4|5)[0-9][0-9] ' "$ACCESS_LOG" | grep -v 'favicon.ico' | sort -u | head -10 | sed 's/^/    /'
  STATUS=1
fi

# What a PASSIVE page load must fetch. Deliberately not the .wasm: the REPL
# initialises its engine on button click (run-a / run-b / run-vfs), so a load
# without interaction legitimately never pulls it. An earlier version of this gate
# asserted the .wasm and reported a failure that was not one.
#
# Engine-actually-executes is covered by tool/test_wasm.sh, which drives
# fixtures.html headlessly over the whole corpus. This gate deliberately stops at
# "the deployed site resolves its assets and wires up without error" — that is the
# part nothing else checks.
for required in "index_js.html" "dart_monty_core_bridge.js" "repl_demo.dart.js"; do
  if grep -qE "^200 .*$required" "$ACCESS_LOG"; then
    echo "  fetched 200  $required"
  else
    echo "  FAIL: $required was never fetched with 200 — the page did not wire up"
    STATUS=1
  fi
done

# ---------------------------------------------------------------- execute
# Everything above proves the page LOADS. This proves the demo WORKS: drive the
# real page over CDP, type Python into #input-a, click Run, and require the
# computed result. The REPL initialises its WASM engine on click, so without this
# a totally broken engine still passes.
echo "--- Chrome (CDP): does the demo actually execute Python? ---"
CDP_PROFILE=$(mktemp -d)
"$CHROME" --headless=new --disable-gpu --no-sandbox --disable-dev-shm-usage \
  --user-data-dir="$CDP_PROFILE" --remote-debugging-port="$CDP_PORT" about:blank \
  >/dev/null 2>&1 &
CDP_PID=$!
sleep 6

DRIVE_LOG=$(mktemp)
node tool/pages_drive.mjs "$CDP_PORT" "http://127.0.0.1:$PORT/repl/" >"$DRIVE_LOG" 2>&1
DRIVE_RC=$?
sed 's/^/  /' "$DRIVE_LOG"
if [ "$DRIVE_RC" != "0" ]; then
  echo "  FAIL: the demo did not evaluate Python"
  STATUS=1
fi

[ "$STATUS" = "0" ] || fail "the Pages site does not render cleanly"
echo "OK: site builds and renders in Chrome with no console or network errors"
