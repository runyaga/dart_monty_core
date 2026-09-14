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


def normalize(sf, roots):
    """Collapse the SAME source file reached by different absolute roots.

    The tree is bind-mounted, so one file legitimately appears under two paths
    in the same tracefile:

        SF:/Users/runyaga/dev/solpi-bench/dart_monty_core/native/src/lib.rs
        SF:/work/dart_monty_core/native/src/lib.rs

    depending on whether the rlib carrying the debug info was compiled on the
    host or in the container. Keying on the raw string makes one file look like
    two, which DOUBLES the denominator while the hits stay put. Measured:
    3766/7345 = 51.27% instead of 3766/4767 = 79.00% -- a false red against the
    74% CI floor, reported with total confidence.

    STRIP ONLY DECLARED ROOTS. The first version of this searched for the last
    "/native/src/" in the path instead, which is wrong in two ways a reviewer
    caught immediately:

      - `/work/some_other_project/native/src/lib.rs` from a dependency or a
        vendored crate would strip to `native/src/lib.rs` and MERGE WITH OURS,
        taking max() of two unrelated files' hit counts. That INFLATES, which is
        the direction that does real damage.
      - a path containing the marker twice truncates at the wrong one.

    A declared root cannot do either: a path that is not under one is left
    exactly as it is, and stays a separate file.
    """
    for r in roots:
        r = r.rstrip("/") + "/"
        if sf.startswith(r):
            return sf[len(r):]
    return sf


def parse(path, roots):
    """-> {source_file: {line: hit_count}}. Ignores FN/BRDA: symbol-keyed."""
    files = defaultdict(dict)
    current = None
    with open(path, encoding="utf-8", errors="replace") as fh:
        for raw in fh:
            line = raw.strip()
            if line.startswith("SF:"):
                current = normalize(line[3:], roots)
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
    roots = []
    args = argv[1:]
    while args and args[0] == "--root":
        if len(args) < 2:
            print("FAIL: --root needs a path", file=sys.stderr)
            return 2
        roots.append(args[1])
        args = args[2:]
    if len(args) < 2:
        print("usage: lcov_union.py [--root DIR ...] OUT.info IN.info [IN.info ...]",
              file=sys.stderr)
        return 2
    out, inputs = args[0], args[1:]

    merged = defaultdict(dict)
    for path in inputs:
        for sf, lines in parse(path, roots).items():
            for n, c in lines.items():
                merged[sf][n] = max(merged[sf].get(n, 0), c)

    if not merged:
        print("FAIL: no SF records in any input tracefile.", file=sys.stderr)
        return 1

    # Two entries with the same basename mean a duplicate this normalization
    # did NOT collapse -- a root nobody declared, or a symlinked path. That
    # deflates rather than inflates, so it will not sneak past the floor as a
    # pass, but it is still a wrong number and must not be silent.
    by_base = defaultdict(list)
    for sf in merged:
        by_base[sf.rsplit("/", 1)[-1]].append(sf)
    for base, paths in sorted(by_base.items()):
        if len(paths) > 1:
            print(f"warning: {base} appears under {len(paths)} distinct paths; "
                  f"declare a --root so they merge:", file=sys.stderr)
            for q in sorted(paths):
                print(f"    {q}", file=sys.stderr)

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
