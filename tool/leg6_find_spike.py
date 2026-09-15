#!/usr/bin/env python3
"""Find the first fixture that triggers WASM OOM poisoning.

Runs `make test-wasm` (with KEEP_WEB_ASSETS=1 so the compiled runner JS remains
on disk) and parses the emitted fixture failures list.

Heuristic: identify the first fixture whose failure reason is
"WASM init failed: ... Cannot allocate Wasm memory for new instance".
That fixture is the first one after the renderer has reached the 4GiB ceiling
(or after wasm memory is otherwise exhausted).

Prints:
  - first_oom_fixture
  - previous_fixture (the last fixture that ran before OOM manifested)

This is not a gate; it's an investigation tool.
"""

from __future__ import annotations

import json
import subprocess
import sys


def main() -> int:
    proc = subprocess.run(
        ["make", "test-wasm"],
        cwd="/work/dart_monty_core",
        env={**dict(**__import__("os").environ), "KEEP_WEB_ASSETS": "1"},
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    out = proc.stdout.splitlines()

    failure_lines = []
    for line in out:
        line = line.strip()
        if line.startswith("{") and '"name"' in line and '"ok":false' in line:
            failure_lines.append(line)

    first_oom = None
    for j in failure_lines:
        if "Cannot allocate Wasm memory for new instance" in j:
            first_oom = json.loads(j)
            break

    if not first_oom:
        print("no_oom_failure_found")
        return 1

    # Get fixture order from the corpus provenance json.
    corpus = json.load(open("/work/dart_monty_core/tool/fixture-corpus.json"))
    order = corpus["fixture_order"]

    idx = order.index(first_oom["name"]) if first_oom["name"] in order else None
    prev_name = order[idx - 1] if idx is not None and idx > 0 else None

    print(f"first_oom_fixture={first_oom['name']}")
    print(f"previous_fixture={prev_name}")
    print(f"oom_index={idx}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
