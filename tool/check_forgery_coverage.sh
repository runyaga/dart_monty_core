#!/usr/bin/env bash
# =============================================================================
# Every wire tag the encoder can emit must have an inbound-forgery test.
# =============================================================================
# The forgery suite (test/integration/_inbound_forgery_test_body.dart) is the
# end-to-end proof of core#136 / core#139: the sandbox authors a `__type`
# envelope, a host callback echoes it back, and the interpreter must see a
# plain dict rather than a privileged type it never authorised.
#
# It is a real control and it was HAND-LISTED, so it drifted. Measured
# 2026-09-14: the suite attacked 11 tags while native/src/convert.rs emitted
# 25 -- and three of the fourteen gaps (class_instance, time, not_implemented)
# had been added days earlier by the wire-v5 work. Nobody noticed, because
# adding an encoder tag and adding a forgery row are separate edits in separate
# languages and nothing tied them together.
#
# This ties them together. A new `"__type": "x"` in the encoder now fails the
# gate until a row exists for it.
#
# Usage: bash tool/check_forgery_coverage.sh
# =============================================================================
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

ENC=native/src/convert.rs
SUITE=test/integration/_inbound_forgery_test_body.dart

for f in "$ENC" "$SUITE"; do
  [ -f "$f" ] || { echo "FATAL: $f is missing"; exit 2; }
done

EMITTED=$(grep -oE '"__type": "[a-z_]+"' "$ENC" | sed 's/.*: "//;s/"//' | sort -u)
# Extracted from the PAYLOADS, not the _Row( first argument. grep is
# line-based, and a multi-line `_Row(\n  'filehandle',` never matched -- the
# first version of this gate reported 9 tags missing that were plainly present.
# Every payload contains its own `"__type": "x"`, which is the thing actually
# being forged, so matching that is both simpler and closer to the claim.
# ...and with COMMENT LINES STRIPPED FIRST. Without that, the illustrative
# `{"__type": "x"}` in this suite's own explanatory comment was extracted as a
# tag named `x` and reported as stale. That is the same comment-matching bug
# that made tool/check_exports_declared.sh unable to fail, found the same day --
# a check must read the code, not the prose about the code.
ATTACKED=$(sed 's|//.*||' "$SUITE" \
  | grep -oE '__type\\?": \\?"[a-z_]+' | sed 's/.*"//' | sort -u)

[ -n "$EMITTED" ]  || { echo "FATAL: no __type tags found in $ENC — has the encoder changed shape?"; exit 2; }
[ -n "$ATTACKED" ] || { echo "FATAL: no _Row( tags found in $SUITE — has the suite changed shape?"; exit 2; }

MISSING=$(comm -23 <(printf '%s\n' "$EMITTED") <(printf '%s\n' "$ATTACKED") || true)
STALE=$(comm -13 <(printf '%s\n' "$EMITTED") <(printf '%s\n' "$ATTACKED") || true)

rc=0
if [ -n "$MISSING" ]; then
  echo "FAIL: the encoder emits these tags and NOTHING forges them:"
  printf '  %s\n' $MISSING
  echo ""
  echo "  Each is a type the sandbox can name in an envelope and a host can"
  echo "  echo back. Untested means unproven, not safe. Add a _Row to"
  echo "  $SUITE."
  rc=1
fi
if [ -n "$STALE" ]; then
  echo "FAIL: the suite forges tags the encoder no longer emits:"
  printf '  %s\n' $STALE
  echo ""
  echo "  A test for a tag that cannot occur is not protection; it is a row"
  echo "  that will never fail. Remove it, or restore the encoder tag."
  rc=1
fi

[ "$rc" -eq 0 ] || exit 1

N=$(printf '%s\n' "$EMITTED" | wc -l | tr -d ' ')
echo "PASS — all $N emittable wire tags have an inbound-forgery test."
