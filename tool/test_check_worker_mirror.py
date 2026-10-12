#!/usr/bin/env python3
"""Negative controls for tool/check_worker_mirror.py --local.

Each case copies the files the check reads into a temp directory, swaps in
local code for an upstream crate the way Cargo would record it, and asserts
the check fails. The unmodified copy must pass, so a red case is the mutation's
doing and not a broken fixture.

Usage: python3 -I tool/test_check_worker_mirror.py
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CHECK = ROOT / 'tool' / 'check_worker_mirror.py'
MIRROR = 'tool/upstream/worker-mirror.json'
MANIFEST = 'native/worker/Cargo.toml'
LOCK = 'native/worker/Cargo.lock'


def lock_entry(lock: str, name: str) -> re.Match[str]:
    """The `[[package]]` block of the single `name` entry in a Cargo.lock."""
    found = list(re.finditer(rf'\[\[package\]\]\nname = "{re.escape(name)}"\n.*?(?=\n\n|\Z)', lock, re.S))
    if len(found) != 1:
        raise AssertionError(f'{name}: {len(found)} lock entries')
    return found[0]


def as_path_entry(lock: str, name: str, version: str) -> str:
    """Rewrites `name`'s lock entry as Cargo records a path/patch override."""
    m = lock_entry(lock, name)
    block = re.sub(r'\nversion = "[^"]*"', f'\nversion = "{version}"', m.group(0))
    block = re.sub(r'\n(source|checksum) = "[^"]*"', '', block)
    return lock[:m.start()] + block + lock[m.end():]


class WorkerMirrorTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix='worker-mirror-'))
        self.addCleanup(shutil.rmtree, self.tmp)
        mirror = json.loads((ROOT / MIRROR).read_text())
        paths = {MIRROR, mirror['pin'], mirror['worker_manifest'], mirror['worker_lock'],
                 mirror['upstream_lock']['local'], *(f['local'] for f in mirror['verbatim'])}
        paths |= {str(p.relative_to(ROOT)) for d in ('.cargo', 'native/.cargo', 'native/worker/.cargo')
                  for p in (ROOT / d).glob('config*')}
        for rel in paths:
            (self.tmp / rel).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT / rel, self.tmp / rel)

    def edit(self, rel: str, change) -> None:
        f = self.tmp / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_text(change(f.read_text() if f.exists() else ''))

    def run_check(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run([sys.executable, '-I', str(CHECK), '--local', '--root', str(self.tmp)],
                              capture_output=True, text=True, check=False)

    def assert_fails(self, *needles: str) -> None:
        r = self.run_check()
        out = r.stdout + r.stderr
        self.assertEqual(r.returncode, 1, f'expected a finding (exit 1), got {r.returncode}:\n{out}')
        for n in needles:
            self.assertIn(n, out)

    def test_unmodified_copy_passes(self) -> None:
        r = self.run_check()
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_patched_monty_proto_path_override(self) -> None:
        # A [patch.crates-io] to local code that still reports 1.1.0.
        self.edit(MANIFEST, lambda t: t + '\n[patch.crates-io]\nmonty-proto = { path = "../proto" }\n')
        self.edit(LOCK, lambda t: as_path_entry(t, 'monty-proto', '1.1.0'))
        self.assert_fails('[patch]', 'monty-proto 1.1.0')

    def test_monty_proto_lock_entry_without_source(self) -> None:
        # The lock alone: a source-less monty-proto at the pinned version.
        self.edit(LOCK, lambda t: as_path_entry(t, 'monty-proto', '1.1.0'))
        self.assert_fails('monty-proto 1.1.0')

    def test_monty_proto_checksum_differs(self) -> None:
        # From crates.io, at 1.1.0, but not the published bytes.
        self.edit(LOCK, lambda t: re.sub(r'(name = "monty-proto"\nversion = "1.1.0"\nsource = "[^"]*"\n'
                                         r'checksum = ")[0-9a-f]{64}', r'\g<1>' + '0' * 64, t))
        self.assert_fails('monty-proto 1.1.0 checksum')

    def test_salsa_0_28_5_as_path_dependency(self) -> None:
        # The drift a fresh resolve produces, smuggled in as a path dependency.
        self.edit(MANIFEST, lambda t: t.replace('[dependencies]\n', '[dependencies]\nsalsa = { path = "../salsa" }\n', 1))
        self.edit(LOCK, lambda t: as_path_entry(t, 'salsa', '0.28.5'))
        self.assert_fails("salsa: 'path'", 'salsa 0.28.5')

    def test_git_dependency(self) -> None:
        # Still an exact `=1.1.0` requirement, so the version check alone passes.
        self.edit(MANIFEST, lambda t: t.replace(
            'monty-alloc = "=1.1.0"',
            'monty-alloc = { version = "=1.1.0", git = "https://example.invalid/monty", tag = "v1.1.0" }', 1))
        self.assert_fails("monty-alloc: 'git'")

    def test_replace_table(self) -> None:
        self.edit(MANIFEST, lambda t: t + '\n[replace]\n"monty-types:1.1.0" = { path = "../types" }\n')
        self.assert_fails('[replace]')

    def test_cargo_config_patch(self) -> None:
        self.edit('native/worker/.cargo/config.toml',
                  lambda t: t + '\n[patch.crates-io]\nmonty-proto = { path = "../../proto" }\n')
        self.assert_fails('native/worker/.cargo/config.toml', '[patch]')

    def test_cargo_config_source_replacement_above_the_crate(self) -> None:
        # Cargo reads every .cargo/config* from the working directory up.
        self.edit('native/.cargo/config.toml', lambda t: t + '\n[source.crates-io]\nreplace-with = "vendored"\n'
                                                            '\n[source.vendored]\ndirectory = "vendor"\n')
        self.assert_fails('native/.cargo/config.toml', '[source]')


if __name__ == '__main__':
    unittest.main(verbosity=2)
