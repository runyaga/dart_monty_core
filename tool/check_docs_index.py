#!/usr/bin/env python3
"""Check the documentation index."""

from __future__ import annotations

from pathlib import Path
import re
import sys

from docs_check_common import display, visible_lines


LINK = re.compile(r'!?(?:\[[^]]*\])\(\s*(<[^>]*>|[^\s)]+)')
H1 = re.compile(r'^\s{0,3}#\s+\S')
HEADING = re.compile(r'^\s{0,3}#{1,6}\s+')
PARAGRAPH_BLOCK = re.compile(r'^\s*(?:[-*+]\s+|\d+[.)]\s+|>|(?:[-*_]\s*){3,}$)')


def index_pages(root: Path) -> list[Path]:
    """Return documentation pages that the index lists."""
    docs = root / 'docs'
    return sorted(
        path for path in docs.rglob('*.md')
        if path != docs / 'README.md'
        and not path.is_relative_to(docs / 'contributor')
        and not path.is_relative_to(docs / 'data')
    )


def index_links(root: Path) -> list[tuple[int, Path, str, bool]]:
    """Return local links from the documentation index."""
    index = root / 'docs' / 'README.md'
    result = []
    for number, line in visible_lines(index):
        for raw_target in LINK.findall(line):
            target = raw_target.strip('<>')
            path_part, _, _ = target.partition('#')
            if path_part and not path_part.startswith(('http:', 'https:', 'mailto:')):
                result.append((number, index.parent / path_part, path_part, path_part.endswith('.md')))
    return result


def has_first_paragraph(path: Path) -> bool:
    """Report whether a page has text after its H1."""
    after_h1 = False
    for _, line in visible_lines(path):
        if not after_h1:
            if H1.match(line):
                after_h1 = True
            continue
        if not line.strip():
            continue
        return not HEADING.match(line) and not PARAGRAPH_BLOCK.match(line)
    return False


def check(root: Path) -> list[str]:
    """Return documentation index findings."""
    index = root / 'docs' / 'README.md'
    if not index.exists():
        return ['docs/README.md:1: documentation index does not exist']

    findings = []
    listed: dict[Path, list[int]] = {}
    docs = root / 'docs'
    for number, target, text, is_page in index_links(root):
        if not target.exists():
            findings.append(f'{display(root, index)}:{number}: linked file does not exist: {text}')
            continue
        if not is_page:
            continue
        resolved = target.resolve()
        if resolved.is_relative_to((docs / 'contributor').resolve()) or resolved.is_relative_to(
            (docs / 'data').resolve()
        ):
            findings.append(f'{display(root, index)}:{number}: index links an excluded page: {text}')
            continue
        listed.setdefault(resolved, []).append(number)

    for page in index_pages(root):
        resolved = page.resolve()
        locations = listed.get(resolved, [])
        if not locations:
            findings.append(f'{display(root, page)}:1: page is not linked from docs/README.md')
            continue
        if len(locations) > 1:
            for number in locations[1:]:
                findings.append(f'{display(root, index)}:{number}: page is linked more than once: {page.relative_to(docs).as_posix()}')
        h1_count = sum(bool(H1.match(line)) for _, line in visible_lines(page))
        if h1_count != 1:
            findings.append(f'{display(root, page)}:1: listed page must have exactly one H1')
        if not has_first_paragraph(page):
            findings.append(f'{display(root, page)}:1: listed page has no first paragraph after its H1')
    return findings


def main() -> int:
    root = Path.cwd()
    findings = check(root)
    print(*findings, sep='\n')
    return int(bool(findings))


if __name__ == '__main__':
    raise SystemExit(main())
