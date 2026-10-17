#!/usr/bin/env python3
"""Check package API names in Markdown inline-code spans."""

from __future__ import annotations

from pathlib import Path
import re
import sys

from docs_check_common import display, inline_code, pages, parse_exports, visible_lines


NAME = re.compile(r'^[A-Z][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?$')
LOWER_CALL = re.compile(r'^[a-z][A-Za-z0-9_]*$')
CALL = re.compile(
    r'^([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?(?:<.*>)?)\(.*\)$'
)


def api_name(span: str) -> str | None:
    """Return a checkable API name from a supported inline-code form."""
    candidate = span
    called = False
    call = CALL.fullmatch(candidate)
    if call:
        candidate = call.group(1)
        called = True
    generic = re.fullmatch(r'(.+)<.*>', candidate)
    if generic:
        candidate = generic.group(1)
    if NAME.fullmatch(candidate):
        return candidate
    if called and LOWER_CALL.fullmatch(candidate):
        return candidate
    return None


def allowed_names(path: Path) -> set[str]:
    """Read one allowed name per line, with hash comments."""
    if not path.exists():
        return set()
    return {
        line.split('#', 1)[0].strip()
        for line in path.read_text(encoding='utf-8').splitlines()
        if line.split('#', 1)[0].strip()
    }


def historical_names(path: Path) -> dict[str, set[str]]:
    """Read page-specific historical names."""
    result: dict[str, set[str]] = {}
    if not path.exists():
        return result
    for line in path.read_text(encoding='utf-8').splitlines():
        line = line.split('#', 1)[0].strip()
        if not line or ':' not in line:
            continue
        page, names = line.split(':', 1)
        result[page.strip()] = {name.strip() for name in names.split(',') if name.strip()}
    return result


def check(root: Path) -> list[str]:
    """Return API-name findings for all checked pages."""
    public, members = parse_exports(root / 'tool/export-golden.txt')
    allowed = allowed_names(root / 'docs/data/names-allow.txt')
    historical = historical_names(root / 'docs/data/historical-names.txt')
    member_names = {name.split('.', 1)[1] for name in members}
    findings = []
    for page in pages(root):
        page_name = display(root, page)
        page_allowed = historical.get(page_name, set())
        for number, line in visible_lines(page):
            for span in inline_code(line):
                name = api_name(span)
                if name is None:
                    continue
                if (
                    LOWER_CALL.fullmatch(name)
                    and name not in public
                    and name not in allowed
                    and name not in page_allowed
                    and (name in member_names or name.islower())
                ):
                    continue
                valid = name in allowed or name in page_allowed
                if '.' in name:
                    type_name, _ = name.split('.', 1)
                    valid = valid or (type_name in public and name in members)
                else:
                    valid = valid or name in public
                if not valid:
                    findings.append(f'{page_name}:{number}: unknown API name: {span}')
    return findings


def main() -> int:
    findings = check(Path.cwd())
    print(*findings, sep='\n')
    return int(bool(findings))


if __name__ == '__main__':
    raise SystemExit(main())
