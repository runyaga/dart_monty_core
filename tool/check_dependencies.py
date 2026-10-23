#!/usr/bin/env python3
"""Check dart_monty_core's resolved dependencies against the allowlist.

Rules (see tool/dependency_allowlist.txt):
  1. Forbidden direction: this package must not depend on dart_monty or
     dart_monty_extras -- they sit above dart_monty_core in the layering.
  2. Allowlist: every package pubspec.lock resolves -- direct main, direct
     dev, transitive or overridden, i.e. every entry under `packages:` --
     must be named in tool/dependency_allowlist.txt.

pubspec.lock is not committed; CI generates it with `dart pub get` before
running this check. A missing lockfile or one with no resolved packages is
therefore a failure, never a pass.

Python 3 standard library only: pubspec.lock's `packages:` block is parsed
line by line (no PyYAML). A package entry is exactly a 2-space-indented
`name:` key below `packages:`; deeper-indented keys such as `dependency:`
or `description:` belong to the entry above and the block ends at the first
column-0 key (`sdks:`).

Usage: python3 tool/check_dependencies.py [--lockfile PATH] [--allowlist PATH]
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent
DEFAULT_LOCKFILE = TOOL_DIR.parent / 'pubspec.lock'
DEFAULT_ALLOWLIST = TOOL_DIR / 'dependency_allowlist.txt'

# Packages dart_monty_core must never depend on (forbidden direction).
FORBIDDEN_PACKAGES = ('dart_monty', 'dart_monty_extras')

# A package entry: exactly two spaces, a key with no embedded colon or
# whitespace, a colon, end of line. 4+-space-indented keys do not match.
PACKAGE_KEY = re.compile(r'^  ([^:\s]+):$')


def parse_packages(lock_text: str) -> list[str]:
    """Return the package names in the `packages:` block, in file order.

    Every dependency section of the block (direct main, direct dev,
    transitive, overridden) is an entry at the same 2-space indent, so all
    of them are collected.
    """
    packages: list[str] = []
    in_block = False
    for line in lock_text.splitlines():
        if not in_block:
            if line.strip() == 'packages:':
                in_block = True
            continue
        if not line.strip():
            continue  # blank line inside the block
        if not line.startswith((' ', '\t')):
            break  # column-0 key (e.g. `sdks:`) ends the block
        match = PACKAGE_KEY.match(line)
        if match:
            packages.append(match.group(1))
    return packages


def read_allowlist(path: Path) -> set[str] | None:
    """Allowed package names, or None if the allowlist file is missing.

    One name per line; `#` starts a comment (whole-line or trailing).
    """
    if not path.is_file():
        return None
    names = set()
    for raw in path.read_text(encoding='utf-8').splitlines():
        entry = raw.split('#', 1)[0].strip()
        if entry:
            names.add(entry)
    return names


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description='Check resolved dependencies against the allowlist.')
    parser.add_argument('--lockfile', type=Path, default=DEFAULT_LOCKFILE,
                        help='pubspec.lock to check (default: %(default)s)')
    parser.add_argument('--allowlist', type=Path, default=DEFAULT_ALLOWLIST,
                        help='allowed package names, one per line (default: %(default)s)')
    args = parser.parse_args(argv)

    if not args.lockfile.is_file():
        print(f'{args.lockfile}: missing pubspec.lock -- run `dart pub get` '
              'before this check')
        return 1
    packages = parse_packages(args.lockfile.read_text(encoding='utf-8'))
    if not packages:
        print(f'{args.lockfile}: no packages resolved -- expected a non-empty '
              '`packages:` block')
        return 1
    allowed = read_allowlist(args.allowlist)
    if allowed is None:
        print(f'{args.allowlist}: allowlist file is missing')
        return 1

    violations: list[str] = []
    for name in packages:
        if name in FORBIDDEN_PACKAGES:
            violations.append(
                f'{name}: forbidden dependency direction -- dart_monty_core '
                'must not depend on it')
        elif name not in allowed:
            violations.append(
                f'{name}: resolved in {args.lockfile} but not in the '
                f'dependency allowlist ({args.allowlist})')

    if violations:
        for violation in violations:
            print(violation)
        return 1
    print(f'PASS: {len(packages)} resolved packages all allowed; '
          'no forbidden dependencies')
    return 0


if __name__ == '__main__':
    sys.exit(main())
