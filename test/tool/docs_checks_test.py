"""Tests for the repository Markdown checkers."""

from __future__ import annotations

from pathlib import Path
import json
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'tool'))

import check_doc_links
import check_doc_names
import check_doc_snippets
import check_docs_data
import check_docs_index
import check_new_urls
import docs_check_common
import render_docs_data


GOLDEN = '''[dart_monty_core.dart]
Monty
Changed
NewName
NewType
runMontyWorkerIfChild

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

    def test_links_resolve_reference_forms_and_report_missing_labels(self) -> None:
        (self.root / 'docs/target.md').write_text('# Same\n', encoding='utf-8')
        (self.root / 'README.md').write_text(
            '[text][target] [target][] [target]\n\n'
            '[target]: docs/target.md#same\n',
            encoding='utf-8',
        )
        self.assertEqual([], check_doc_links.check(self.root))
        (self.root / 'README.md').write_text(
            '[text][missing]\n\n[bad]: docs/missing.md\n', encoding='utf-8')
        findings = check_doc_links.check(self.root)
        self.assertEqual(2, len(findings))
        self.assertTrue(any('reference label does not exist: missing' in item for item in findings))
        self.assertTrue(any('linked file does not exist: docs/missing.md' in item for item in findings))

    def test_links_resolve_multi_line_reference_definitions(self) -> None:
        (self.root / 'docs/target.md').write_text('# Target\n', encoding='utf-8')
        (self.root / 'README.md').write_text(
            '[missing]:\ndocs/missing.md\n'
            '[existing]:\n  docs/target.md#target\n\n'
            '[bad][missing] [good][existing]\n',
            encoding='utf-8',
        )
        self.assertEqual(
            [
                'README.md:1: linked file does not exist: docs/missing.md',
                'README.md:6: linked file does not exist: docs/missing.md',
            ],
            check_doc_links.check(self.root),
        )

    def test_multi_line_reference_destination_is_not_blank_or_a_definition(self) -> None:
        (self.root / 'docs/target.md').write_text('# Target\n', encoding='utf-8')
        (self.root / 'README.md').write_text(
            '[blank]:\n\n'
            '[first]:\n[second]: docs/target.md#target\n\n'
            '[blank][blank] [first][first] [second]\n',
            encoding='utf-8',
        )
        self.assertEqual(
            [
                'README.md:6: reference label does not exist: blank',
                'README.md:6: reference label does not exist: first',
            ],
            check_doc_links.check(self.root),
        )

    def test_heading_slugs_strip_formatting_and_avoid_existing_candidates(self) -> None:
        (self.root / 'README.md').write_text(
            '# *A* `word` [link](target.md) [again][ref] and name_value!\n'
            '# A\n# A\n# A-1\n',
            encoding='utf-8',
        )
        self.assertEqual(
            {'a-word-link-again-and-name_value', 'a', 'a-1', 'a-1-1'},
            docs_check_common.headings(self.root / 'README.md'),
        )

    def test_heading_slugs_handle_code_emphasis_and_identifier_underscores(self) -> None:
        (self.root / 'README.md').write_text(
            '# __Bold__\n'
            '# _Emphasis_\n'
            '# `_literal_`\n'
            '# `__init__`\n'
            '# foo__bar\n'
            '# snake_case\n'
            "# What's *new*?\n",
            encoding='utf-8',
        )
        self.assertEqual(
            {
                'bold',
                'emphasis',
                '_literal_',
                '__init__',
                'foo__bar',
                'snake_case',
                'whats-new',
            },
            docs_check_common.headings(self.root / 'README.md'),
        )

    def test_heading_collision_skips_an_already_used_suffix(self) -> None:
        (self.root / 'README.md').write_text('# Same\n# Same-1\n# Same\n', encoding='utf-8')
        self.assertEqual(
            {'same', 'same-1', 'same-2'},
            docs_check_common.headings(self.root / 'README.md'),
        )

    def write_docs_index(self, links: str) -> None:
        (self.root / 'docs/README.md').write_text(
            '# Documentation\n\nThis index lists every documentation page.\n\n'
            f'{links}\n',
            encoding='utf-8',
        )

    def write_index_page(self, name: str, text: str = 'Page purpose.') -> None:
        path = self.root / f'docs/{name}.md'
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f'# {name}\n\n{text}\n', encoding='utf-8')

    def test_docs_index_accepts_a_complete_index(self) -> None:
        self.write_index_page('reference/one')
        self.write_index_page('deep-dives/two')
        self.write_docs_index(
            '- [One](reference/one.md): One purpose.\n'
            '- [Two](deep-dives/two.md): Two purpose.'
        )
        self.assertEqual([], check_docs_index.check(self.root))

    def test_docs_index_rejects_an_unlisted_page(self) -> None:
        self.write_index_page('reference/one')
        self.write_docs_index('')
        findings = check_docs_index.check(self.root)
        self.assertTrue(any('page is not linked' in item for item in findings))

    def test_docs_index_rejects_a_doubled_page(self) -> None:
        self.write_index_page('reference/one')
        self.write_docs_index(
            '- [One](reference/one.md): One purpose.\n'
            '- [One again](reference/one.md): Another purpose.'
        )
        findings = check_docs_index.check(self.root)
        self.assertTrue(any('linked more than once' in item for item in findings))

    def test_docs_index_rejects_a_missing_file(self) -> None:
        self.write_docs_index('- [Missing](reference/missing.md): Missing purpose.')
        findings = check_docs_index.check(self.root)
        self.assertTrue(any('linked file does not exist' in item for item in findings))

    def test_docs_index_rejects_two_h1s(self) -> None:
        self.write_index_page('reference/one')
        (self.root / 'docs/reference/one.md').write_text(
            '# One\n\nPurpose.\n\n# Two\n', encoding='utf-8')
        self.write_docs_index('- [One](reference/one.md): One purpose.')
        findings = check_docs_index.check(self.root)
        self.assertTrue(any('exactly one H1' in item for item in findings))

    def test_names_accept_public_name_and_member(self) -> None:
        (self.root / 'README.md').write_text(
            '`Monty` and `Monty.start` and `Unknown`.\n', encoding='utf-8')
        findings = check_doc_names.check(self.root)
        self.assertEqual(['README.md:1: unknown API name: Unknown'], findings)

    def test_names_check_calls_and_generics_but_not_plain_lowercase_words(self) -> None:
        (self.root / 'README.md').write_text(
            '`Monty()` `Monty.start()` `NewType<String>` '
            '`runMontyWorkerIfChild(args)` `runMontyWorkerIfChild(List<String>())` '
            '`close()` `plainword` `Unknown()` `unknownCall()`\n',
            encoding='utf-8',
        )
        self.assertEqual(
            [
                'README.md:1: unknown API name: Unknown()',
                'README.md:1: unknown API name: unknownCall()',
            ],
            check_doc_names.check(self.root),
        )

    def test_names_check_nested_generics(self) -> None:
        (self.root / 'README.md').write_text(
            '`Unknown<List<String>>` and `Unknown<List<String>>()`\n',
            encoding='utf-8',
        )
        self.assertEqual(
            [
                'README.md:1: unknown API name: Unknown<List<String>>',
                'README.md:1: unknown API name: Unknown<List<String>>()',
            ],
            check_doc_names.check(self.root),
        )

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

    def test_urls_stop_at_markdown_closers_and_keep_network_errors(self) -> None:
        urls = check_new_urls.urls_from_text(
            '`https://one.example/path` "https://two.example/path" '
            "'https://three.example/path' https://four.example/path,"
        )
        self.assertEqual(
            [
                'https://one.example/path',
                'https://two.example/path',
                'https://three.example/path',
                'https://four.example/path',
            ],
            urls,
        )
        original = check_new_urls.fetch
        try:
            def unavailable(url: str, method: str = 'HEAD') -> int:
                raise RuntimeError('offline')

            check_new_urls.fetch = unavailable
            self.assertEqual(
                ['https://one.example/path:1: URL unreachable: RuntimeError: offline'],
                check_new_urls.check_urls(urls[:1]),
            )
        finally:
            check_new_urls.fetch = original

    def test_real_url_fetch_preserves_urlopen_error_text(self) -> None:
        with patch.object(
            check_new_urls.urllib.request,
            'urlopen',
            side_effect=OSError('network unavailable'),
        ):
            self.assertEqual(
                ['https://example.test:1: URL unreachable: OSError: network unavailable'],
                check_new_urls.check_urls(['https://example.test']),
            )

    def test_snippets_handle_analyzer_exit_status_and_output(self) -> None:
        accepted_error = subprocess.CompletedProcess(
            [], 1, 'Analyzing snippets...\nwarning - note\n1 issue found.\n', '')
        with patch.object(check_doc_snippets.subprocess, 'run', return_value=accepted_error):
            self.assertEqual([], check_doc_snippets.check(self.root))
        unreadable_error = subprocess.CompletedProcess(
            [], 3, 'Analyzing snippets...\n1 issue found.\n', '')
        with patch.object(check_doc_snippets.subprocess, 'run', return_value=unreadable_error):
            self.assertEqual(
                ['tool/check_doc_snippets.py:1: dart analyze reported errors that this check could not read'],
                check_doc_snippets.check(self.root),
            )
        startup = subprocess.CompletedProcess([], 255, 'startup failed\nmore detail\n', '')
        with patch.object(check_doc_snippets.subprocess, 'run', return_value=startup):
            findings = check_doc_snippets.check(self.root)
        self.assertIn('dart analyze exited with status 255: startup failed\nmore detail', findings[0])
        no_output = subprocess.CompletedProcess([], 0, '', '')
        with patch.object(check_doc_snippets.subprocess, 'run', return_value=no_output):
            self.assertEqual(
                ['tool/check_doc_snippets.py:1: dart analyze produced no analyzer output'],
                check_doc_snippets.check(self.root),
            )


if __name__ == '__main__':
    unittest.main()
