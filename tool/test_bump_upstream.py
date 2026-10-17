#!/usr/bin/env python3
"""Offline controls for tool/bump_upstream.py."""

from __future__ import annotations

import importlib.util
import json
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name('bump_upstream.py')
SPEC = importlib.util.spec_from_file_location('bump_upstream', SCRIPT)
assert SPEC and SPEC.loader
BUMP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUMP)


def payload(name: str, version: str) -> dict:
    digest = ('a' if name == 'pydantic-monty' else 'b') * 64
    return {
        'info': {'version': version},
        'urls': [
            {'filename': f'{name}-{version}.tar.gz', 'packagetype': 'sdist',
             'digests': {'sha256': digest}},
            {'filename': f'{name}-{version}-py3-none-any.whl', 'packagetype': 'bdist_wheel',
             'digests': {'sha256': digest[::-1]}},
            {'filename': f'{name}-{version}-cp312-abi3-manylinux_2_28_x86_64.whl',
             'packagetype': 'bdist_wheel', 'digests': {'sha256': 'c' * 64}},
            {'filename': f'{name}-{version}-cp311-abi3-manylinux_2_28_x86_64.whl',
             'packagetype': 'bdist_wheel', 'digests': {'sha256': 'd' * 64}},
        ],
    }


class BumpUpstreamTest(unittest.TestCase):
    def test_tags_keep_peels_and_ignore_beta(self) -> None:
        refs = '\n'.join([
            'a' * 40 + '\trefs/tags/v1.0.0',
            'b' * 40 + '\trefs/tags/v1.0.1',
            'c' * 40 + '\trefs/tags/v1.0.1^{}',
            'd' * 40 + '\trefs/tags/v1.1.0-beta.1',
            'e' * 40 + '\trefs/tags/v1.2.0',
        ])
        self.assertEqual(['v1.0.0', 'v1.0.1', 'v1.2.0'], BUMP.stable_tags(refs))
        self.assertEqual('v1.2.0', BUMP.newer_tag(refs, 'v1.0.0'))

    def test_mapping_carries_upstream_patch(self) -> None:
        self.assertEqual('0.110.1', BUMP.mapped_core_version('1.1.1'))
        self.assertEqual('0.120.0-dev.1', BUMP.mapped_core_version('1.2.0', dev=True))
        with self.assertRaisesRegex(ValueError, 'owner decision'):
            BUMP.mapped_core_version('1.10.0')

    def test_pin_rewrite_keeps_order_and_is_idempotent(self) -> None:
        source = json.dumps({
            'upstream': 'u', 'version': '1.1.0', 'tag': 'v1.1.0', 'commit': 'a' * 40,
            'trees': [{'path': 'a', 'git_tree': 'b' * 40, 'files': 1}],
            'python': {'lock': 'lock', 'distributions': {'pydantic-monty': '1.1.0'}},
        }, indent=2) + '\n'
        rewritten = BUMP.rewrite_pin_text(source, version='1.1.1', commit='c' * 40,
                                          trees={'a': ('d' * 40, 2)})
        parsed = json.loads(rewritten)
        self.assertEqual(['upstream', 'version', 'tag', 'commit', 'trees', 'python'], list(parsed))
        self.assertEqual('v1.1.1', parsed['tag'])
        self.assertEqual(2, parsed['trees'][0]['files'])
        self.assertEqual(rewritten, BUMP.rewrite_pin_text(rewritten, version='1.1.1',
                                                           commit='c' * 40,
                                                           trees={'a': ('d' * 40, 2)}))

    def test_lock_rendering_selects_fixture_artifacts_and_keeps_typing(self) -> None:
        old = '# header stays\n' + BUMP.render_requirement('pydantic-monty', '1.1.0', ['e' * 64]) + \
            BUMP.render_requirement('pydantic-monty-client', '1.1.0', ['e' * 64]) + \
            BUMP.render_requirement('pydantic-monty-runtime', '1.1.0', ['e' * 64]) + \
            BUMP.render_requirement('typing-extensions', '4.0.0', ['f' * 64])
        rendered = BUMP.render_lock(old, '1.1.1', {name: payload(name, '1.1.1')
                                                    for name in BUMP.DIST_NAMES})
        self.assertTrue(rendered.startswith('# header stays\n'))
        self.assertIn('pydantic-monty-client==1.1.1', rendered)
        self.assertIn('typing-extensions==4.0.0', rendered)
        self.assertNotIn('d' * 64, rendered)

    def test_body_lists_evidence_and_manual_work(self) -> None:
        body = BUMP.render_body('v1.1.0', 'v1.1.1', 'a' * 40, 'b' * 40, [{
            'sha': 'c' * 40, 'subject': 'add thing', 'flags': ['PROTO'], 'verdict': 'green',
            'new_failures': ['web case'], 'fixed_failures': [],
        }], 'WATCHED x.rs changed')
        self.assertIn('Core version: 0.110.1.', body)
        self.assertIn('`cccccccccccc` add thing. Flags: PROTO. Verdict: green.', body)
        self.assertIn('New failures: web case. Fixed failures: none.', body)
        self.assertIn('- [ ] Port watched files.', body)


if __name__ == '__main__':
    unittest.main()
