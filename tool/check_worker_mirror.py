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
  - native/worker/Cargo.lock has exactly one source-less entry, the worker
    crate itself; every other entry comes from the crates.io registry with a
    checksum, so a path, git or [patch] override cannot stand in for upstream
    code while reporting upstream's version;
  - every crates.io package appears in upstream's lock with the same version
    and checksum (the lock is a subset of upstream's; a fresh resolution that
    drifts, e.g. to salsa 0.28.5, fails);
  - the monty crates, which upstream's lock records as workspace members
    without a checksum, are exactly the pinned version with the crates.io
    checksum recorded in pinned_crates;
  - native/worker/Cargo.toml has no [patch] or [replace] table and no path,
    git or alternate-registry dependency, and its monty crates are `=X`
    requirements;
  - no .cargo/config* that Cargo reads when building from native/worker/
    (that directory, native/, the repository root) has a [patch] or [source]
    table or a `paths` override.

--online: every verbatim and watched upstream file, and upstream's Cargo.lock,
still hashes to its recorded sha256 at the pinned commit, and every
pinned_crates checksum is the one the crates.io index publishes for the pin.

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
INDEX = 'https://index.crates.io/{prefix}/{name}'
MIRROR = 'tool/upstream/worker-mirror.json'
HEX64 = re.compile(r'^[0-9a-f]{64}$')
CRATES_IO = 'registry+https://github.com/rust-lang/crates.io-index'
WORKER = 'dart_monty_worker'
# Dependency tables and the keys that point one away from crates.io.
DEP_TABLES = ('dependencies', 'dev-dependencies', 'build-dependencies')
NON_REGISTRY = ('path', 'git', 'registry', 'registry-index', 'package')
# Cargo reads .cargo/config* from the working directory up; CI builds from
# native/worker/.
CARGO_CONFIG_DIRS = ('native/worker/.cargo', 'native/.cargo', '.cargo')
CARGO_CONFIG_OVERRIDES = ('patch', 'source', 'paths')


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def fetch(ref: str, path: str) -> bytes:
    with urllib.request.urlopen(RAW.format(ref=ref, path=path), timeout=30) as r:
        return r.read()


def fatal(msg: str) -> None:
    print(f'FATAL: {msg}')
    sys.exit(2)


def lock_packages(text: str) -> dict[str, dict[str, str | None]]:
    """{name: {version: checksum}} for the crates.io packages of a Cargo.lock.

    Workspace/path packages (no source) map to None. Any other source raises
    ValueError, naming the package.
    """
    out: dict[str, dict[str, str | None]] = {}
    for pkg in tomllib.loads(text).get('package', []):
        source = pkg.get('source')
        if source is not None and source != CRATES_IO:
            raise ValueError(f'{pkg["name"]} {pkg["version"]}: source {source}')
        out.setdefault(pkg['name'], {})[pkg['version']] = pkg.get('checksum') if source else None
    return out


def dep_tables(manifest: dict) -> list[tuple[str, dict]]:
    """(label, table) for every dependency table, target-specific ones included."""
    out = [(t, manifest.get(t, {})) for t in DEP_TABLES]
    for cfg, target in manifest.get('target', {}).items():
        out += [(f'target.{cfg}.{t}', target.get(t, {})) for t in DEP_TABLES]
    return out


def check_manifest(root: Path, mirror: dict, version: str, bad: list[str]) -> int:
    """Checks the worker's Cargo.toml; returns the number of monty requirements."""
    path = mirror['worker_manifest']
    manifest = tomllib.loads((root / path).read_text())
    for table in ('patch', 'replace'):
        if table in manifest:
            bad.append(f'{path}: [{table}] table overrides crates.io sources; the worker builds '
                       'upstream\'s published crates only')
    if manifest.get('package', {}).get('name') != WORKER:
        bad.append(f'{path}: package is {manifest.get("package", {}).get("name")!r}, expected {WORKER!r}')
    pinned = mirror['pinned_crates']
    reqs = 0
    for label, deps in dep_tables(manifest):
        for name, spec in deps.items():
            if isinstance(spec, dict):
                for key in NON_REGISTRY:
                    if key in spec:
                        bad.append(f'{path} [{label}] {name}: {key!r} dependency; only crates.io '
                                   'version requirements are allowed')
            if not name.startswith('monty'):
                continue
            reqs += 1
            req = spec if isinstance(spec, str) else spec.get('version')
            if name not in pinned:
                bad.append(f'{path}: {name} is not in pinned_crates')
            if req != f'={version}':
                bad.append(f'{path}: {name} = {req!r}, must be "={version}"')
    if not reqs:
        bad.append(f'{path}: no monty dependencies found')
    return reqs


