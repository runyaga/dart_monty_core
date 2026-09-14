#!/usr/bin/env python3
"""Union LCOV tracefiles by FILE AND LINE.

`cargo llvm-cov` merges by SYMBOL. lib.rs holds 63 `#[unsafe(no_mangle)]
pub extern "C"` functions, and #[no_mangle] strips the hash disambiguator, so
`monty_create` compiled under cfg(test) and `monty_create` compiled for the
integration binary are one symbol name with two different bodies. llvm-cov
keeps one mapping, finds no hits against it, and drops the other binary's real
hits on the floor.

Line numbers cannot collide that way. Merging DA records with max() is the
whole fix. See tool/rust_coverage.sh for the measurements.
"""
import sys
from collections import defaultdict


def parse(path):
    """-> {source_file: {line: hit_count}}. Ignores FN/BRDA: symbol-keyed."""
    files = defaultdict(dict)
    current = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if line.startswith("SF:"):
                current = line[3:]
            elif line == "end_of_record":
                current = None
            elif line.startswith("DA:") and current is not None:
                lineno, _, count = line[3:].partition(",")
                try:
                    n, c = int(lineno), int(count)
                except ValueError:
                    continue
                # A line present in both runs takes the higher count. A line
                # present in only one keeps its own -- a line the other binary
                # never instrumented is not evidence that it went unexecuted.
                files[current][n] = max(files[current].get(n, 0), c)
    return files


def main(argv):
    if len(argv) < 3:
        print("usage: lcov_union.py OUT.info IN.info [IN.info ...]", file=sys.stderr)
        return 2
    out, inputs = argv[1], argv[2:]

    merged = defaultdict(dict)
    for path in inputs:
        for sf, lines in parse(path).items():
            for n, c in lines.items():
                merged[sf][n] = max(merged[sf].get(n, 0), c)

    if not merged:
        print("FAIL: no SF records in any input tracefile.", file=sys.stderr)
        return 1

    total_found = total_hit = 0
    with open(out, "w", encoding="utf-8") as fh:
        for sf in sorted(merged):
            lines = merged[sf]
            found = len(lines)
            hit = sum(1 for c in lines.values() if c > 0)
            total_found += found
            total_hit += hit
            fh.write(f"SF:{sf}\n")
            for n in sorted(lines):
                fh.write(f"DA:{n},{lines[n]}\n")
            fh.write(f"LF:{found}\nLH:{hit}\nend_of_record\n")

    pct = (100.0 * total_hit / total_found) if total_found else 0.0
    print(f"{total_hit} {total_found} {pct:.2f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
