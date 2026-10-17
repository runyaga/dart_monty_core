"""Tests for the repository Markdown checkers."""

from __future__ import annotations

from pathlib import Path
import json
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool'))

import check_doc_links
import check_doc_names
import check_docs_data
import check_new_urls
import render_docs_data


GOLDEN = '''[dart_monty_core.dart]
Monty
Changed
NewName
NewType

[dart_monty_core_testing.dart]

[unsafe_callback_file.dart]

[members: src/example.dart]
  Monty.start: method() -> void
  NewType.go: method() -> void
'''


class DocsChecksTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / 'docs/data').mkdir(parents=True)
        (self.root / 'tool').mkdir()
        (self.root / 'README.md').write_text('# Readme\n', encoding='utf-8')
        (self.root / 'tool/export-golden.txt').write_text(GOLDEN, encoding='utf-8')
        (self.root / 'docs/data/names-allow.txt').write_text('', encoding='utf-8')
        (self.root / 'docs/data/historical-names.txt').write_text('', encoding='utf-8')

    def tearDown(self) -> None:
        self.temp.cleanup()

    def test_links_resolve_files_and_number_duplicate_headings(self) -> None:
        (self.root / 'docs/target.md').write_text(
            '# Same\n\n## Same\n', encoding='utf-8')
        (self.root / 'README.md').write_text(
            '[first](docs/target.md#same) [second](docs/target.md#same-1)\n',
            encoding='utf-8')
        self.assertEqual([], check_doc_links.check(self.root))
        (self.root / 'README.md').write_text(
            '[file](docs/missing.md) [anchor](docs/target.md#missing)\n',
            encoding='utf-8')
        findings = check_doc_links.check(self.root)
        self.assertEqual(2, len(findings))
        self.assertIn('linked file does not exist', findings[0])
        self.assertIn('anchor does not exist', findings[1])

    def test_names_accept_public_name_and_member(self) -> None:
        (self.root / 'README.md').write_text(
            '`Monty` and `Monty.start` and `Unknown`.\n', encoding='utf-8')
        findings = check_doc_names.check(self.root)
        self.assertEqual(['README.md:1: unknown API name: Unknown'], findings)

    def test_readme_version_accepts_prerelease_and_rejects_mismatch(self) -> None:
        (self.root / 'pubspec.yaml').write_text('version: 0.110.0-dev.2\n', encoding='utf-8')
        (self.root / 'tool/upstream').mkdir()
        (self.root / 'tool/upstream/upstream-pin.json').write_text(
            json.dumps({'version': '1.1.0'}), encoding='utf-8')
        (self.root / 'README.md').write_text(
            '**dart_monty_core 0.110.0 · monty 1.1.0**\n', encoding='utf-8')
        self.assertEqual([], check_docs_data.version_check(self.root))
        (self.root / 'README.md').write_text(
            '**dart_monty_core 0.110.1 · monty 1.1.0**\n', encoding='utf-8')
        self.assertTrue(check_docs_data.version_check(self.root))

    def test_migration_accepts_each_kind(self) -> None:
        rows = [
            'area\told\tnew\tkind\tnote',
            'A\tOld\tNewName\trenamed\t',
            'A\tRemoved\t\tremoved\t',
            'A\tChanged\tChanged\tkept-changed\tchanged',
            'A\tElse\tNewType.go\tmoved\t',
            'A\tHidden\t\tnot-public\t',
        ]
        (self.root / 'docs/data/migration.tsv').write_text('\n'.join(rows), encoding='utf-8')
        self.assertEqual([], check_docs_data.check_table(self.root, 'migration.tsv'))

    def test_render_and_check_detects_drift(self) -> None:
        (self.root / 'docs/data/differences.tsv').write_text(
            'area\tupstream\tcore\tevidence\nAPI\tone\ttwo\t`README.md:1`\n',
            encoding='utf-8')
        self.assertEqual([], render_docs_data.check_or_write(self.root, False))
        self.assertEqual([], render_docs_data.check_or_write(self.root, True))
        (self.root / 'docs/differences.md').write_text('drift\n', encoding='utf-8')
        self.assertTrue(render_docs_data.check_or_write(self.root, True))

    def test_url_extraction_checks_added_lines_only(self) -> None:
        diff = '\n'.join([
            'diff --git a/README.md b/README.md',
            '--- a/README.md',
            '+++ b/README.md',
            '- https://old.example',
            '+ https://good.example/path.',
            '+ [bad](https://bad.example)',
        ])
        urls = check_new_urls.urls_from_diff(diff)
        self.assertEqual(['https://good.example/path', 'https://bad.example'], urls)
        original = check_new_urls.fetch
        try:
            check_new_urls.fetch = lambda url, method='HEAD': 204
            self.assertEqual([], check_new_urls.check_urls(urls))
            check_new_urls.fetch = lambda url, method='HEAD': 404 if 'bad' in url else 204
            self.assertEqual(['https://bad.example:1: URL returned HTTP 404'],
                             check_new_urls.check_urls(urls))
        finally:
            check_new_urls.fetch = original


if __name__ == '__main__':
    unittest.main()
