#!/usr/bin/env python3
"""Check external URLs added to documentation or all documentation URLs."""

from __future__ import annotations

from pathlib import Path
import re
import subprocess
import sys
from typing import Optional
from urllib.error import HTTPError
from urllib.request import Request, urlopen

from docs_check_common import pages


URL = re.compile(r'''https?://[^\s)>\]"'`]+''')
USER_AGENT = 'dart_monty_core-doc-check'


def urls_from_text(text: str) -> list[str]:
    """Return de-duplicated external URLs from text."""
    found = []
    for match in URL.findall(text):
        value = match.rstrip('.,;:')
        if value not in found:
            found.append(value)
    return found


def urls_from_diff(text: str) -> list[str]:
    """Return URLs from added diff lines only."""
    return urls_from_text('\n'.join(
        line[1:] for line in text.splitlines()
        if line.startswith('+') and not line.startswith('+++')
    ))


def fetch(url: str, method: str = 'HEAD') -> int:
    """Fetch one URL and return its final HTTP status."""
    request = Request(url, method=method, headers={'User-Agent': USER_AGENT})
    try:
        with urlopen(request, timeout=20) as response:
            return response.status
    except HTTPError as error:
        return error.code


def check_urls(urls: list[str]) -> list[str]:
    """Return URL findings, retrying a refused HEAD request with GET."""
    findings = []
    for url in urls:
        try:
            status = fetch(url)
        except Exception as error:
            findings.append(f'{url}:1: URL unreachable: {type(error).__name__}: {error}')
            continue
        if status in {405, 501}:
            try:
                status = fetch(url, 'GET')
            except Exception as error:
                findings.append(f'{url}:1: URL unreachable: {type(error).__name__}: {error}')
                continue
        if not 200 <= status < 300:
            findings.append(f'{url}:1: URL returned HTTP {status}')
    return findings


def main(argv: Optional[list[str]] = None) -> int:
    argv = sys.argv[1:] if argv is None else argv
    root = Path.cwd()
    if argv == ['--all']:
        urls = urls_from_text('\n'.join(page.read_text(encoding='utf-8') for page in pages(root)))
    elif len(argv) == 1:
        try:
            diff = subprocess.run(
                ['git', 'diff', '-U0', f'{argv[0]}...HEAD', '--', 'README.md', 'docs'],
                cwd=root, capture_output=True, text=True, check=True,
            ).stdout
        except (OSError, subprocess.CalledProcessError) as error:
            print(f'tool/check_new_urls.py:1: git diff could not run: {error}')
            return 1
        urls = urls_from_diff(diff)
    else:
        print('tool/check_new_urls.py:1: expected --all or one base ref')
        return 1
    findings = check_urls(urls)
    print(*findings, sep='\n')
    return int(bool(findings))


if __name__ == '__main__':
    raise SystemExit(main())
