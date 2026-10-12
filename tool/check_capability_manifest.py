#!/usr/bin/env python3
"""Check the frozen capability manifest against its schema and its totals.

The manifest (tool/upstream/capability-manifest.tsv) is the D1 denominator:
one row per upstream FOSS capability of pydantic/monty 1.1.0, grouped from
upstream's public items, with the status dart_monty_core's baseline was
measured at on each backend. tool/upstream/capability-manifest.json freezes
its content hash and totals. This check fails if either drifts from the
other, so no row can be added, dropped, re-scoped, re-scored or reworded
without editing the frozen record in the same change.

Usage:
  python3 -I tool/check_capability_manifest.py            # offline (gate)
  python3 -I tool/check_capability_manifest.py --online   # + every cite

--online fetches upstream at the pinned commit and checks that every cited
path exists there and every cited line is within the file.
Exit 0 on pass, 1 on any violation, 2 when a file is unreadable.
"""

from __future__ import annotations

import csv
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
META = ROOT / 'tool/upstream/capability-manifest.json'
PIN = ROOT / 'tool/upstream/upstream-pin.json'

COLUMNS = [
    'cap_id', 'area', 'in_scope', 'exclusion', 'upstream_items', 'upstream_cite',
    'python_cite', 'js_cite', 'description', 'baseline_ffi', 'baseline_web',
    'baseline_method',
]
STATUSES = ['PRESENT', 'PARTIAL', 'ABSENT', 'REFUSED', 'N/A']
METHODS = {'run', 'read', 'mixed', 'decided'}
CAP_ID = re.compile(r'^[a-z][a-z0-9_]*$')
# A path inside the upstream repo at the pinned commit, with a line or range.
CITE = re.compile(r'^(?!/)(?!.*\.\.)[A-Za-z0-9_./-]+:\d+(-\d+)?$')

errors: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)
    print(f'FAIL: {msg}')


def check_cites_online(pin: dict, rows: list[dict]) -> int:
    """Every cite names a file at the pinned commit, and a line inside it."""
    n = 0
    with tempfile.TemporaryDirectory(prefix='capability-cites-') as tmp:
        def git(*args: str) -> subprocess.CompletedProcess:
            return subprocess.run(['git', *args], cwd=tmp, capture_output=True, text=True)
        git('init', '-q')
        f = git('fetch', '-q', '--depth', '1', pin['upstream'] + '.git', pin['commit'])
        if f.returncode != 0:
            err(f'fetch {pin["commit"]}: {f.stderr.strip()[-300:]}')
            return 0
        lines: dict[str, int | None] = {}
        for r in rows:
            for c in ('upstream_cite', 'python_cite', 'js_cite'):
                if r[c] == '-':
                    continue
                path, span = r[c].rsplit(':', 1)
                if path not in lines:
                    show = git('show', f'{pin["commit"]}:{path}')
                    lines[path] = len(show.stdout.splitlines()) if show.returncode == 0 else None
                last = int(span.split('-')[-1])
                n += 1
                if lines[path] is None:
                    err(f'{r["cap_id"]}: {c} {r[c]}: no such file at {pin["commit"][:12]}')
                elif last > lines[path]:
                    err(f'{r["cap_id"]}: {c} {r[c]}: file has {lines[path]} lines')
    return n


