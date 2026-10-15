### Internal

- `tool/check_oracles.sh` runs `--check` for every `tool/generate_*_oracle.py`, found by glob, in a cached Python 3.12 venv with the pydantic-monty version from `tool/upstream/requirements.lock`. `tool/gate.sh` runs it as step `oracle_check` and CI runs it in the `upstream-pin` job, so a stale oracle `.g.dart` fails both instead of being caught by hand.
