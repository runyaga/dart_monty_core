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
PORT=${PAGES_PORT:-8231}
SKIP_BUILD=0
[ "${1:-}" = "--skip-build" ] && SKIP_BUILD=1

fail() { echo "FAIL: $*"; exit 1; }

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

  echo "--- dart2js ---"
  dart compile js "$WEB/repl_demo.dart" -o "$WEB/repl_demo.dart.js" --no-source-maps \
    >/dev/null || fail "dart2js build"
  echo "--- dart2wasm ---"
  dart compile wasm "$WEB/repl_demo.dart" -o "$WEB/repl_demo.wasm" \
    >/dev/null || fail "dart2wasm build"

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
class H(http.server.SimpleHTTPRequestHandler):
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
( cd site && python3 "$SRV" "$PORT" "$ACCESS_LOG" ) &
SERVER_PID=$!
trap 'kill $SERVER_PID 2>/dev/null' EXIT
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
CDP_PORT=${PAGES_CDP_PORT:-9334}
CDP_PROFILE=$(mktemp -d)
"$CHROME" --headless=new --disable-gpu --no-sandbox --disable-dev-shm-usage \
  --user-data-dir="$CDP_PROFILE" --remote-debugging-port="$CDP_PORT" about:blank \
  >/dev/null 2>&1 &
CDP_PID=$!
trap 'kill $SERVER_PID $CDP_PID 2>/dev/null' EXIT
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
