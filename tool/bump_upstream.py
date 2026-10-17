#!/usr/bin/env python3
"""Prepare a reviewable dart_monty_core bump for a released monty tag.

The command deliberately uses git tags rather than GitHub releases.  Its pure
helpers are kept separate from network and checkout work so they can be
exercised in an offline Python test.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Iterable


UPSTREAM = 'https://github.com/pydantic/monty.git'
PIN_PATH = Path('tool/upstream/upstream-pin.json')
MIRROR_PATH = Path('tool/upstream/worker-mirror.json')
LOCK_PATH = Path('tool/upstream/requirements.lock')
DIST_NAMES = ('pydantic-monty', 'pydantic-monty-client', 'pydantic-monty-runtime')
TAG_RE = re.compile(r'^v(\d+)\.(\d+)\.(\d+)$')
WORKSPACE_MONTY_CRATES = (
    'monty', 'monty-type-checking', 'monty-macros', 'monty-typeshed',
    'monty-proto', 'monty-types', 'monty-alloc', 'monty-fs',
)


def semver(tag: str) -> tuple[int, int, int] | None:
    """Return the stable tag's numeric version, or None for every other ref."""
    match = TAG_RE.fullmatch(tag)
    return tuple(map(int, match.groups())) if match else None


def stable_tags(ls_remote: str) -> list[str]:
    """Extract stable release tags from git ls-remote output, including peels."""
    tags: set[str] = set()
    for line in ls_remote.splitlines():
        fields = line.split('\t', 1)
        if len(fields) != 2:
            continue
        ref = fields[1]
        if not ref.startswith('refs/tags/'):
            continue
        tag = ref.removeprefix('refs/tags/').removesuffix('^{}')
        if semver(tag) is not None:
            tags.add(tag)
    return sorted(tags, key=lambda tag: semver(tag) or (0, 0, 0))


def newer_tag(ls_remote: str, current_tag: str) -> str | None:
    """Return the greatest stable tag newer than current_tag."""
    current = semver(current_tag)
    if current is None:
        raise ValueError(f'pin tag {current_tag!r} is not a stable vN.N.N tag')
    later = [tag for tag in stable_tags(ls_remote) if (semver(tag) or current) > current]
    return later[-1] if later else None


def mapped_core_version(version: str, dev: bool = False) -> str:
    """Map upstream M.m.p to 0.Mm0.p, refusing ambiguous major/minor values."""
    parsed = semver(f'v{version}')
    if parsed is None:
        raise ValueError(f'upstream version {version!r} is not M.m.p')
    major, minor, patch = parsed
    if major > 9 or minor > 9:
        raise ValueError(f'upstream version {version!r} needs an owner decision for version mapping')
    value = f'0.{major}{minor}0.{patch}'
    return value + '-dev.1' if dev else value


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def rewrite_pin_text(text: str, *, version: str, commit: str,
                     trees: dict[str, tuple[str, int]]) -> str:
    """Rewrite pin values while retaining its JSON order and two-space layout."""
    pin = json.loads(text)
    pin['version'] = version
    pin['tag'] = f'v{version}'
    pin['commit'] = commit
    for entry in pin['trees']:
        git_tree, files = trees[entry['path']]
        entry['git_tree'] = git_tree
        entry['files'] = files
    for name in pin['python']['distributions']:
        pin['python']['distributions'][name] = version
    # The committed pin uses this exact form. json preserves parsed object key
    # order, so only values change and no hand-maintained order is lost.
    return json.dumps(pin, indent=2) + '\n'


def accepted_pypi_file(name: str, file: dict[str, Any]) -> bool:
    """Whether a PyPI artifact is supported for one pinned distribution."""
    filename = str(file.get('filename', ''))
    match = re.match(r'^(.+)-\d', filename)
    if not match:
        return False
    normalized_name = re.sub(r'[-.]', '_', name).lower()
    normalized_filename_name = re.sub(r'[-.]', '_', match.group(1)).lower()
    if normalized_filename_name != normalized_name:
        return False
    if file.get('packagetype') == 'sdist':
        return True
    if not filename.endswith('.whl'):
        return False
    if name == 'pydantic-monty':
        return filename.endswith('-py3-none-any.whl')
    if name == 'pydantic-monty-runtime':
        return bool(re.search(r'-py3-none-'
                              r'(manylinux_2_28_x86_64|macosx_11_0_arm64)\.whl$', filename))
    return bool(re.search(r'-(cp312|cp313|cp314)-\1-'
                          r'(manylinux_2_28_x86_64|macosx_11_0_arm64)\.whl$', filename))


