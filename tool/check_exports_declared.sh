#!/usr/bin/env bash
# =============================================================================
# Every exported C symbol must be DECLARED in the public header.
# =============================================================================
# native/include/dart_monty.h is the contract: it is what a C consumer reads and
# what ffigen turns into Dart bindings. A symbol exported from Rust but absent
# here is reachable and invisible — it exists for anyone who guesses the name
# and for nobody who reads the documentation.
#
# Found 2026-09-14: monty_alloc and monty_dealloc were exported
# (native/src/lib.rs), called 49 times by js/src/worker_src.js, and declared
# ZERO times in this header. The pairing rule made it worse than a doc gap —
# monty_alloc with no declared monty_dealloc invites free(), which is wrong,
# because the buffer belongs to the module's allocator.
#
# This is the COMPLEMENT of tool/check_wasm_arity.mjs. That one reads the
# shipped wasm exports and never opens the header, so it can prove a call site
# matches the binary while the header says nothing at all. Exported-but-
# undeclared is precisely the gap it cannot see.
#
# Usage: bash tool/check_exports_declared.sh
# =============================================================================
set -euo pipefail
PKG="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PKG"

SRC=native/src/lib.rs
HDR=native/include/dart_monty.h

for f in "$SRC" "$HDR"; do
  [ -f "$f" ] || { echo "FATAL: $f is missing"; exit 2; }
done

# Every `#[unsafe(no_mangle)] pub [unsafe] extern "C" fn NAME` in lib.rs.
EXPORTED=$(grep -oE 'pub (unsafe )?extern "C" fn [a-z_0-9]+' "$SRC" \
  | awk '{print $NF}' | sort -u)

[ -n "$EXPORTED" ] || { echo "FATAL: no exported symbols found in $SRC — has the pattern changed?"; exit 2; }

# STRIP COMMENTS FIRST. The first version of this gate grepped the raw header
# for the bare symbol name, which matched the DOC COMMENTS that mention these
# functions in prose -- so deleting a real declaration still passed. A gate that
# cannot fail is worse than no gate, and it was caught only because the
# falsification step ran and both arms came back green.
DECLS=$(python3 - "$HDR" <<'PYEOF'
import re, sys
src = open(sys.argv[1]).read()
src = re.sub(r'/\*.*?\*/', ' ', src, flags=re.S)   # block comments
src = re.sub(r'//[^\n]*', ' ', src)                 # line comments
# A declaration is a name immediately followed by '('.
print('\n'.join(sorted(set(re.findall(r'\b([a-z_][a-z_0-9]*)\s*\(', src)))))
PYEOF
)

MISSING=""
for sym in $EXPORTED; do
  printf '%s\n' "$DECLS" | grep -qx "$sym" || MISSING="$MISSING $sym"
done

if [ -n "$MISSING" ]; then
  echo "FAIL: exported from Rust, absent from the public header:"
  for sym in $MISSING; do
    echo "  $sym   (native/src/lib.rs)"
  done
  echo ""
  echo "  native/include/dart_monty.h is the C ABI contract and ffigen's input."
  echo "  A symbol missing here is reachable and undocumented: no Dart binding"
  echo "  is generated, and a C consumer cannot know it exists."
  echo ""
  echo "  Declare it, then re-run: bash tool/generate_bindings.sh"
  exit 1
fi

COUNT=$(printf '%s\n' "$EXPORTED" | wc -l | tr -d ' ')
echo "PASS — all $COUNT exported C symbols are declared in the header."
