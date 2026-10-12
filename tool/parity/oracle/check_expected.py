#!/usr/bin/env python3
"""Regenerate the oracle's expected outcomes and fail if they differ from the committed ones.

usage: python -I tool/parity/oracle/check_expected.py [--rust BIN] [--write]

Runs tool/parity/oracle/run_cases.py over every case and run_probes.py over
every probe with the interpreter running this script (which must have the
hash-pinned pydantic-monty from tool/upstream/requirements.lock installed),
and, with --rust, the Rust oracle binary for the three Rust-only probes. The
result must equal tool/parity/expected byte for byte. --write replaces the
committed files instead (then review the diff).

The committed outcomes were generated on Linux x86_64, as CI runs it; one
case's upstream error follows the host OS errno (b11fs_unlink_dir), so a
macOS run differs there and nowhere else.
"""

from __future__ import annotations

import argparse
import filecmp
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
EXPECTED = ROOT / 'tool/parity/expected'
ORACLE = ROOT / 'tool/parity/oracle'


def files(d: Path) -> set[str]:
    return {str(p.relative_to(d)) for p in d.rglob('*.json')}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--rust', type=Path, help='built parity-rust-oracle binary')
    ap.add_argument('--write', action='store_true')
    a = ap.parse_args()
    with tempfile.TemporaryDirectory(prefix='parity-expected-') as tmp:
        out = Path(tmp)
        cases = sorted(str(p) for p in (ROOT / 'tool/parity/cases').glob('*/*.json'))
        for cmd in ([sys.executable, '-I', str(ORACLE / 'run_cases.py'), str(out), *cases],
                    [sys.executable, '-I', str(ORACLE / 'run_probes.py'), str(out)]):
            p = subprocess.run(cmd, capture_output=True, text=True, cwd=tmp)
            if p.returncode != 0:
                print(p.stdout[-2000:], p.stderr[-2000:])
                return 1
            errors = [ln for ln in p.stdout.splitlines() if ln.endswith('ERROR')]
            if errors:
                print('FAIL: the oracle could not run:', *errors, sep='\n  ')
                return 1
        rust_outputs = {f for f in files(EXPECTED) if f.endswith('ref-rust.json')}
        if a.rust:
            subprocess.run([str(a.rust), str(out)], check=True)
        if a.write:
            keep = None if a.rust else tempfile.mkdtemp()
            if keep:
                for f in rust_outputs:
                    (Path(keep) / f).parent.mkdir(parents=True, exist_ok=True)
                    shutil.copy(EXPECTED / f, Path(keep) / f)
            shutil.rmtree(EXPECTED)
            shutil.copytree(out, EXPECTED)
            if keep:
                shutil.copytree(keep, EXPECTED, dirs_exist_ok=True)
            print(f'wrote {len(files(EXPECTED))} expected outcomes')
            return 0
        want = files(EXPECTED) - (set() if a.rust else rust_outputs)
        got = files(out)
        bad = sorted(want ^ got) + sorted(f for f in want & got if not filecmp.cmp(EXPECTED / f, out / f, shallow=False))
        for f in bad[:40]:
            print(f'FAIL: {f} differs from the committed expected outcome' if f in want & got
                  else f'FAIL: {f} is {"missing" if f in want else "not committed"}')
        if bad:
            print(f'\n{len(bad)} expected outcome(s) differ. If upstream behaviour is meant to change, '
                  'regenerate with --write on Linux and review the diff.')
            return 1
        print(f'PASS: {len(got)} expected outcomes regenerate identically'
              + ('' if a.rust else ' (Rust-only probes not regenerated: pass --rust)'))
        return 0


if __name__ == '__main__':
    sys.exit(main())
