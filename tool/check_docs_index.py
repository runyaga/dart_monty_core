#!/usr/bin/env python3
"""Check the documentation index."""

from __future__ import annotations

from pathlib import Path
import re
import sys

from docs_check_common import display, visible_lines, without_inline_code


LINK = re.compile(r'!?(?:\[[^]]*\])\(\s*(<[^>]*>|[^\s)]+)')
ATX_HEADING = re.compile(r'^\s{0,3}(#{1,6})\s+\S')
SETEXT_UNDERLINE = re.compile(r'^\s{0,3}(=+|-+)\s*$')
DEFINITION = re.compile(r'^\s{0,3}\[([^]]+)\]:\s*(<[^>]*>|[^\s]+)')
DEFINITION_START = re.compile(r'^\s{0,3}\[([^]]+)\]:\s*$')
DEFINITION_DESTINATION = re.compile(r'^\s*(<[^>]*>|[^\s]+)')
REFERENCE = re.compile(r'!?(?:\[([^]]+)\])\[([^]]*)\]')
SHORTCUT = re.compile(r'(?<!\])!?\[([^]]+)\](?![\[(])')
LIST_OR_QUOTE = re.compile(r'^\s{0,3}(?:[-*+]\s+|\d+[.)]\s+|>)')
THEMATIC_BREAK = re.compile(r'^\s{0,3}(?:(?:[-*_]\s*){3,})$')
INDENTED_CODE = re.compile(r'^(?: {4}|\t)')
TABLE_DIVIDER = re.compile(
    r'^\s*\|?\s*:?-+:?\s*(?:\|\s*:?-+:?\s*)+\|?\s*$'
)


def label(value: str) -> str:
    """Normalize a Markdown reference label."""
    return ' '.join(value.lower().split())


def markdown_headings(lines: list[tuple[int, str]]) -> list[tuple[int, int, int]]:
    """Return (start line, level, end line) triples for Markdown headings."""
    result = []
    for index, (number, line) in enumerate(lines):
        atx = ATX_HEADING.match(line)
        if atx:
            result.append((number, len(atx.group(1)), number))
        if index == 0:
            continue
        previous_number, previous = lines[index - 1]
        setext = SETEXT_UNDERLINE.match(line)
        if (
            setext
            and number == previous_number + 1
            and previous.strip()
            and not ATX_HEADING.match(previous)
            and not INDENTED_CODE.match(previous)
            and not LIST_OR_QUOTE.match(previous)
            and not THEMATIC_BREAK.match(previous)
        ):
            result.append((previous_number, 1 if setext.group(1)[0] == '=' else 2, number))
    return result


def table_lines(lines: list[tuple[int, str]]) -> set[int]:
    """Return line numbers that form simple pipe tables."""
    result = set()
    for index, (number, line) in enumerate(lines):
        if not TABLE_DIVIDER.match(line) or index == 0:
            continue
        previous_number, previous = lines[index - 1]
        if previous_number != number - 1 or '|' not in previous:
            continue
        result.update({previous_number, number})
        following = index + 1
        last_number = number
        while following < len(lines):
            candidate_number, candidate = lines[following]
            if candidate_number != last_number + 1 or not candidate.strip() or '|' not in candidate:
                break
            result.add(candidate_number)
            last_number = candidate_number
            following += 1
    return result


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
    lines = visible_lines(index)
    definitions: dict[str, str] = {}
    definition_lines = set()
    index_number = 0
    while index_number < len(lines):
        number, line = lines[index_number]
        text = without_inline_code(line)
        definition = DEFINITION.match(text)
        if definition:
            definitions[label(definition.group(1))] = definition.group(2)
            definition_lines.add(number)
            index_number += 1
            continue
        start = DEFINITION_START.match(text)
        if start and index_number + 1 < len(lines):
            destination_number, destination_line = lines[index_number + 1]
            destination = (
                DEFINITION_DESTINATION.match(without_inline_code(destination_line))
                if destination_number == number + 1 else None
            )
            next_is_definition = destination and (
                DEFINITION.match(without_inline_code(destination_line))
                or DEFINITION_START.match(without_inline_code(destination_line))
            )
            if destination and not next_is_definition:
                definitions[label(start.group(1))] = destination.group(1)
                definition_lines.update({number, destination_number})
                index_number += 2
                continue
        index_number += 1

    def add(number: int, raw_target: str) -> None:
        """Add one local target to the index result."""
        target = raw_target.strip('<>')
        path_part, _, _ = target.partition('#')
        if path_part and not path_part.startswith(('http:', 'https:', 'mailto:')):
            result.append((number, index.parent / path_part, path_part, path_part.endswith('.md')))

    for number, line in lines:
        text = without_inline_code(line)
        for raw_target in LINK.findall(text):
            add(number, raw_target)
        if number in definition_lines:
            continue
        for text_label, reference_label in REFERENCE.findall(text):
            target = definitions.get(label(reference_label or text_label))
            if target is not None:
                add(number, target)
        for text_label in SHORTCUT.findall(text):
            target = definitions.get(label(text_label))
            if target is not None:
                add(number, target)
    return result


def has_first_paragraph(path: Path) -> bool:
    """Report whether a page has text after its H1."""
    lines = visible_lines(path)
    headings = markdown_headings(lines)
    h1_ends = {end for _, level, end in headings if level == 1}
    heading_lines = {number for start, _, end in headings for number in (start, end)}
    tables = table_lines(lines)
    after_h1 = False
    in_comment = False
    for number, line in lines:
        if not after_h1:
            if number in h1_ends:
                after_h1 = True
            continue
        text, in_comment = without_html_comments(line, in_comment)
        if not text.strip():
            continue
        if (
            number in heading_lines
            or number in tables
            or INDENTED_CODE.match(text)
            or LIST_OR_QUOTE.match(text)
            or THEMATIC_BREAK.match(text)
        ):
            return False
        return True
    return False


def without_html_comments(line: str, in_comment: bool) -> tuple[str, bool]:
    """Remove HTML comments from one line while preserving surrounding text."""
    result = ''
    remaining = line
    while remaining:
        if in_comment:
            end = remaining.find('-->')
            if end < 0:
                return result, True
            remaining = remaining[end + 3:]
            in_comment = False
            continue
        start = remaining.find('<!--')
        if start < 0:
            return result + remaining, False
        result += remaining[:start]
        remaining = remaining[start + 4:]
        in_comment = True
    return result, in_comment


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
        h1_count = sum(level == 1 for _, level, _ in markdown_headings(visible_lines(page)))
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
