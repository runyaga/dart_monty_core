#!/usr/bin/env python3
"""Check local Markdown links and anchors."""

from __future__ import annotations

from pathlib import Path
import re
import sys

from docs_check_common import display, headings, pages, visible_lines, without_inline_code


LINK = re.compile(r'!?\[[^]]*\]\(\s*(<[^>]*>|[^\s)]+)')


def check(root: Path) -> list[str]:
    """Return link findings for all checked pages."""
    findings = []
    for page in pages(root):
        for number, line in visible_lines(page):
            for raw in LINK.findall(without_inline_code(line)):
                target = raw.strip('<>')
                if target.startswith(('http:', 'https:', 'mailto:')):
                    continue
                path_part, marker, anchor = target.partition('#')
                destination = page if not path_part else page.parent / path_part
                if not destination.exists():
                    findings.append(
                        f'{display(root, page)}:{number}: linked file does not exist: {path_part}'
                    )
                    continue
                if marker and destination.suffix.lower() == '.md':
                    if anchor not in headings(destination):
                        findings.append(
                            f'{display(root, page)}:{number}: anchor does not exist: #{anchor}'
                        )
    return findings


def main() -> int:
    root = Path.cwd()
    findings = check(root)
    print(*findings, sep='\n')
    return int(bool(findings))


if __name__ == '__main__':
    raise SystemExit(main())
