#!/usr/bin/env bash
# Run `--check` for every tool/generate_*_oracle.py: a committed oracle
# .g.dart that differs from what upstream's pydantic-monty records fails.
#
# The generators are found by glob, so a new one is covered with no edit here.
# They need Python 3.12 with the pinned pydantic-monty (the oracle), installed
# from the hash-pinned tool/upstream/requirements.lock into a reused venv:
#
#   bash tool/check_oracles.sh
#
# Each generator formats its output with `dart format`, which reads the root
# analysis_options.yaml, so `dart pub get` must have run (else every file looks
# stale): a missing dart or package_config is "could not run", not "stale".
#
# Env: ORACLE_VENV   venv dir (default .venv-oracle, gitignored)
#      ORACLE_REQUIRE=1  a venv that cannot be built is a FAIL, not exit 77
#                        (CI sets it; the gate lets a machine without
#                        uv/python3.12/network show a visible SKIP).
# Exit: 0 all current, 1 stale generator or bad setup, 77 could not run.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)"

WANT_PY=3.12
LOCK=tool/upstream/requirements.lock
VENV="${ORACLE_VENV:-.venv-oracle}"
PY="$VENV/bin/python"

unrunnable(){ echo "check_oracles: $*" >&2
  [ "${ORACLE_REQUIRE:-0}" = 1 ] && exit 1; exit 77; }

command -v dart >/dev/null 2>&1 || unrunnable "dart not on PATH"
[ -f .dart_tool/package_config.json ] || unrunnable "run dart pub get first"

# The pinned version comes from the lock, not from this script.
WANT_PKG="$(sed -n 's/^pydantic-monty==\([0-9][0-9.]*\).*/\1/p' "$LOCK" | head -n1)"
[ -n "$WANT_PKG" ] || { echo "check_oracles: no pydantic-monty pin in $LOCK" >&2; exit 1; }

# A venv is reused only if it was installed from this exact lock (its digest is
# stamped after a successful install), so a changed pin or hash rebuilds it.
LOCK_SUM="$(shasum -a 256 "$LOCK" | cut -d' ' -f1)"
STAMP="$VENV/.oracle-lock-sha256"

venv_ok(){
  [ -x "$PY" ] && [ "$(cat "$STAMP" 2>/dev/null)" = "$LOCK_SUM" ] || return 1
  "$PY" -I - "$WANT_PY" "$WANT_PKG" <<'PYEOF' 2>/dev/null
import sys
from importlib.metadata import version
py, pkg = sys.argv[1:3]
ok = '%d.%d' % sys.version_info[:2] == py and version('pydantic-monty') == pkg
sys.exit(0 if ok else 1)
PYEOF
}

if ! venv_ok; then
  /bin/rm -rf "$VENV"
  if command -v uv >/dev/null 2>&1; then
    uv venv -q -p "$WANT_PY" "$VENV" || unrunnable "uv could not make a Python $WANT_PY venv"
    uv pip install -q -p "$PY" --require-hashes --only-binary :all: --no-deps -r "$LOCK" \
      || unrunnable "could not install $LOCK"
  elif command -v "python$WANT_PY" >/dev/null 2>&1; then
    "python$WANT_PY" -m venv "$VENV" || unrunnable "venv creation failed"
    "$PY" -m pip install -q --require-hashes --only-binary :all: --no-deps -r "$LOCK" \
      || unrunnable "could not install $LOCK"
  else
    unrunnable "need uv or python$WANT_PY"
  fi
  echo "$LOCK_SUM" > "$STAMP"
  venv_ok || { echo "check_oracles: venv is not Python $WANT_PY with pydantic-monty $WANT_PKG" >&2; exit 1; }
fi

shopt -s nullglob
GENS=(tool/generate_*_oracle.py)
[ "${#GENS[@]}" -gt 0 ] || { echo "check_oracles: no tool/generate_*_oracle.py found" >&2; exit 1; }

RC=0
for g in "${GENS[@]}"; do
  if "$PY" -I "$g" --check; then echo "OK:   $g --check"
  else echo "FAIL: $g --check (stale: run it without --check and commit)"; RC=1; fi
done
echo "ran ${#GENS[@]} oracle generators (Python $WANT_PY, pydantic-monty $WANT_PKG), rc=$RC"
exit $RC
