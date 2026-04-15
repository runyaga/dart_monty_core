#!/usr/bin/env python3
"""gen_fixture_corpus.py — regenerate _fixture_corpus.dart from upstream .py files.

Usage:
    python3 tool/gen_fixture_corpus.py \\
        --fixture-dir ~/dev/monty-upstream/crates/monty/test_cases \\
        --out test/integration/_fixture_corpus.dart

    # Or point at a local symlink:
    python3 tool/gen_fixture_corpus.py \\
        --fixture-dir test/fixtures/test_cases \\
        --out test/integration/_fixture_corpus.dart

IMPORTANT — xfail=wasm markers:
    After regenerating, any '# xfail=wasm' markers that were added to the
    previous corpus are LOST. Run 'bash tool/test_wasm.sh --skip-build' to
    find new WASM failures and re-add '# xfail=wasm\\n' prefixes as needed.
    See tool/test_wasm.sh and the maintenance guide for details.

The output format is identical to tool/generate_fixture_corpus.dart so either
tool can be used. Run 'dart format test/integration/_fixture_corpus.dart' after
generation to canonicalise line wrapping.
"""
import argparse
import json
import pathlib
import sys


def main() -> None:
    ap = argparse.ArgumentParser(
        description='Regenerate _fixture_corpus.dart from .py fixture files.',
    )
    ap.add_argument(
        '--fixture-dir',
        required=True,
        metavar='DIR',
        help='Directory containing .py fixture files (flat, no subdirs).',
    )
    ap.add_argument(
        '--out',
        required=True,
        metavar='FILE',
        help='Output path for the generated Dart file.',
    )
    args = ap.parse_args()

    fixture_dir = pathlib.Path(args.fixture_dir).expanduser().resolve()
    out_path = pathlib.Path(args.out).expanduser()

    if not fixture_dir.is_dir():
        print(f'ERROR: fixture-dir not found: {fixture_dir}', file=sys.stderr)
        sys.exit(1)

    fixtures = sorted(fixture_dir.glob('*.py'))
    if not fixtures:
        print(f'ERROR: no .py files found in {fixture_dir}', file=sys.stderr)
        sys.exit(1)

    lines = [
        '// GENERATED — do not edit.',
        '// Run: dart tool/generate_fixture_corpus.dart',
        '// ignore_for_file: lines_longer_than_80_chars, prefer_single_quotes,'
        ' avoid_escaping_inner_quotes, eol_at_end_of_file',
        '',
        '/// Python fixture corpus embedded at compile time.',
        '///',
        '/// Used by WASM/JS tests where `dart:io` is unavailable.',
        '/// Keys are fixture file names; values are source text.',
        'const Map<String, String> fixtureCorpus = {',
    ]

    for f in fixtures:
        name = f.name
        content = f.read_text(encoding='utf-8')
        # json.dumps produces a valid Dart string literal: double-quoted with
        # all control characters and backslashes properly escaped.
        # Escape $ so Dart doesn't attempt string interpolation.
        dart_literal = json.dumps(content).replace('$', r'\$')
        lines.append(f"  '{name}': {dart_literal},")

    lines.append('};')
    lines.append('')

    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text('\n'.join(lines), encoding='utf-8')

    print(f'Generated {out_path} with {len(fixtures)} fixtures.')
    print()
    print('Next steps:')
    print('  dart format test/integration/_fixture_corpus.dart')
    print('  dart test test/integration/oracle_ffi_test.dart -p vm --run-skipped --tags=ffi')
    print('  bash tool/test_wasm.sh --skip-build  # check for new xfail=wasm')


if __name__ == '__main__':
    main()
