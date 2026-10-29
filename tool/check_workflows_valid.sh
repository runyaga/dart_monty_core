#!/usr/bin/env bash
# =============================================================================
# The workflow files must be VALID, or CI silently stops running.
# =============================================================================
# A workflow GitHub cannot parse does not fail loudly. It records a run with
# ZERO JOBS and conclusion "failure", and — the part that actually hurts — it
# stops matching its own triggers, so the pull_request runs simply cease.
#
# Measured 2026-09-14: a duplicate `env:` key in one step (ci.yaml, added by a
# commit that only meant to pass one more variable) took CI out for THIRTEEN
# COMMITS. Every push produced a 0-job failure, the PR runs stopped entirely,
# and `python3 -c 'import yaml; yaml.safe_load(...)'` passed the whole time —
# PyYAML keeps the last duplicate key, GitHub rejects the document.
#
# So YAML-parses is not the check. This is.
#
# actionlint is fetched on demand and cached; if it cannot be fetched the gate
# SKIPS with a warning rather than failing, because a network hiccup must not
# block a commit — but it says so, so a silent skip is impossible to mistake
# for a pass.
#
# It also checks the publish guard (F14): no workflow that runs
# `pub publish` may trigger on a -dev tag. A pushed v0.110.0-dev.1 must not
# publish (O6, M3b); publish.yaml excludes it with '!v*-dev.*'. That half needs
# no network, so it runs before actionlint and never SKIPs.
#
# Usage: bash tool/check_workflows_valid.sh
# =============================================================================
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

# --- The publish guard -------------------------------------------------------
python3 -I - <<'PY'
import glob, re, sys
import yaml

DEV_TAGS = ["v0.110.0-dev.1", "v1.2.3-dev.12"]


def glob_re(pat):
    # GitHub's filter glob: * (no /), ** (anything), ? and + qualify the
    # preceding character, [..] is a class.
    out, i = "", 0
    while i < len(pat):
        c = pat[i]
        if pat.startswith("**", i):
            out += ".*"; i += 2; continue
        if c == "*":
            out += "[^/]*"
        elif c in "?+":
            out += c
        elif c == "[":
            j = pat.index("]", i)
            out += pat[i:j + 1]; i = j
        else:
            out += re.escape(c)
        i += 1
    return re.compile(out + r"\Z")


def matches(patterns, tag):
    # The last pattern that matches decides; a '!' pattern excludes.
    hit = False
    for p in patterns:
        neg = p.startswith("!")
        if glob_re(p[1:] if neg else p).match(tag):
            hit = not neg
    return hit


# Controls: the matcher is not vacuous.
assert matches(["v[0-9]+.[0-9]+.[0-9]+*"], "v0.110.0-dev.1")
assert not matches(["v[0-9]+.[0-9]+.[0-9]+*", "!v*-dev.*"], "v0.110.0-dev.1")
assert matches(["v[0-9]+.[0-9]+.[0-9]+*", "!v*-dev.*"], "v0.110.0")

rc = 0
for path in sorted(glob.glob(".github/workflows/*.y*ml")):
    text = open(path).read()
    if not re.search(r"pub publish(?![^\n]*--dry-run)", text):
        continue
    doc = yaml.safe_load(text)
    on = doc.get("on", doc.get(True)) or {}
    if isinstance(on, (str, list)):
        on = {k: None for k in ([on] if isinstance(on, str) else on)}
    if "release" in on or "create" in on:
        print(f"FAIL: {path} publishes on a release/create event, which a -dev "
              "tag can trigger")
        rc = 1
    if "push" in on:
        push = on["push"] or {}
        tags = push.get("tags")
        if tags is None and "tags-ignore" not in push and "branches" not in push:
            tags = ["**"]
        ignore = push.get("tags-ignore") or []
        for tag in DEV_TAGS:
            if tags is not None and matches(tags, tag) and not matches(ignore, tag):
                print(f"FAIL: {path} publishes on push of tag {tag}")
                rc = 1
    if rc == 0:
        print(f"  ok  {path} does not publish on a -dev tag")
sys.exit(rc)
PY

VERSION=1.7.7
CACHE="${HOME}/.cache/actionlint-${VERSION}"

if [ ! -x "$CACHE" ]; then
  case "$(uname -m)" in
    x86_64|amd64) ARCH=amd64 ;;
    aarch64|arm64) ARCH=arm64 ;;
    *) echo "SKIP: no actionlint build for $(uname -m) — workflows NOT validated"; exit 0 ;;
  esac
  URL="https://github.com/rhysd/actionlint/releases/download/v${VERSION}/actionlint_${VERSION}_$(uname -s | tr '[:upper:]' '[:lower:]')_${ARCH}.tar.gz"
  mkdir -p "$(dirname "$CACHE")"
  TMP="$(mktemp -d)"
  if curl -sfL --max-time 60 "$URL" -o "$TMP/al.tgz" 2>/dev/null \
     && tar xzf "$TMP/al.tgz" -C "$TMP" actionlint 2>/dev/null; then
    mv "$TMP/actionlint" "$CACHE"
    chmod +x "$CACHE"
  else
    rm -rf "$TMP"
    echo "SKIP: could not fetch actionlint — workflows NOT validated this run."
    echo "      This is a SKIP, not a pass. Re-run with network to check them."
    exit 0
  fi
  rm -rf "$TMP"
fi

# -shellcheck= disables the embedded shellcheck: the run blocks here are already
# covered by the gate's own discipline, and a shellcheck opinion is not a reason
# to block a commit. Workflow VALIDITY is.
if ! "$CACHE" -shellcheck= -pyflakes= .github/workflows/*.yaml .github/workflows/*.yml 2>&1; then
  echo ""
  echo "  A workflow GitHub cannot parse does not fail loudly: it records a"
  echo "  0-job run and STOPS MATCHING ITS TRIGGERS, so PR checks quietly stop"
  echo "  running. Fix the file above before committing."
  exit 1
fi

N=$(ls .github/workflows/*.yaml .github/workflows/*.yml 2>/dev/null | wc -l | tr -d ' ')
echo "PASS — all $N workflow files are valid."