def check_cargo_config(root: Path, bad: list[str]) -> int:
    """Rejects source overrides in any .cargo/config* a worker build reads."""
    seen = 0
    for d in CARGO_CONFIG_DIRS:
        for f in sorted((root / d).glob('config*')):
            seen += 1
            rel = f.relative_to(root).as_posix()
            try:
                config = tomllib.loads(f.read_text())
            except (OSError, ValueError) as e:
                bad.append(f'{rel}: unreadable ({e})')
                continue
            for key in CARGO_CONFIG_OVERRIDES:
                if key in config:
                    bad.append(f'{rel}: [{key}] overrides where crates come from; the worker builds '
                               'upstream\'s published crates only')
    return seen


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
    pinned = mirror['pinned_crates']
    if not isinstance(pinned, dict) or not pinned:
        fatal(f'{MIRROR}: pinned_crates must map each crate to its crates.io checksum')
    for name, checksum in pinned.items():
        if not isinstance(checksum, str) or not HEX64.match(checksum):
            fatal(f'{MIRROR}: pinned_crates.{name} is not 64 hex digits')
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
    try:
        upstream = lock_packages(up_bytes.decode())
    except ValueError as e:
        fatal(f'{up_lock["local"]}: unsupported source: {e}')
    pinned = mirror['pinned_crates']
    version = pin['version']
    lock_path = mirror['worker_lock']

    checked = 0
    worker_entries = 0
    found: dict[str, list[str]] = {}
    for pkg in tomllib.loads((root / lock_path).read_text()).get('package', []):
        name, ver = pkg['name'], pkg['version']
        source, checksum = pkg.get('source'), pkg.get('checksum')
        found.setdefault(name, []).append(ver)
        if source is None:
            if name == WORKER:
                worker_entries += 1
            else:
                bad.append(f'{lock_path}: {name} {ver} has no source (a path, workspace or [patch] '
                           f'override); only {WORKER} itself may')
            continue
        if source != CRATES_IO:
            bad.append(f'{lock_path}: {name} {ver} comes from {source}, not crates.io')
            continue
        if not checksum:
            bad.append(f'{lock_path}: {name} {ver} has no checksum')
            continue
        checked += 1
        if name in pinned:
            if ver != version:
                continue  # reported below
            if checksum != pinned[name]:
                bad.append(f'{lock_path}: {name} {ver} checksum {checksum[:12]} is not the published '
                           f'crate\'s {pinned[name][:12]} (pinned_crates)')
            continue
        up = upstream.get(name, {})
        if ver not in up:
            bad.append(f'Cargo.lock drift: {name} {ver} is not in upstream\'s lock '
                       f'(upstream has {sorted(up) or "none"})')
        elif up[ver] != checksum:
            bad.append(f'Cargo.lock drift: {name} {ver} checksum differs from upstream\'s')
    if worker_entries != 1:
        bad.append(f'{lock_path}: {worker_entries} {WORKER} entries, expected 1')

    for name in sorted(pinned):
        got = sorted(found.get(name, []))
        if got != [version]:
            bad.append(f'{name} must be exactly {version} in {lock_path}, found {got or "none"}')

    reqs = check_manifest(root, mirror, version, bad)
    configs = check_cargo_config(root, bad)

    if not bad:
        print(f'OK:   {len(mirror["verbatim"])} verbatim file(s) match {pin["tag"]}; '
              f'{checked} crates.io packages, {len(pinned)} of them monty crates at {version} with '
              f'pinned checksums, the rest a subset of upstream\'s lock; {reqs} exact requirements; '
              f'no source overrides in the manifest or {configs} cargo config file(s)')


def online(mirror: dict, pin: dict, bad: list[str]) -> None:
    commit = pin['commit']
    files = mirror['verbatim'] + mirror['watched'] + [mirror['upstream_lock']]
    for f in files:
        got = sha(fetch(commit, f['upstream']))
        if got != f['sha256']:
            bad.append(f'{f["upstream"]} @ {commit[:12]} hashes {got[:12]}, recorded {f["sha256"][:12]}')
        else:
            print(f'OK:   {f["upstream"]} @ {commit[:12]} {got[:12]}')
    version = pin['version']
    for name, checksum in sorted(mirror['pinned_crates'].items()):
        prefix = {1: '1', 2: '2', 3: f'3/{name[0]}'}.get(len(name), f'{name[:2]}/{name[2:4]}')
        url = INDEX.format(prefix=prefix, name=name)
        with urllib.request.urlopen(url, timeout=30) as r:
            lines = [json.loads(line) for line in r.read().decode().splitlines() if line]
        published = [e['cksum'] for e in lines if e.get('vers') == version]
        if published != [checksum]:
            bad.append(f'crates.io {name} {version}: index has {published or "nothing"}, '
                       f'pinned_crates records {checksum[:12]}')
        else:
            print(f'OK:   crates.io {name} {version} {checksum[:12]}')


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
