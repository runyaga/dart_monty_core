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
    fence: tuple[str, int] | None = None
    for number, line in enumerate(path.read_text(encoding='utf-8').splitlines(), 1):
        if fence is not None:
            match = re.match(r'^( {0,3})([`~]+)([ \t]*)$', line)
            if (
                match
                and match.group(2)[0] == fence[0]
                and len(match.group(2)) >= fence[1]
            ):
                fence = None
            continue
        match = re.match(r'^( {0,3})(`{3,}|~{3,})(.*)$', line)
        if match:
            marker = match.group(2)
            # CommonMark does not permit a backtick fence's info string to
            # contain backticks. A tilde fence has no equivalent restriction.
            if marker[0] == '`' and '`' in match.group(3):
                result.append((number, line))
                continue
            fence = (marker[0], len(marker))
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
    pieces = re.split(r'(`[^`]*`)', text)
    for index, piece in enumerate(pieces):
        if index % 2:
            # Keep code content literal: Markdown delimiters in a code span
            # are ordinary characters, even when they are underscores.
            pieces[index] = piece[1:-1]
            continue
        piece = re.sub(r'!?\[([^]]*)\]\([^)]*\)', r'\1', piece)
        piece = re.sub(r'!?\[([^]]*)\]\[[^]]*\]', r'\1', piece)
        # Strip only paired emphasis delimiters. The word boundaries leave
        # identifier-style underscores such as snake_case and foo__bar alone.
        delimiter = r'(\*\*|__|\*|_)'
        previous = None
        while piece != previous:
            previous = piece
            piece = re.sub(
                rf'(?<!\w){delimiter}(?=\S)(.*?\S)\1(?!\w)',
                r'\2',
                piece,
            )
        pieces[index] = piece
    text = ''.join(pieces)
    clean = ''.join(char for char in text.lower() if char.isalnum() or char in ' -_')
    return clean.replace(' ', '-')


def headings(path: Path) -> set[str]:
    """Return numbered heading slugs for a Markdown file."""
    result = set()
    for _, line in visible_lines(path):
        match = re.match(r'^\s{0,3}#{1,6}\s+(.+?)\s*$', line)
        if not match:
            continue
        text = re.sub(r'\s+#+\s*$', '', match.group(1))
        base = slug(text)
        number = 0
        candidate = base
        while candidate in result:
            number += 1
            candidate = f'{base}-{number}'
        result.add(candidate)
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