def selected_hashes(name: str, payload: dict[str, Any]) -> list[str]:
    """Return sorted eligible PyPI artifact hashes from one JSON response."""
    urls = payload.get('urls', [])
    selected: list[tuple[str, str]] = []
    for item in urls:
        digest = item.get('digests', {}).get('sha256')
        if accepted_pypi_file(name, item) and isinstance(digest, str):
            selected.append((str(item.get('filename', '')), digest))
    return [digest for _, digest in sorted(selected)]


def lock_header_and_typing(text: str) -> tuple[str, str]:
    """Split a committed requirements lock into immutable header and typing entry."""
    first = re.search(r'(?m)^pydantic-monty==', text)
    typing = re.search(r'(?m)^typing-extensions==', text)
    if not first or not typing:
        raise ValueError('requirements lock must have pydantic-monty and typing-extensions entries')
    return text[:first.start()], text[typing.start():]


def render_requirement(name: str, version: str, hashes: Iterable[str]) -> str:
    hashes = list(hashes)
    if not hashes:
        raise ValueError(f'PyPI has no supported artifacts for {name}=={version}')
    lines = [f'{name}=={version} \\']
    lines.extend(f'    --hash=sha256:{digest}' + (' \\' if i + 1 < len(hashes) else '')
                 for i, digest in enumerate(hashes))
    return '\n'.join(lines) + '\n'


def render_lock(old_text: str, version: str, pypi: dict[str, dict[str, Any]]) -> str:
    """Render updated monty entries while retaining header and typing lock exactly."""
    header, typing = lock_header_and_typing(old_text)
    entries = []
    for name in DIST_NAMES:
        payload = pypi[name]
        info_version = payload.get('info', {}).get('version')
        if info_version != version:
            raise ValueError(f'PyPI payload for {name} reports {info_version!r}, want {version!r}')
        entries.append(render_requirement(name, version, selected_hashes(name, payload)))
    return header + ''.join(entries) + typing


def render_body(old_tag: str, tag: str, old_commit: str, new_commit: str,
                evidence: list[dict[str, Any]], mirror_diff: str) -> str:
    """Render the draft PR body from saved follow evidence and mirror review output."""
    version = tag.removeprefix('v')
    lines = [
        f'Upstream pin: {old_tag} ({old_commit[:12]}) to {tag} ({new_commit[:12]}).',
        f'Core version: {mapped_core_version(version)}.',
        '', '### Follow evidence', '',
    ]
    if not evidence:
        lines.append('- No commits were followed.')
    for item in evidence:
        sha = str(item.get('sha', item.get('commit', 'unknown')))
        subject = str(item.get('subject', 'not followed'))
        flags = ', '.join(map(str, item.get('flags', []))) or 'none'
        verdict = str(item.get('verdict', item.get('gate', 'not followed')))
        new = ', '.join(map(str, item.get('new_failures', []))) or 'none'
        fixed = ', '.join(map(str, item.get('fixed_failures', []))) or 'none'
        lines.append(f'- `{sha[:12]}` {subject}. Flags: {flags}. Verdict: {verdict}. '
                     f'New failures: {new}. Fixed failures: {fixed}.')
    lines.extend(['', '### Watched-file diff', ''])
    lines.append(mirror_diff.rstrip() if mirror_diff.strip() else 'No watched-file differences reported.')
    lines.extend([
        '', '### Still manual', '',
        '- [ ] Port watched files.',
        '- [ ] Make Dart changes for each new failure listed above.',
        '- [ ] Update the parity repository with expected outcomes regenerated on Linux, then update PARITY_PIN.',
        '- [ ] Update the dart_monty repository.',
        '- [ ] Open the release PR and tag within 7 days of the upstream tag.',
        '',
    ])
    return '\n'.join(lines)


def run(args: list[str], cwd: Path | None = None) -> str:
    completed = subprocess.run(args, cwd=cwd, text=True, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE)
    if completed.returncode:
        raise RuntimeError(f'command failed ({completed.returncode}): {" ".join(args)}\n'
                           f'{completed.stderr.strip()}')
    return completed.stdout.strip()


def git(upstream: Path, *args: str) -> str:
    return run(['git', '-C', str(upstream), *args])


def fetch_pypi(name: str, version: str) -> dict[str, Any]:
    url = f'https://pypi.org/pypi/{name}/{version}/json'
    try:
        with urllib.request.urlopen(url, timeout=30) as response:
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        if error.code == 404:
            raise FileNotFoundError(f'{name}=={version} is not on PyPI yet. Rerun after publication.') from error
        raise


