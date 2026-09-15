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
# @override ... <name>(...) { ... throw UnimplementedError
for m in re.finditer(
        r'(?:Future<[^>]*>|void|[A-Za-z_][\w<>, ?]*)\s+([A-Za-z_]\w*)\s*\([^)]*\)\s*(?:async\s*)?\{(.*?)\n  \}',
        src, re.S):
    name, body = m.group(1), m.group(2)
    if 'throw UnimplementedError' in body:
        print(name)
PY
}

FFI_STUBS=$(stubbed "$FFI" | sort -u)
WASM_STUBS=$(stubbed "$WASM" | sort -u)

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

echo "PASS — both backends agree on the CoreBindings surface."
