#!/usr/bin/env python3
"""Check dart_monty_core's resolved dependencies against the allowlist.

Shared contract (every dart_monty* repository carries a copy of this
checker; only the policy constants below differ):

  * direction -- a resolved package whose name is in FORBIDDEN, or starts
    with one of the FORBIDDEN_PREFIXES while not being in PREFIX_EXEMPT,
    is a violation. This holds even when the name is in the allowlist.
  * allowlist -- a resolved package that is absent from the allowlist is
    a violation. The two rules are checked independently, so a package
    that breaks both produces two findings. An allowlist entry that no
    package resolves is allowed: the allowlist is a set of approved
    names, not an inventory.

Every entry under pubspec.lock's `packages:` block counts as resolved,
whatever its `dependency:` kind -- direct main, direct dev, transitive or
direct overridden. The block is parsed line by line with the standard
library only (no PyYAML): a package is exactly a 2-space-indented
`<name>:` key below `packages:`, lines indented 4 or more spaces belong
to the entry above, and the block ends at the next line at column 0.
Comments (a line whose first non-space character is `#`, or ` #` and
everything after it) and blank lines are stripped first and never end
the block.

Input errors -- a missing or unreadable file, non-UTF-8 content, no
`packages:` block, more than one, an empty block, a duplicate package
key, or a malformed or duplicate allowlist entry -- are each one
`input` finding on stderr, exit 1, never a traceback.

Usage:
  python3 tool/check_dependencies.py [--root DIR] [--lockfile PATH]
      [--allowlist PATH]
  --root defaults to the repository root (the parent of this script's
  directory); relative --lockfile/--allowlist paths resolve against it.
Exit codes: 0 pass, 1 findings, 2 usage error.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# --------------------------------------------------------------- policy ---
# dart_monty_core's row of the shared contract (dependency_check.md,
# section 1). It sits at the bottom of the layering, so it must not
# depend on either package above it; no name prefixes are forbidden
# here, so PREFIX_EXEMPT -- the escape hatch from a prefix rule -- is
# empty.
FORBIDDEN = frozenset({'dart_monty', 'dart_monty_extras'})
FORBIDDEN_PREFIXES = ()
PREFIX_EXEMPT = frozenset()

# ----------------------------------------------------------- constants ----
DEFAULT_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_LOCKFILE = Path('pubspec.lock')
DEFAULT_ALLOWLIST = Path('tool/dependency_allowlist.txt')

# A package key: exactly two spaces, [a-z0-9_]+, a colon, end of line.
PACKAGE_KEY = re.compile(r'^  ([a-z0-9_]+):$')
# A legal allowlist entry.
ALLOWLIST_ENTRY = re.compile(r'^[a-z0-9_]+$')
# A trailing comment: whitespace followed by '#'. A '#' glued to content
# with no whitespace in front is content, not a comment.
TRAILING_COMMENT = re.compile(r'\s#.*$')

NO_BLOCK = "lockfile has no 'packages:' block"
MULTI_BLOCK = "lockfile has more than one 'packages:' block"
EMPTY_BLOCK = "lockfile has an empty 'packages:' block"


# -------------------------------------------------------------- parsing ---
def strip_comment(line: str) -> str:
    """Return `line` without its comment part (may be empty).

    A line whose first non-space character is '#' is a whole-line
    comment. Otherwise a '# preceded by whitespace' starts a trailing
    comment; everything from that whitespace on is removed.
    """
    if line.lstrip().startswith('#'):
        return ''
    return TRAILING_COMMENT.sub('', line)


def cleaned_lines(text: str) -> list[str]:
    """Comment-stripped, right-stripped, non-blank lines, in file order."""
    lines = []
    for raw in text.splitlines():
        line = strip_comment(raw).rstrip()
        if line:
            lines.append(line)
    return lines


def parse_lockfile(text: str) -> tuple[list[str], list[str]]:
    """Return (resolved package names in file order, input error reasons)."""
    packages: list[str] = []
    seen: set[str] = set()
    errors: list[str] = []
    blocks = 0
    in_block = False
    multi_noted = False
    for line in cleaned_lines(text):
        if not in_block:
            # Only an exact column-0 `packages:` starts the block; an
            # indented one is content of the key above it.
            if line == 'packages:':
                blocks += 1
                if blocks == 1:
                    in_block = True
                elif not multi_noted:
                    errors.append(MULTI_BLOCK)
                    multi_noted = True
            continue
        if not line.startswith(' '):
            # The next line at column 0 ends the block.
            in_block = False
            if line == 'packages:':
                blocks += 1
                if not multi_noted:
                    errors.append(MULTI_BLOCK)
                    multi_noted = True
            continue
        indent = len(line) - len(line.lstrip(' '))
        if indent != 2:
            continue  # 4+ spaces: belongs to the current package entry
        match = PACKAGE_KEY.match(line)
        if match is None:
            errors.append(
                f"expected '  <name>:' at 2-space indent, got '{line}'")
            continue
        name = match.group(1)
        if name in seen:
            errors.append(f"lockfile has a duplicate package key '{name}'")
            continue
        seen.add(name)
        packages.append(name)
    if blocks == 0:
        errors.append(NO_BLOCK)
    elif blocks == 1 and not packages:
        errors.append(EMPTY_BLOCK)
    return packages, errors


def parse_allowlist(text: str) -> tuple[set[str], list[str]]:
    """Return (allowed names, input error reasons)."""
    allowed: set[str] = set()
    errors: list[str] = []
    for raw in text.splitlines():
        entry = strip_comment(raw).strip()
        if not entry:
            continue
        if not ALLOWLIST_ENTRY.match(entry):
            errors.append(f"allowlist has a malformed entry '{entry}'")
        elif entry in allowed:
            errors.append(f"allowlist has a duplicate entry '{entry}'")
        else:
            allowed.add(entry)
    return allowed, errors


def read_input(path: Path, label: str) -> tuple[str | None, str | None]:
    """Return (text, None), or (None, input error reason) on failure."""
    try:
        data = path.read_bytes()
    except OSError:
        return None, f'{label} is missing or unreadable'
    try:
        text = data.decode('utf-8')
    except UnicodeDecodeError:
        return None, f'{label} is not valid UTF-8'
    return text, None


# --------------------------------------------------------------- rules ----
def forbidden_reason(name: str) -> str | None:
    """Why `name` breaks the direction rule, or None if it does not."""
    if name in FORBIDDEN:
        return f'forbidden dependency direction ({name} is in FORBIDDEN)'
    if name in PREFIX_EXEMPT:
        return None  # an exempt name escapes the prefix rule only
    for prefix in FORBIDDEN_PREFIXES:
        if name.startswith(prefix):
            return (f'forbidden dependency direction '
                    f"(starts with forbidden prefix '{prefix}')")
    return None


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Check dart_monty_core's resolved dependencies "
                    'against the dependency allowlist.')
    parser.add_argument(
        '--root', type=Path, default=DEFAULT_ROOT,
        help='repository root that relative paths resolve against '
             "(default: the parent of the script's directory)")
    parser.add_argument(
        '--lockfile', type=Path, default=DEFAULT_LOCKFILE,
        help='pubspec.lock to check, relative to --root '
             '(default: %(default)s)')
    parser.add_argument(
        '--allowlist', type=Path, default=DEFAULT_ALLOWLIST,
        help='allowlist to check against, relative to --root '
             '(default: %(default)s)')
    args = parser.parse_args(argv)

    lockfile = (args.lockfile if args.lockfile.is_absolute()
                else args.root / args.lockfile)
    allowlist = (args.allowlist if args.allowlist.is_absolute()
                 else args.root / args.allowlist)

    # (rule, package-or-path, reason) tuples, in report order.
    findings: list[tuple[str, str, str]] = []

    lock_text, error = read_input(lockfile, 'lockfile')
    if error is None:
        packages, errors = parse_lockfile(lock_text)
        findings += [('input', str(lockfile), reason) for reason in errors]
    else:
        packages = []
        findings.append(('input', str(lockfile), error))

    allow_text, error = read_input(allowlist, 'allowlist')
    if error is None:
        allowed, errors = parse_allowlist(allow_text)
        findings += [('input', str(allowlist), reason) for reason in errors]
    else:
        allowed = set()
        findings.append(('input', str(allowlist), error))

    if not findings:  # input errors suppress the rule checks
        for name in packages:
            reason = forbidden_reason(name)
            if reason is not None:
                findings.append(('direction', name, reason))
            if name not in allowed:
                findings.append(
                    ('allowlist', name,
                     'resolved but not in the dependency allowlist'))

    if findings:
        for rule, subject, reason in findings:
            print(f'FAIL {rule} {subject}: {reason}', file=sys.stderr)
        return 1

    print(f'PASS: {len(packages)} resolved packages allowed')
    return 0


if __name__ == '__main__':
    sys.exit(main())