def load_worker_mirror() -> Any:
    """Load the sibling checker without relying on Python's import path."""
    checker = Path(__file__).with_name('check_worker_mirror.py')
    spec = importlib.util.spec_from_file_location('check_worker_mirror', checker)
    if spec is None or spec.loader is None:
        raise RuntimeError(f'could not load {checker}')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pin_worker_lock(core: Path, version: str) -> None:
    """Pin workspace monty crates that Cargo resolved from crates.io."""
    if semver(f'v{version}') is None:
        raise ValueError('--version must be M.N.P')
    worker = core / 'native/worker'
    present = set(re.findall(r'(?m)^name\s*=\s*"([^"]+)"$',
                             (worker / 'Cargo.lock').read_text()))
    for crate in WORKSPACE_MONTY_CRATES:
        if crate in present:
            run(['cargo', 'update', '-p', crate, '--precise', version], cwd=worker)


def rewrite_versions(manifest: str, upstream_version: str, core_version: str) -> str:
    manifest = re.sub(r'(?m)^version\s*=\s*"[^"]+"$', f'version = "{core_version}"', manifest,
                      count=1)
    return re.sub(r'(monty(?:-[a-z-]+)?\s*=\s*(?:\{\s*version\s*=\s*)?")='
                  + re.escape(upstream_version) + r'(")',
                  rf'\g<1>={upstream_version}\g<2>', manifest)


def write(path: Path, data: bytes, dry_run: bool) -> bool:
    current = path.read_bytes() if path.exists() else None
    if current == data:
        return False
    print(('would update ' if dry_run else 'updated ') + str(path))
    if not dry_run:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
    return True


def clone_tag(workdir: Path, tag: str) -> Path:
    checkout = workdir / 'monty'
    if checkout.exists():
        shutil.rmtree(checkout)
    workdir.mkdir(parents=True, exist_ok=True)
    run(['git', 'clone', '--filter=blob:none', '--no-checkout', UPSTREAM, str(checkout)])
    run(['git', '-C', str(checkout), 'checkout', '--detach', tag])
    return checkout


def apply(tag: str, core: Path, workdir: Path, dry_run: bool) -> int:
    pin_file = core / PIN_PATH
    pin = json.loads(pin_file.read_text())
    if tag == pin['tag']:
        print(f'{tag} is already pinned. No tracked files change.')
        return 0
    version = tag.removeprefix('v')
    if semver(tag) is None:
        raise ValueError('--tag must be a stable vN.N.N tag')
    mapped_core_version(version, dev=True)  # validate before network work
    upstream = clone_tag(workdir, tag)
    commit = git(upstream, 'rev-parse', f'{tag}^{{}}')
    trees: dict[str, tuple[str, int]] = {}
    for tree in pin['trees']:
        path = tree['path']
        trees[path] = (git(upstream, 'rev-parse', f'{tag}:{path}'),
                       len(git(upstream, 'ls-tree', '-r', '--name-only', tag, '--', path).splitlines()))
    pypi: dict[str, dict[str, Any]] = {}
    try:
        for name in DIST_NAMES:
            pypi[name] = fetch_pypi(name, version)
    except FileNotFoundError as error:
        print(f'NOT PUBLISHED: {error}', file=sys.stderr)
        return 3

    write(pin_file, rewrite_pin_text(pin_file.read_text(), version=version, commit=commit, trees=trees).encode(), dry_run)
    lock_file = core / LOCK_PATH
    write(lock_file, render_lock(lock_file.read_text(), version, pypi).encode(), dry_run)

    mirror_file = core / MIRROR_PATH
    mirror = json.loads(mirror_file.read_text())
    watched_changed: list[str] = []
    for entry in mirror['verbatim'] + mirror['watched'] + [mirror['upstream_lock']]:
        fresh = (upstream / entry['upstream']).read_bytes()
        changed = sha256(fresh) != entry['sha256']
        entry['sha256'] = sha256(fresh)
        if entry in mirror['watched'] and changed:
            watched_changed.append(entry['upstream'])
        if 'local' in entry:
            write(core / entry['local'], fresh, dry_run)
    try:
        check_worker_mirror = load_worker_mirror()
        for name in mirror['pinned_crates']:
            mirror['pinned_crates'][name] = check_worker_mirror.crates_io_checksum(name, version)
    except (OSError, ValueError) as error:
        raise RuntimeError(f'could not fetch crates.io checksums: {error}') from error
    write(mirror_file, (json.dumps(mirror, indent=2) + '\n').encode(), dry_run)
    write(core / mirror['upstream_lock']['local'], (upstream / 'Cargo.lock').read_bytes(), dry_run)

    manifest = core / mirror['worker_manifest']
    new_manifest = rewrite_versions(manifest.read_text(), str(pin['version']), mapped_core_version(version, dev=True))
    # Exact monty requirements must use the new upstream version even if a
    # manifest had been locally changed before the bump.
    new_manifest = re.sub(r'(monty(?:-[a-z-]+)?\s*=\s*(?:\{\s*version\s*=\s*)?")=[^"]+(\")',
                          rf'\g<1>={version}\g<2>', new_manifest)
    write(manifest, new_manifest.encode(), dry_run)
    worker_lock = core / mirror['worker_lock']
    write(worker_lock, (upstream / 'Cargo.lock').read_bytes(), dry_run)

    pubspec = core / 'pubspec.yaml'
    pubspec_text = re.sub(r'(?m)^version:\s*\S+$', f'version: {mapped_core_version(version, dev=True)}',
                          pubspec.read_text(), count=1)
    write(pubspec, pubspec_text.encode(), dry_run)
    fragment = core / f'changes/upstream-{tag}.md'
    write(fragment, f'### Changed\n\nPins upstream monty {tag}.\n'.encode(), dry_run)
    if watched_changed:
        print('WATCHED files requiring a manual port:')
        print('\n'.join(f'- {path}' for path in watched_changed))
    else:
        print('No watched files changed.')
    return 0


