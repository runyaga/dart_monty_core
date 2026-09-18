#!/usr/bin/env bash
# =============================================================================
# The two backends must agree on which CoreBindings methods they support.
# =============================================================================
# `CoreBindings` is the shared contract. Both FfiCoreBindings and
# WasmCoreBindings implement it, and a consumer chooses a backend without
# choosing a feature set -- that is the point of the interface.
#
# `throw UnimplementedError` breaks that silently. It is indistinguishable at
# the call site from a genuine platform limitation, and the project already
# knows this shape: test/unit/repl/repl_platform_args_test.dart records that an
# UnimplementedError sails straight through a conformance harness's
# `catch (Exception)` and takes the whole run with it.
#
# Measured 2026-09-14, which is why this exists:
#   FfiCoreBindings.resumeNameLookupValue threw
#     "resumeNameLookupValue is not supported by the FFI backend"
#   while monty_resume_name_lookup_value existed in native/src/lib.rs:580,
#   in native/include/dart_monty.h:326, and in the generated Dart binding.
#   The message was FALSE -- the capability was there, unwired. It reached a
#   shipped example, where PR #150's CI logged
#     "TODO: UnimplementedError -- resumeNameLookupValue is not supported by
#      the FFI backend (FfiCoreBindings:165). Binding gap, not docs rot."
#
# This is a STRUCTURAL check, deliberately. A runtime parity test would need a
# live engine on both backends and would not run in the fast gate; this catches
# the declaration, which is where the lie lives.
#
# Usage: bash tool/check_backend_parity.sh
# =============================================================================
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

FFI=lib/src/ffi/ffi_core_bindings.dart
WASM=lib/src/wasm/wasm_core_bindings.dart

for f in "$FFI" "$WASM"; do
  [ -f "$f" ] || { echo "FATAL: $f is missing"; exit 2; }
done

# A method is "stubbed" when its body throws UnimplementedError. Report the
# method NAME, not just the line, so the failure names the contract hole.
stubbed() {
  python3 - "$1" <<'PY'
import re, sys
src = open(sys.argv[1]).read()
matched = 0
names = []
# @override ... <name>(...) { ... throw UnimplementedError
for m in re.finditer(
        r'(?:Future<[^>]*>|void|[A-Za-z_][\w<>, ?]*)\s+([A-Za-z_]\w*)\s*\([^)]*\)\s*(?:async\s*)?\{(.*?)\n  \}',
        src, re.S):
    name, body = m.group(1), m.group(2)
    matched += 1
    if 'throw UnimplementedError' in body:
        names.append(name)
# The METHOD count comes first, so the caller can tell "no stubs" from "the
# parser matched nothing". Those produce identical output otherwise, and only
# one of them is good news.
print('COUNT:%d' % matched)
for n in names:
    print(n)
PY
}

FFI_RAW=$(stubbed "$FFI")
WASM_RAW=$(stubbed "$WASM")

# PARSER SANITY, BEFORE COMPARING ANYTHING.
#
# This reports asymmetry between two SETS OF STUBS and passes when they are
# equal -- including when both are EMPTY. Empty-and-equal is the desired state,
# so today's pass is correct: 0 stubs on each backend. But it is also exactly
# what a BROKEN PARSER produces. The body regex ends in a newline followed by
# two spaces and a brace, so a reformat that changes that closing indentation
# makes every method stop matching, both sets go empty, and this prints PASS
# having compared nothing.
#
# Tell them apart by asserting the parser saw a plausible number of METHODS.
# Measured 2026-09-17: 30 in ffi_core_bindings.dart, 19 in
# wasm_core_bindings.dart. Floors sit under those so ordinary churn does not
# trip them. Raise when the surface grows; never lower to make a run pass.
FFI_COUNT=$(printf '%s\n' "$FFI_RAW" | sed -n 's/^COUNT://p')
WASM_COUNT=$(printf '%s\n' "$WASM_RAW" | sed -n 's/^COUNT://p')

parse_floor() {
  local label="$1" got="$2" min="$3" file="$4"
  if [ -z "$got" ] || [ "$got" -lt "$min" ]; then
    echo "FAIL: parsed only ${got:-0} method(s) out of $file (expected >= $min)."
    echo "  The method regex stopped matching. With nothing parsed, both stub"
    echo "  sets are empty and this check would report PASS having compared"
    echo "  nothing at all."
    exit 1
  fi
}
parse_floor FFI  "$FFI_COUNT"  20 "$FFI"
parse_floor WASM "$WASM_COUNT" 12 "$WASM"

# `|| true` IS LOAD-BEARING. When a backend has no stubs -- the desired state,
# and the state today -- grep filters out every line and exits 1, which under
# `set -e` kills this script silently at rc 1 with no output at all. Measured
# while adding the floor above: the check "failed" printing nothing, and the
# cause was the success case.
FFI_STUBS=$(printf '%s\n' "$FFI_RAW" | grep -v '^COUNT:' | sort -u || true)
WASM_STUBS=$(printf '%s\n' "$WASM_RAW" | grep -v '^COUNT:' | sort -u || true)

# Asymmetry is the finding: one backend refusing what the other implements.
ONLY_FFI=$(comm -23 <(printf '%s\n' "$FFI_STUBS") <(printf '%s\n' "$WASM_STUBS") | grep -v '^$' || true)
ONLY_WASM=$(comm -13 <(printf '%s\n' "$FFI_STUBS") <(printf '%s\n' "$WASM_STUBS") | grep -v '^$' || true)

rc=0
if [ -n "$ONLY_FFI" ]; then
  echo "FAIL: the FFI backend refuses methods the web backend implements:"
  printf '  %s\n' $ONLY_FFI
  rc=1
fi
if [ -n "$ONLY_WASM" ]; then
  echo "FAIL: the web backend refuses methods the FFI backend implements:"
  printf '  %s\n' $ONLY_WASM
  rc=1
fi

if [ "$rc" -ne 0 ]; then
  echo ""
  echo "  A method on the shared CoreBindings contract that throws"
  echo "  UnimplementedError on ONE backend is either:"
  echo "    (a) unwired, not unsupported -- implement it; or"
  echo "    (b) genuinely impossible on that platform -- then say WHY in the"
  echo "        message, and record it with a falsifier so it stops being"
  echo "        rediscovered."
  echo "  Do not silence this by stubbing the other side to match."
  exit 1
fi

echo "PASS — both backends agree on the CoreBindings surface ($FFI_COUNT FFI / $WASM_COUNT web methods parsed)."
