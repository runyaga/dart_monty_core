#!/usr/bin/env python3
"""Extract fixture order from packages/monty_conformance/lib/src/fixture_corpus.dart.

We rely on the literal map order in the Dart source (insertion order).
"""

from __future__ import annotations

import re

SRC = "/work/dart_monty_core/packages/monty_conformance/lib/src/fixture_corpus.dart"


def main() -> int:
    text = open(SRC, "r", encoding="utf-8").read().splitlines()
    keys: list[str] = []
    key_re = re.compile(r"^\s*'([^']+)':\s")
    for line in text:
        m = key_re.match(line)
        if m:
            keys.append(m.group(1))
    for k in keys:
        print(k)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
