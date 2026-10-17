#!/usr/bin/env python3
"""Check local Markdown links and anchors."""

from __future__ import annotations

from pathlib import Path
import re
import sys

from docs_check_common import display, headings, pages, visible_lines, without_inline_code


LINK = re.compile(r'!?\[[^]]*\]\(\s*(<[^>]*>|[^\s)]+)')
DEFINITION = re.compile(r'^\s{0,3}\[([^]]+)\]:\s*(<[^>]*>|[^\s]+)')
REFERENCE = re.compile(r'!?\[([^]]+)\]\[([^]]*)\]')
SHORTCUT = re.compile(r'(?<!\])!?\[([^]]+)\](?![\[(])')


def label(value: str) -> str:
    """Normalize a Markdown reference label."""
    return ' '.join(value.lower().split())


def check_target(root: Path, page: Path, number: int, target: str) -> list[str]:
    """Return findings for one local link target."""
    target = target.strip('<>')
    if target.startswith(('http:', 'https:', 'mailto:')):
        return []
    path_part, marker, anchor = target.partition('#')
    destination = page if not path_part else page.parent / path_part
    if not destination.exists():
        return [f'{display(root, page)}:{number}: linked file does not exist: {path_part}']
    if marker and destination.suffix.lower() == '.md' and anchor not in headings(destination):
        return [f'{display(root, page)}:{number}: anchor does not exist: #{anchor}']
    return []


def check(root: Path) -> list[str]:
    """Return link findings for all checked pages."""
    findings = []
    for page in pages(root):
        lines = visible_lines(page)
        definitions: dict[str, str] = {}
        definition_lines = set()
        for number, line in lines:
            match = DEFINITION.match(without_inline_code(line))
            if match:
                definitions[label(match.group(1))] = match.group(2)
                definition_lines.add(number)
                findings.extend(check_target(root, page, number, match.group(2)))
        for number, line in lines:
            text = without_inline_code(line)
            for raw in LINK.findall(text):
                findings.extend(check_target(root, page, number, raw))
            if number in definition_lines:
                continue
            for text_label, reference_label in REFERENCE.findall(text):
                name = label(reference_label or text_label)
                target = definitions.get(name)
                if target is None:
                    findings.append(
                        f'{display(root, page)}:{number}: reference label does not exist: {name}'
                    )
                else:
                    findings.extend(check_target(root, page, number, target))
            for text_label in SHORTCUT.findall(text):
                target = definitions.get(label(text_label))
                if target is not None:
                    findings.extend(check_target(root, page, number, target))
    return findings


def main() -> int:
    root = Path.cwd()
    findings = check(root)
    print(*findings, sep='\n')
    return int(bool(findings))


if __name__ == '__main__':
    raise SystemExit(main())
