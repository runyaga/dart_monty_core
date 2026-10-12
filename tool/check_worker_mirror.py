#!/usr/bin/env python3
"""Check that native/worker/ still mirrors the pinned upstream tag.

native/worker/ is core's build of upstream pydantic/monty's `monty subprocess`
worker. It carries one upstream file verbatim, depends on the upstream crates
by exact version, and resolves them from a Cargo.lock seeded with upstream's.
The pin (tag, commit, version) is tool/upstream/upstream-pin.json; what is
mirrored is tool/upstream/worker-mirror.json.

Usage:
  python3 -I tool/check_worker_mirror.py --local             # offline (gate)
  python3 -I tool/check_worker_mirror.py --online            # CI upstream-pin
  python3 -I tool/check_worker_mirror.py --candidate vX.Y.Z  # per-release review

--local (no network):
  - every verbatim copy hashes to its recorded sha256;
  - tool/upstream/monty-Cargo.lock (upstream's lock at the pin) hashes to its
    recorded sha256;
  - every crates.io package in native/worker/Cargo.lock appears in upstream's
    lock with the same version and checksum (the lock is a subset of
    upstream's; a fresh resolution that drifts, e.g. to salsa 0.28.5, fails);
  - the monty crates are exactly the pinned version, both as `=X` requirements
    in native/worker/Cargo.toml and in the lock.

--online: every verbatim and watched upstream file, and upstream's Cargo.lock,
still hashes to its recorded sha256 at the pinned commit.

--candidate TAG: prints a unified diff for every verbatim or watched upstream
file that differs between the pin and TAG. Exit 1 means there is porting work.

Exit 0 on pass, 1 on any finding, 2 on a malformed record.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import json
import re
import sys
import tomllib
import urllib.request
from pathlib import Path

RAW = 'https://raw.githubusercontent.com/pydantic/monty/{ref}/{path}'
MIRROR = 'tool/upstream/worker-mirror.json'
HEX64 = re.compile(r'^[0-9a-f]{64}$')
CRATES_IO = 'registry+https://github.com/rust-lang/crates.io-index'


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch(ref: str, path: str) -> bytes:
    with urllib.request.urlopen(RAW.format(ref=ref, path=path), timeout=30) as r:
        return r.read()


def fatal(msg: str) -> None:
    print(f'FATAL: {msg}')
    sys.exit(2)


def lock_packages(text: str) -> dict[str, dict[str, str | None]]:
    """{name: {version: checksum}} for every package in a Cargo.lock.

    Path and workspace packages have no source; their versions are recorded
    with a None checksum and the source marked by the key "path".
    """
    out: dict[str, dict[str, str | None]] = {}
    for pkg in tomllib.loads(text).get('package', []):
        source = pkg.get('source')
        checksum = pkg.get('checksum') if source == CRATES_IO else None
        if source is not None and source != CRATES_IO:
            fatal(f'{pkg["name"]} {pkg["version"]}: unsupported source {source}')
        out.setdefault(pkg['name'], {})[pkg['version']] = checksum if source else 'path'
    return out


def load(root: Path) -> tuple[dict, dict]:
    try:
        mirror = json.loads((root / MIRROR).read_text())
        pin = json.loads((root / mirror['pin']).read_text())
    except (OSError, ValueError, KeyError) as e:
        fatal(f'{MIRROR} or its pin unreadable: {e}')
    for key in ('worker_manifest', 'worker_lock', 'upstream_lock', 'pinned_crates', 'verbatim', 'watched'):
        if key not in mirror:
            fatal(f'{MIRROR} has no "{key}"')
    for key in ('version', 'tag', 'commit'):
        if key not in pin:
            fatal(f'{mirror["pin"]} has no "{key}"')
    for f in mirror['verbatim'] + mirror['watched'] + [mirror['upstream_lock']]:
        if not HEX64.match(f.get('sha256', '')):
            fatal(f'{f.get("upstream")}: sha256 is not 64 hex digits')
    return mirror, pin


def local(root: Path, mirror: dict, pin: dict, bad: list[str]) -> None:
    for f in mirror['verbatim']:
        got = sha((root / f['local']).read_bytes())
        if got != f['sha256']:
            bad.append(f'verbatim copy edited or stale: {f["local"]} sha256 {got[:12]}, '
                       f'pinned {f["sha256"][:12]} ({f["upstream"]} @ {pin["tag"]})')

    up_lock = mirror['upstream_lock']
    up_bytes = (root / up_lock['local']).read_bytes()
    if sha(up_bytes) != up_lock['sha256']:
        bad.append(f'{up_lock["local"]} is not upstream\'s Cargo.lock @ {pin["tag"]} '
                   f'(sha256 {sha(up_bytes)[:12]}, pinned {up_lock["sha256"][:12]})')
    upstream = lock_packages(up_bytes.decode())
    ours = lock_packages((root / mirror['worker_lock']).read_text())
    pinned = set(mirror['pinned_crates'])
    version = pin['version']

    checked = 0
    for name, versions in sorted(ours.items()):
        if name in pinned:
            continue
        for ver, checksum in sorted(versions.items()):
            if checksum == 'path':
                continue  # the worker crate itself
            checked += 1
            up = upstream.get(name, {})
            if ver not in up:
                bad.append(f'Cargo.lock drift: {name} {ver} is not in upstream\'s lock '
                           f'(upstream has {sorted(up) or "none"})')
            elif up[ver] != checksum:
                bad.append(f'Cargo.lock drift: {name} {ver} checksum differs from upstream\'s')

    for name in sorted(pinned):
        got = sorted(ours.get(name, {}))
        if got != [version]:
            bad.append(f'{name} must be exactly {version} in {mirror["worker_lock"]}, found {got or "none"}')

    manifest = tomllib.loads((root / mirror['worker_manifest']).read_text())
    tables = [manifest.get('dependencies', {})]
    tables += [t.get('dependencies', {}) for t in manifest.get('target', {}).values()]
    reqs = 0
    for deps in tables:
        for name, spec in deps.items():
            if not name.startswith('monty'):
                continue
            reqs += 1
            req = spec if isinstance(spec, str) else spec.get('version')
            if name not in pinned:
                bad.append(f'{mirror["worker_manifest"]}: {name} is not in pinned_crates')
            if req != f'={version}':
                bad.append(f'{mirror["worker_manifest"]}: {name} = {req!r}, must be "={version}"')
    if not reqs:
        bad.append(f'{mirror["worker_manifest"]}: no monty dependencies found')

    if not bad:
        print(f'OK:   {len(mirror["verbatim"])} verbatim file(s) match {pin["tag"]}; '
              f'{checked} crates.io packages are a subset of upstream\'s lock; '
              f'{len(pinned)} monty crates at {version}; {reqs} exact requirements')


def online(mirror: dict, pin: dict, bad: list[str]) -> None:
    commit = pin['commit']
    files = mirror['verbatim'] + mirror['watched'] + [mirror['upstream_lock']]
    for f in files:
        got = sha(fetch(commit, f['upstream']))
        if got != f['sha256']:
            bad.append(f'{f["upstream"]} @ {commit[:12]} hashes {got[:12]}, recorded {f["sha256"][:12]}')
        else:
            print(f'OK:   {f["upstream"]} @ {commit[:12]} {got[:12]}')


def candidate(mirror: dict, pin: dict, tag: str, bad: list[str]) -> None:
    groups = (('VERBATIM (copy, update sha256)', mirror['verbatim']),
              ('WATCHED (review, port by hand)', mirror['watched']))
    for kind, files in groups:
        for f in files:
            old = fetch(pin['commit'], f['upstream']).decode()
            try:
                new = fetch(tag, f['upstream']).decode()
            except OSError as e:
                bad.append(f'{kind} {f["upstream"]}: missing at {tag} ({e})')
                continue
            if old != new:
                diff = ''.join(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                                                    f'{pin["tag"]}/{f["upstream"]}', f'{tag}/{f["upstream"]}'))
                where = f'; mirrored in {f["mirrored_in"]}' if 'mirrored_in' in f else ''
                bad.append(f'{kind} {f["upstream"]} changed ({f.get("why", "")}{where})\n{diff}')


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument('--local', action='store_true')
    mode.add_argument('--online', action='store_true')
    mode.add_argument('--candidate', metavar='TAG')
    ap.add_argument('--root', default=str(Path(__file__).resolve().parent.parent),
                    help='repository root (default: this checkout)')
    a = ap.parse_args()
    root = Path(a.root)
    mirror, pin = load(root)
    bad: list[str] = []
    if a.local:
        local(root, mirror, pin, bad)
        label = 'local'
    elif a.online:
        online(mirror, pin, bad)
        label = 'online'
    else:
        candidate(mirror, pin, a.candidate, bad)
        label = f'candidate {a.candidate}'
    for b in bad:
        print(f'FAIL: {b}')
    print(f'\nworker mirror ({label}, {pin["tag"]} @ {pin["commit"][:12]}): '
          f'{"PASS" if not bad else f"{len(bad)} finding(s)"}')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