def main() -> None:
    args = sys.argv[1:]
    if args not in ([], ['--online']):
        print(__doc__)
        sys.exit(2)
    try:
        meta = json.loads(META.read_text())
        pin = json.loads(PIN.read_text())
        tsv = ROOT / meta['manifest']
        with tsv.open(newline='') as f:
            reader = csv.DictReader(f, delimiter='\t')
            header = reader.fieldnames
            rows = list(reader)
    except (OSError, ValueError, KeyError) as e:
        print(f'FATAL: {e}')
        sys.exit(2)

    digest = hashlib.sha256(tsv.read_bytes()).hexdigest()
    if digest != meta.get('sha256'):
        err(f'{meta["manifest"]} sha256 {digest}, frozen at {meta.get("sha256")} '
            '(the manifest is frozen: an edit must update the frozen record in the same change)')

    if header != COLUMNS:
        err(f'header {header} != {COLUMNS}')
        print('\ncapability manifest: header wrong, rows not checked')
        sys.exit(1)

    if meta.get('upstream_version') != pin.get('version'):
        err(f'manifest is for upstream {meta.get("upstream_version")}, the pin is {pin.get("version")}')

    areas = meta['areas']
    seen: set[str] = set()
    for n, r in enumerate(rows, start=2):
        cid = r['cap_id']
        where = f'line {n} ({cid})'
        if None in r or any(v is None for v in r.values()):
            err(f'{where}: wrong number of fields')
            continue
        if not CAP_ID.match(cid):
            err(f'{where}: cap_id must match {CAP_ID.pattern}')
        if cid in seen:
            err(f'{where}: duplicate cap_id')
        seen.add(cid)
        if r['area'] not in areas:
            err(f'{where}: area {r["area"]!r} not in the frozen area list')
        if not r['description'].strip():
            err(f'{where}: empty description')
        for c in ('upstream_cite', 'python_cite', 'js_cite'):
            if r[c] != '-' and not CITE.match(r[c]):
                err(f'{where}: {c} {r[c]!r} is not "-" or an upstream path:line')
        if r['in_scope'] == 'yes':
            if r['exclusion']:
                err(f'{where}: in scope but has an exclusion reason')
            for c in ('baseline_ffi', 'baseline_web'):
                if r[c] not in STATUSES:
                    err(f'{where}: {c} {r[c]!r} not one of {STATUSES}')
            if r['baseline_method'] not in METHODS:
                err(f'{where}: baseline_method {r["baseline_method"]!r} not one of {sorted(METHODS)}')
        elif r['in_scope'] == 'no':
            if not r['exclusion'].strip():
                err(f'{where}: out of scope without an exclusion reason')
            for c in ('baseline_ffi', 'baseline_web', 'baseline_method'):
                if r[c] != '-':
                    err(f'{where}: out of scope, so {c} must be "-"')
        else:
            err(f'{where}: in_scope must be yes or no')

    in_scope = [r for r in rows if r['in_scope'] == 'yes']
    if len(rows) != meta['rows']:
        err(f'{len(rows)} rows, frozen at {meta["rows"]}')
    if len(in_scope) != meta['in_scope']:
        err(f'{len(in_scope)} rows in scope, frozen at {meta["in_scope"]}')
    if [a for a in areas if not any(r['area'] == a for r in rows)]:
        err('an area in the frozen list has no rows')

    base = meta['baseline']
    for col, key in (('baseline_ffi', 'ffi'), ('baseline_web', 'web')):
        got = Counter(r[col] for r in in_scope)
        want = base[key]
        for s in STATUSES:
            if got.get(s, 0) != want.get(s, 0):
                err(f'{key}: {s} {got.get(s, 0)}, frozen at {want.get(s, 0)}')
    got_m = Counter(r['baseline_method'] for r in in_scope)
    if dict(got_m) != base['methods']:
        err(f'methods {dict(got_m)}, frozen at {base["methods"]}')

    cites = check_cites_online(pin, rows) if args else 0

    if errors:
        print(f'\ncapability manifest: {len(errors)} violation(s)')
        sys.exit(1)
    ffi, web = base['ffi'], base['web']
    print(f'PASS: capability manifest, upstream {meta["upstream_version"]}: '
          f'{len(rows)} rows, {len(in_scope)} in scope; baseline PRESENT '
          f'{ffi["PRESENT"]}/{len(in_scope)} FFI, {web["PRESENT"]}/{len(in_scope)} web'
          + (f'; {cites} cites resolve at {pin["commit"][:12]}' if args else ''))


if __name__ == '__main__':
    main()
