#!/usr/bin/env python3
"""Analyze Dart snippets found in checked Markdown pages."""

from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
import sys

from docs_check_common import display, pages


FENCE = re.compile(r'^\s*(`{3,}|~{3,})\s*([^\s]+(?:\s+[^\s]+)?)\s*$')


def snippets(root: Path) -> tuple[list[tuple[Path, int, str]], list[str]]:
    """Extract dart snippets and validate skip comments."""
    found: list[tuple[Path, int, str]] = []
    findings = []
    for page in pages(root):
        lines = page.read_text(encoding='utf-8').splitlines()
        index = 0
        while index < len(lines):
            match = FENCE.match(lines[index])
            if not match or match.group(2) not in {'dart', 'dart skip'}:
                index += 1
                continue
            marker, info = match.group(1)[0], match.group(2)
            start = index + 1
            index += 1
            body = []
            while index < len(lines) and not re.match(rf'^\s*{re.escape(marker)}{{3,}}\s*$', lines[index]):
                body.append(lines[index])
                index += 1
            if index == len(lines):
                findings.append(f'{display(root, page)}:{start}: unterminated dart block')
                break
            if info == 'dart skip':
                if start < 2 or not re.match(r'^\s*<!--.+-->\s*$', lines[start - 2]):
                    findings.append(f'{display(root, page)}:{start}: dart skip needs a reason comment above it')
            else:
                found.append((page, start + 1, '\n'.join(body) + '\n'))
            index += 1
    return found, findings


def wrapped(source: str) -> str:
    """Wrap a statement-only snippet in a valid Dart async function."""
    if re.search(r'^\s*import\s|\bvoid\s+main\b|\bFuture<void>\s+main\b', source, re.M):
        return source
    return (
        "import 'package:dart_monty_core/dart_monty_core.dart';\n"
        "import 'dart:typed_data';\n\n"
        'Future<void> _snippet(Monty monty, MontySession session, MontyValue value, '
        'MontySnapshot snapshot) async {\n'
        + ''.join(f'  {line}\n' if line else '\n' for line in source.splitlines())
        + '}\n'
    )


def check(root: Path) -> list[str]:
    """Write snippets, run the Dart analyzer, and return findings."""
    source, findings = snippets(root)
    directory = root / '.dart_tool/doc_snippets'
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True)
    locations = {}
    for number, (page, line, text) in enumerate(source, 1):
        filename = directory / f'snippet_{number}.dart'
        filename.write_text(wrapped(text), encoding='utf-8')
        locations[filename.name] = (display(root, page), line)
    try:
        run = subprocess.run(
            ['dart', 'analyze', '.dart_tool/doc_snippets'], cwd=root,
            capture_output=True, text=True, check=False,
        )
    except OSError as error:
        return findings + [f'tool/check_doc_snippets.py:1: dart analyze could not run: {error}']
    output = run.stdout + run.stderr
    output_lines = output.splitlines()
    errors = [line for line in output_lines if ' error - ' in line]
    for error in errors:
        match = re.search(r'(snippet_\d+\.dart)', error)
        page, line = locations.get(match.group(1) if match else '', ('tool/check_doc_snippets.py', 1))
        message = error.split(' error - ', 1)[1] if ' error - ' in error else error
        findings.append(f'{page}:{line}: Dart snippet error: {message}')
    if run.returncode not in {0, 1, 2, 3}:
        excerpt = '\n'.join(output_lines[:3]) or '(no output)'
        findings.append(
            'tool/check_doc_snippets.py:1: '
            f'dart analyze exited with status {run.returncode}: {excerpt}'
        )
    if run.returncode == 3 and not errors:
        findings.append('tool/check_doc_snippets.py:1: dart analyze reported errors that this check could not read')
    has_analysis = re.search(r'^Analyzing\b', output, re.M)
    has_summary = re.search(r'\b(?:No issues found!|\d+ issues? found\.)', output)
    if not has_analysis and not has_summary:
        findings.append('tool/check_doc_snippets.py:1: dart analyze produced no analyzer output')
    return findings


def main() -> int:
    findings = check(Path.cwd())
    print(*findings, sep='\n')
    return int(bool(findings))


if __name__ == '__main__':
    raise SystemExit(main())
