#!/usr/bin/env python3
"""Verify the upstream reference pin: pydantic/monty by content hash.

The pin is the oracle every parity number is measured against, so it has to
be checkable rather than asserted. Two records, one script:

  tool/upstream/upstream-pin.json    git tag -> commit, and the git tree hash
                                     and file count of every upstream
                                     directory the parity work reads
                                     (test_cases corpus, limitations pages)
  tool/upstream/requirements.lock    pydantic-monty and its wheels, sha256-
                                     pinned for `pip --require-hashes`

Usage:
  python3 -I tool/check_upstream_pin.py            # offline: shape only
  python3 -I tool/check_upstream_pin.py --online   # + fetch and compare

Offline (source-only, in the gate): both files are well formed, every
requirement is `name==version` with at least one sha256 hash, and the three
pydantic-monty distributions carry exactly the pinned version.

Online (CI job `upstream-pin`): the tag still resolves to the recorded commit;
each recorded tree hash and file count equals the tree at that commit; the
lock installs with --require-hashes into a fresh venv; the installed
distributions report the pinned version; and the oracle evaluates `1 + 1` to
2 through its own worker. A git tree hash is a content hash of every file
under the path, so a re-tagged or edited corpus cannot pass.

Exit 0 on pass, 1 on any mismatch, 2 on a malformed record.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
PIN = ROOT / 'tool/upstream/upstream-pin.json'

HEX40 = re.compile(r'^[0-9a-f]{40}$')
HEX64 = re.compile(r'^[0-9a-f]{64}$')
REQ = re.compile(r'^([A-Za-z0-9][A-Za-z0-9._-]*)==([0-9][0-9A-Za-z.+-]*)$')
HASH = re.compile(r'^--hash=sha256:(\S+)$')

failures: list[str] = []


def fail(msg: str) -> None:
    failures.append(msg)
    print(f'FAIL: {msg}')


def ok(msg: str) -> None:
    print(f'OK:   {msg}')


def fatal(msg: str) -> None:
    print(f'FATAL: {msg}')
    sys.exit(2)


def canon(name: str) -> str:
    return re.sub(r'[-_.]+', '-', name).lower()


def load_pin() -> dict:
    try:
        pin = json.loads(PIN.read_text())
    except (OSError, ValueError) as e:
        fatal(f'{PIN.relative_to(ROOT)} unreadable: {e}')
    for key in ('upstream', 'version', 'tag', 'commit', 'trees', 'python'):
        if key not in pin:
            fatal(f'{PIN.relative_to(ROOT)} has no "{key}"')
    return pin


def parse_lock(path: Path) -> dict[str, tuple[str, list[str]]]:
    """Return {canonical name: (version, [sha256, ...])}."""
    text = path.read_text()
    logical: list[str] = []
    buf = ''
    for raw in text.splitlines():
        line = re.sub(r'(^|\s)#.*$', '', raw).rstrip()
        if not line.strip():
            if buf:
                logical.append(buf)
                buf = ''
            continue
        if line.endswith('\\'):
            buf += line[:-1].strip() + ' '
        else:
            buf += line.strip()
            logical.append(buf)
            buf = ''
    if buf:
        logical.append(buf)

    reqs: dict[str, tuple[str, list[str]]] = {}
    for entry in logical:
        tokens = entry.split()
        m = REQ.match(tokens[0])
        if not m:
            fail(f'lock: not an exact `name==version` requirement: {tokens[0]!r}')
            continue
        name, version = canon(m.group(1)), m.group(2)
        hashes = []
        for tok in tokens[1:]:
            h = HASH.match(tok)
            if not h:
                fail(f'lock: {name}: unexpected token {tok!r} (only --hash=sha256:... allowed)')
                continue
            if not HEX64.match(h.group(1)):
                fail(f'lock: {name}: not a sha256 digest: {h.group(1)!r}')
                continue
            hashes.append(h.group(1))
        if not hashes:
            fail(f'lock: {name}=={version} has no --hash (pip --require-hashes would refuse it)')
        if len(set(hashes)) != len(hashes):
            fail(f'lock: {name}: duplicate hash')
        if name in reqs:
            fail(f'lock: {name} listed twice')
        reqs[name] = (version, hashes)
    return reqs


def offline(pin: dict) -> dict[str, tuple[str, list[str]]]:
    version = pin['version']
    if pin['tag'] != f'v{version}':
        fail(f'tag {pin["tag"]!r} is not v{version}')
    if not HEX40.match(pin['commit']):
        fail(f'commit {pin["commit"]!r} is not a 40-hex git object id')
    if not pin['trees']:
        fail('no trees recorded')
    for t in pin['trees']:
        if not HEX40.match(t.get('git_tree', '')):
            fail(f'{t.get("path")}: git_tree is not a 40-hex git object id')
        if not isinstance(t.get('files'), int) or t['files'] <= 0:
            fail(f'{t.get("path")}: files must be a positive integer')
    ok(f'pin record: {pin["upstream"]} {pin["tag"]} @ {pin["commit"][:12]}, {len(pin["trees"])} trees')

    lock = ROOT / pin['python']['lock']
    if not lock.is_file():
        fatal(f'{pin["python"]["lock"]} missing')
    reqs = parse_lock(lock)
    dists = {canon(k): v for k, v in pin['python']['distributions'].items()}
    for name, want in dists.items():
        if want != version:
            fail(f'pin: {name} pinned at {want}, upstream version is {version}')
        got = reqs.get(name)
        if got is None:
            fail(f'lock: {name} missing')
        elif got[0] != want:
            fail(f'lock: {name}=={got[0]}, pin says {want}')
    n_hashes = sum(len(h) for _, h in reqs.values())
    ok(f'lock: {len(reqs)} requirements, {n_hashes} sha256 hashes, '
       f'{", ".join(f"{n}=={v}" for n, (v, _) in sorted(reqs.items()))}')
    return reqs


def run(cmd: list[str], cwd: Path | None = None) -> str:
    p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    if p.returncode != 0:
        fail(f'`{" ".join(cmd)}` exited {p.returncode}: {p.stderr.strip()[-400:]}')
        return ''
    return p.stdout


def online(pin: dict) -> None:
    url = pin['upstream'] + '.git'
    tag = pin['tag']
    # A lightweight tag has no peeled (^{}) line; an annotated one does, and
    # the peeled commit is what counts.
    refs = {}
    for line in run(['git', 'ls-remote', url, f'refs/tags/{tag}', f'refs/tags/{tag}^{{}}']).splitlines():
        sha, ref = line.split('\t')
        refs[ref] = sha
    resolved = refs.get(f'refs/tags/{tag}^{{}}') or refs.get(f'refs/tags/{tag}')
    if resolved != pin['commit']:
        fail(f'{tag} resolves to {resolved}, pin records {pin["commit"]}')
    else:
        ok(f'{tag} -> {resolved}')

    with tempfile.TemporaryDirectory(prefix='upstream-pin-') as tmp:
        repo = Path(tmp) / 'monty'
        repo.mkdir()
        run(['git', 'init', '-q'], repo)
        # Trees only: tree hashes and file counts need no blob contents.
        run(['git', 'fetch', '-q', '--depth', '1', '--filter=blob:none', url, pin['commit']], repo)
        for t in pin['trees']:
            spec = f'{pin["commit"]}:{t["path"]}'
            tree = run(['git', 'rev-parse', spec], repo).strip()
            files = run(['git', 'ls-tree', '-r', '--name-only', pin['commit'], '--', t['path']], repo).splitlines()
            if tree != t['git_tree']:
                fail(f'{t["path"]}: tree {tree}, pin records {t["git_tree"]}')
            elif len(files) != t['files']:
                fail(f'{t["path"]}: {len(files)} files, pin records {t["files"]}')
            else:
                ok(f'{t["path"]}: tree {tree[:12]}, {len(files)} files')

        venv = Path(tmp) / 'venv'
        run([sys.executable, '-m', 'venv', str(venv)])
        py = venv / ('Scripts/python.exe' if sys.platform == 'win32' else 'bin/python')
        before = len(failures)
        run([str(py), '-m', 'pip', 'install', '-q', '--disable-pip-version-check', '--no-cache-dir',
             '--require-hashes', '--only-binary', ':all:', '--no-deps',
             '-r', str(ROOT / pin['python']['lock'])])
        if len(failures) > before:
            return  # the install failed; a smoke run would only repeat it
        smoke = (
            'import importlib.metadata as md, json, pydantic_monty as pm\n'
            'names = json.loads(__import__("sys").argv[1])\n'
            'with pm.Monty() as pool:\n'
            '    with pool.checkout() as s:\n'
            '        r = s.feed_run("1 + 1")\n'
            'print(json.dumps({"versions": {n: md.version(n) for n in names}, "one_plus_one": r}))\n'
        )
        names = list(pin['python']['distributions'])
        out = run([str(py), '-I', '-c', smoke, json.dumps(names)], Path(tmp))
        if out:
            got = json.loads(out.strip().splitlines()[-1])
            for n in names:
                if got['versions'][n] != pin['python']['distributions'][n]:
                    fail(f'installed {n} {got["versions"][n]}, pin says {pin["python"]["distributions"][n]}')
            if got['one_plus_one'] != 2:
                fail(f'oracle smoke: 1 + 1 -> {got["one_plus_one"]!r}')
            if len(failures) == before:
                ok(f'oracle installed with --require-hashes on Python '
                   f'{sys.version_info.major}.{sys.version_info.minor}: '
                   f'{", ".join(f"{n} {v}" for n, v in got["versions"].items())}; 1 + 1 -> 2')


def main() -> None:
    args = sys.argv[1:]
    if args not in ([], ['--online']):
        print(__doc__)
        sys.exit(2)
    pin = load_pin()
    offline(pin)
    if args == ['--online']:
        online(pin)
    if failures:
        print(f'\nupstream pin: {len(failures)} failure(s)')
        sys.exit(1)
    print('\nPASS: upstream pin' + (' (verified online)' if args else ' (offline shape)'))


if __name__ == '__main__':
    main()