def command_latest(args: argparse.Namespace) -> int:
    pin = json.loads(Path(args.pin).read_text())
    output = Path(args.tags_file).read_text() if args.tags_file else run(
        ['git', 'ls-remote', '--tags', UPSTREAM, 'refs/tags/v*'])
    tag = newer_tag(output, pin['tag'])
    if tag:
        print(tag)
    return 0


def first_parent_commits(old_commit: str, new_commit: str) -> list[tuple[str, str]]:
    """Return every first-parent commit after old_commit through new_commit.

    The release workflow supplies the checkout made by ``apply`` through
    MONTY_CHECKOUT. A direct invocation fetches just the two required commit
    histories into a temporary blobless repository.
    """
    checkout_value = os.environ.get('MONTY_CHECKOUT')
    checkout = Path(checkout_value) if checkout_value else None
    temporary: tempfile.TemporaryDirectory[str] | None = None
    if checkout is None:
        temporary = tempfile.TemporaryDirectory(prefix='bump-upstream-body-')
        checkout = Path(temporary.name) / 'monty'
        run(['git', 'init', '-q', str(checkout)])
        run(['git', '-C', str(checkout), 'fetch', '-q', '--filter=blob:none', UPSTREAM,
             old_commit, new_commit])
    try:
        output = git(checkout, 'log', '--first-parent', '--reverse', '--format=%H%x09%s',
                     f'{old_commit}..{new_commit}')
        return [tuple(line.split('\t', 1)) for line in output.splitlines() if line]
    finally:
        if temporary is not None:
            temporary.cleanup()


def evidence_lines(path: Path, old_commit: str, new_commit: str) -> list[dict[str, Any]]:
    records = [json.loads(line) for line in path.read_text().splitlines() if line.strip()]
    by_sha = {str(row.get('sha', row.get('commit', ''))): row for row in records}
    rows = []
    for sha, subject in first_parent_commits(old_commit, new_commit):
        if sha in by_sha:
            rows.append(by_sha[sha])
        else:
            rows.append({'sha': sha, 'subject': subject, 'flags': [], 'verdict': 'not followed',
                         'new_failures': [], 'fixed_failures': []})
    return rows


def command_body(args: argparse.Namespace) -> int:
    core = Path(args.core)
    pin = json.loads((core / PIN_PATH).read_text())
    evidence = evidence_lines(Path(args.evidence), args.old_commit, str(pin['commit']))
    Path(args.out).write_text(render_body(args.old_tag or 'previous pin', args.tag, args.old_commit,
                                          str(pin['commit']), evidence,
                                          Path(args.mirror_diff).read_text()))
    return 0


def command_pin_lock(args: argparse.Namespace) -> int:
    pin_worker_lock(args.core, args.version)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    latest = sub.add_parser('latest-tag')
    latest.add_argument('--pin', default=str(PIN_PATH))
    latest.add_argument('--tags-file')
    latest.set_defaults(func=command_latest)
    change = sub.add_parser('apply')
    change.add_argument('--tag', required=True)
    change.add_argument('--core', required=True, type=Path)
    change.add_argument('--workdir', required=True, type=Path)
    change.add_argument('--dry-run', action='store_true')
    change.set_defaults(func=lambda a: apply(a.tag, a.core, a.workdir, a.dry_run))
    pin_lock = sub.add_parser('pin-lock')
    pin_lock.add_argument('--core', required=True, type=Path)
    pin_lock.add_argument('--version', required=True)
    pin_lock.set_defaults(func=command_pin_lock)
    body = sub.add_parser('body')
    body.add_argument('--core', required=True)
    body.add_argument('--tag', required=True)
    body.add_argument('--old-commit', required=True)
    body.add_argument('--old-tag')
    body.add_argument('--evidence', required=True)
    body.add_argument('--mirror-diff', required=True)
    body.add_argument('--out', required=True)
    body.set_defaults(func=command_body)
    args = parser.parse_args()
    try:
        return args.func(args)
    except (OSError, ValueError, RuntimeError) as error:
        print(f'FAIL: {error}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
