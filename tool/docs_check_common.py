"""Shared helpers for repository Markdown checks."""

from __future__ import annotations

from pathlib import Path
import re


def pages(root: Path) -> list[Path]:
    """Return checked documentation pages in deterministic order."""
    found = [root / 'README.md']
    docs = root / 'docs'
    if docs.exists():
        found.extend(
            path for path in docs.rglob('*.md')
            if not path.is_relative_to(docs / 'contributor')
            and not path.is_relative_to(docs / 'data')
        )
    return sorted(found)


def visible_lines(path: Path) -> list[tuple[int, str]]:
    """Return lines outside fenced code blocks."""
    result = []
    fence = None
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        match = re.match(r'^\s*(`{3,}|~{3,})', line)
        if match:
            marker = match.group(1)
            if fence is None:
                fence = marker[0]
            elif marker[0] == fence:
                fence = None
            continue
        if fence is None:
            result.append((number, line))
    return result


def without_inline_code(line: str) -> str:
    """Remove simple inline-code spans before scanning Markdown syntax."""
    return re.sub(r'`[^`]*`', '', line)


def inline_code(line: str) -> list[str]:
    """Return simple inline-code spans from one Markdown line."""
    return re.findall(r'`([^`]+)`', line)


def slug(text: str) -> str:
    """Build the GitHub-style heading slug used by this repository."""
    clean = ''.join(
        char for char in text.lower()
        if char.isalnum() or char in ' -_'
    )
    return clean.replace(' ', '-')


def headings(path: Path) -> set[str]:
    """Return numbered heading slugs for a Markdown file."""
    seen: dict[str, int] = {}
    result = set()
    for _, line in visible_lines(path):
        match = re.match(r'^\s{0,3}#{1,6}\s+(.+?)\s*$', line)
        if not match:
            continue
        text = re.sub(r'\s+#+\s*$', '', match.group(1))
        base = slug(text)
        number = seen.get(base, 0)
        seen[base] = number + 1
        result.add(base if number == 0 else f'{base}-{number}')
    return result


def parse_exports(path: Path) -> tuple[set[str], set[str]]:
    """Read public names and Type.member entries from export-golden.txt."""
    libraries = {
        'dart_monty_core.dart',
        'dart_monty_core_testing.dart',
        'unsafe_callback_file.dart',
    }
    names: set[str] = set()
    members: set[str] = set()
    section = ''
    for line in path.read_text(encoding='utf-8').splitlines():
        heading = re.fullmatch(r'\[([^]]+)\]', line)
        if heading:
            section = heading.group(1)
            continue
        if section in libraries and re.fullmatch(r'[A-Za-z_]\w*', line):
            names.add(line)
        match = re.match(r'\s+([A-Za-z_]\w*)\.([A-Za-z_]\w*)\s*:', line)
        if section.startswith('members:') and match:
            members.add(f'{match.group(1)}.{match.group(2)}')
    return names, members


def display(root: Path, path: Path) -> str:
    """Return a repository-relative display path."""
    return path.relative_to(root).as_posix()
