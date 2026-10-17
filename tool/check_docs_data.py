#!/usr/bin/env python3
"""Check documentation versions and optional TSV data tables."""

from __future__ import annotations

from pathlib import Path
import json
import re
import sys

from docs_check_common import parse_exports


SCHEMAS = {
    'migration.tsv': ['area', 'old', 'new', 'kind', 'note'],
    'not-supported.tsv': ['behaviour', 'kind', 'ids', 'evidence', 'dart_monty'],
    'differences.tsv': ['area', 'upstream', 'core', 'evidence'],
    'known-untested.tsv': ['page', 'clause', 'text'],
}


def issue(path: Path, line: int, message: str) -> str:
    return f'{path.as_posix()}:{line}: {message}'


def version_check(root: Path) -> list[str]:
    """Check the package and upstream versions advertised by the README."""
    readme = root / 'README.md'
    pubspec = (root / 'pubspec.yaml').read_text(encoding='utf-8')
    package = re.search(r'^version:\s*([^\s]+)', pubspec, re.M)
    upstream = json.loads((root / 'tool/upstream/upstream-pin.json').read_text())['version']
    expected = package.group(1).split('-', 1)[0] if package else ''
    lines = readme.read_text(encoding='utf-8').splitlines()
    pattern = re.compile(r'^\*\*dart_monty_core (\d+\.\d+\.\d+) · monty (\d+\.\d+\.\d+)\*\*$')
    matches = [(number, pattern.fullmatch(line)) for number, line in enumerate(lines, 1)]
    matches = [(number, match) for number, match in matches if match]
    findings = []
    if len(matches) != 1:
        findings.append('README.md:1: package version line is missing or repeated')
    elif matches[0][1].group(1) != expected or matches[0][1].group(2) != upstream:
        findings.append(f'README.md:{matches[0][0]}: package version line does not match pinned versions')
    version = re.compile(r'\b0\.\d+\.\d+(?:-[A-Za-z0-9.]+)?\b')
    accepted = matches[0][0] if len(matches) == 1 else -1
    for number, line in enumerate(lines, 1):
        if number == accepted:
            continue
        for match in version.finditer(line):
            before = line[:match.start()]
            if 'http://' not in before[max(before.rfind(' '), before.rfind('(')) + 1:] and \
                    'https://' not in before[max(before.rfind(' '), before.rfind('(')) + 1:]:
                findings.append(f'README.md:{number}: unexpected package-style version: {match.group()}')
    return findings


def evidence_paths(root: Path, value: str) -> list[str]:
    """Return repository paths named by backticked evidence tokens."""
    result = []
    for quoted in re.findall(r'`([^`]+)`', value):
        for token in re.split(r'[\s,]+', quoted.strip()):
            if token:
                result.append(token.split(':', 1)[0])
    return result


def check_table(root: Path, filename: str) -> list[str]:
    """Check one optional data table."""
    path = root / 'docs/data' / filename
    if not path.exists():
        return []
    rows = path.read_text(encoding='utf-8').splitlines()
    findings = []
    header = rows[0].split('\t') if rows else []
    if header != SCHEMAS[filename]:
        return [issue(path.relative_to(root), 1, 'unexpected header')]
    seen = set()
    public, members = parse_exports(root / 'tool/export-golden.txt')
    valid_names = public | members
    for number, text in enumerate(rows[1:], 2):
        row = text.split('\t')
        relative = path.relative_to(root)
        if len(row) != len(header):
            findings.append(issue(relative, number, 'wrong number of columns'))
            continue
        key = tuple(row)
        if key in seen:
            findings.append(issue(relative, number, 'duplicate row'))
        seen.add(key)
        values = dict(zip(header, row))
        allowed_empty = set()
        if filename == 'migration.tsv':
            allowed_empty.add('note')
            if values['kind'] in {'removed', 'not-public'}:
                allowed_empty.add('new')
        for column, value in values.items():
            if not value and column not in allowed_empty:
                findings.append(issue(relative, number, f'{column} is empty'))
        if filename == 'migration.tsv':
            kind = values['kind']
            if kind not in {'renamed', 'removed', 'kept-changed', 'moved', 'not-public'}:
                findings.append(issue(relative, number, 'invalid kind'))
            if kind in {'renamed', 'moved'} and values['new'] not in valid_names:
                findings.append(issue(relative, number, 'new name is not public'))
            if kind in {'renamed', 'removed', 'not-public'} and values['old'] in public:
                findings.append(issue(relative, number, 'old name is still public'))
            if kind == 'kept-changed' and values['old'] not in public:
                findings.append(issue(relative, number, 'kept-changed name is not public'))
        if filename == 'not-supported.tsv':
            if values['kind'] not in {'unsupported', 'missing convenience'}:
                findings.append(issue(relative, number, 'invalid kind'))
            if values['dart_monty'] not in {'yes', 'no'}:
                findings.append(issue(relative, number, 'invalid dart_monty value'))
        if 'evidence' in values:
            for evidence in evidence_paths(root, values['evidence']):
                if not (root / evidence).exists():
                    findings.append(issue(relative, number, f'evidence file does not exist: {evidence}'))
    return findings


def check(root: Path) -> list[str]:
    """Return all documentation data findings."""
    findings = version_check(root)
    for filename in SCHEMAS:
        findings.extend(check_table(root, filename))
    return findings


def main() -> int:
    findings = check(Path.cwd())
    print(*findings, sep='\n')
    return int(bool(findings))


if __name__ == '__main__':
    raise SystemExit(main())
