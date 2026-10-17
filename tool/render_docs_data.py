#!/usr/bin/env python3
"""Render optional documentation TSV tables into Markdown pages."""

from __future__ import annotations

from pathlib import Path
import sys
from typing import Optional


PAGES = {
    'migration.tsv': ('migration.md', 'Migration from 0.23', 'This page maps the 0.23 API to this package.'),
    'not-supported.tsv': ('not-supported.md', 'Not supported', 'This page lists unsupported upstream behaviour.'),
    'differences.tsv': ('differences.md', 'Differences from upstream', 'This page lists documented differences from upstream.'),
    'known-untested.tsv': ('known-untested.md', 'Known untested', 'This page lists documented coverage gaps.'),
}


def cell(value: str) -> str:
    """Escape a TSV value for a Markdown table cell."""
    return value.replace('\\', '\\\\').replace('|', '\\|').replace('\n', '<br>')


def table(header: list[str], rows: list[list[str]]) -> list[str]:
    """Render one Markdown table."""
    return [
        '| ' + ' | '.join(cell(value) for value in header) + ' |',
        '| ' + ' | '.join('---' for _ in header) + ' |',
        *['| ' + ' | '.join(cell(value) for value in row) + ' |' for row in rows],
    ]


def render(filename: str, text: str) -> str:
    """Render one TSV text into its corresponding Markdown page."""
    output, title, purpose = PAGES[filename]
    rows = [line.split('\t') for line in text.splitlines()]
    if not rows:
        return ''
    header, data = rows[0], rows[1:]
    data = [(row + [''] * len(header))[:len(header)] for row in data]
    lines = [f'# {title}', '', purpose, '']
    if filename == 'migration.tsv':
        areas: dict[str, list[list[str]]] = {}
        for row in data:
            areas.setdefault(row[0], []).append(row)
        for area, area_rows in areas.items():
            lines += [f'## {area}', '']
            lines += table(['old', 'new', 'note'], [[row[1], row[2], row[4]] for row in area_rows])
            lines.append('')
    else:
        lines += table(header, data)
        lines.append('')
    return '\n'.join(lines)


def check_or_write(root: Path, check: bool) -> list[str]:
    """Render existing TSV files or report drift."""
    findings = []
    for filename, (output, _, _) in PAGES.items():
        source = root / 'docs/data' / filename
        if not source.exists():
            continue
        destination = root / 'docs' / output
        expected = render(filename, source.read_text(encoding='utf-8'))
        if check:
            if not destination.exists() or destination.read_text(encoding='utf-8') != expected:
                findings.append(f'docs/{output}:1: generated page differs from its TSV')
        else:
            destination.write_text(expected, encoding='utf-8')
    return findings


def main(argv: Optional[list[str]] = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    if set(argv) - {'--check'}:
        print('tool/render_docs_data.py:1: expected --check or no arguments')
        return 1
    findings = check_or_write(Path.cwd(), '--check' in argv)
    print(*findings, sep='\n')
    return int(bool(findings))


if __name__ == '__main__':
    raise SystemExit(main())
