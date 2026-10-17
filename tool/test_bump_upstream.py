#!/usr/bin/env python3
"""Offline controls for tool/bump_upstream.py."""

from __future__ import annotations

import importlib.util
import json
import re
import subprocess
import tempfile
import unittest
from importlib.machinery import ModuleSpec
from pathlib import Path
from unittest import mock


SCRIPT = Path(__file__).with_name('bump_upstream.py')
SPEC = importlib.util.spec_from_file_location('bump_upstream', SCRIPT)
assert SPEC and SPEC.loader
BUMP = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(BUMP)


def payload(name: str, version: str) -> dict:
    digest = ('a' if name == 'pydantic-monty' else 'b') * 64
    return {
        'info': {'name': name, 'version': version},
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

    def test_mapping_joins_three_upstream_digits(self) -> None:
        cases = (
            ('1.1.0', False, '0.110.0'),
            ('1.0.2', False, '0.102.0'),
            ('1.1.1', False, '0.111.0'),
            ('1.2.0', True, '0.120.0-dev.1'),
        )
        for version, dev, expected in cases:
            with self.subTest(version=version, dev=dev):
                self.assertEqual(expected, BUMP.mapped_core_version(version, dev=dev))

        for version in ('1.10.0', '1.1.10', '10.0.0'):
            with self.subTest(version=version):
                with self.assertRaisesRegex(ValueError, 'owner decision'):
                    BUMP.mapped_core_version(version)

    def test_mapping_agrees_with_version_pin_check(self) -> None:
        result = subprocess.run(
            ['bash', 'tool/check_version_pin.sh', '--self-test'],
            cwd=SCRIPT.parent.parent,
            check=True,
            capture_output=True,
            text=True,
        )
        controls = []
        for line in result.stdout.splitlines():
            match = re.fullmatch(
                r'PASS: control (\d+\.\d+\.\d+) -> (?:0\.(\d+)\.(x|\d+)|(refused))',
                line,
            )
            if line.startswith('PASS: control ') and match is None:
                self.fail(f'unrecognized version-pin self-test output: {line!r}')
            if match is not None:
                controls.append(match.groups())

        self.assertTrue(controls, 'version-pin self-test printed no controls')
        for upstream, checked_minor, patch_shape, refused in controls:
            with self.subTest(upstream=upstream):
                if refused:
                    with self.assertRaisesRegex(ValueError, 'owner decision'):
                        BUMP.mapped_core_version(upstream)
                else:
                    mapped_minor = BUMP.mapped_core_version(upstream).split('.')[1]
                    self.assertEqual(checked_minor, mapped_minor)
                    self.assertEqual(
                        'x', patch_shape,
                        'version-pin self-test must express the core patch as x',
                    )

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

    def test_pypi_artifact_selection_is_distribution_specific(self) -> None:
        version = '1.1.0'

        def artifact(filename: str, digest: str, kind: str = 'bdist_wheel') -> dict:
            return {'filename': filename, 'packagetype': kind, 'digests': {'sha256': digest * 64}}

        client = 'pydantic-monty-client'
        runtime = 'pydantic-monty-runtime'
        meta = 'pydantic-monty'
        client_filename = 'pydantic_monty_client'
        runtime_filename = 'pydantic_monty_runtime'
        meta_filename = 'pydantic_monty'
        files = [
            artifact(f'{client_filename}-{version}.tar.gz', 'a', 'sdist'),
            artifact(f'{client_filename}-{version}-cp312-cp312-manylinux_2_28_x86_64.whl', 'b'),
            artifact(f'{client_filename}-{version}-cp312-cp312-macosx_11_0_arm64.whl', 'c'),
            artifact(f'{client_filename}-{version}-cp313-cp313-manylinux_2_28_x86_64.whl', 'd'),
            artifact(f'{client_filename}-{version}-cp313-cp313-macosx_11_0_arm64.whl', 'e'),
            artifact(f'{client_filename}-{version}-cp314-cp314-manylinux_2_28_x86_64.whl', 'f'),
            artifact(f'{client_filename}-{version}-cp314-cp314-macosx_11_0_arm64.whl', 'g'),
            artifact(f'{client_filename}-{version}-cp314-cp314t-manylinux_2_28_x86_64.whl', 'h'),
            artifact(f'{client_filename}-{version}-cp314-cp314t-macosx_11_0_arm64.whl', 'i'),
            artifact(f'{client_filename}-{version}-cp314-cp314-manylinux_2_28_aarch64.whl', 'j'),
            artifact(f'{client_filename}-{version}-cp314-cp314-win_amd64.whl', 'k'),
            artifact(f'{client_filename}-{version}-cp314-cp314-musllinux_1_2_x86_64.whl', 'l'),
            artifact(f'{runtime_filename}-{version}.tar.gz', 'm', 'sdist'),
            artifact(f'{runtime_filename}-{version}-py3-none-manylinux_2_28_x86_64.whl', 'n'),
            artifact(f'{runtime_filename}-{version}-py3-none-macosx_11_0_arm64.whl', 'o'),
            artifact(f'{runtime_filename}-{version}-py3-none-any.whl', 'p'),
            artifact(f'{meta_filename}-{version}.tar.gz', 'q', 'sdist'),
            artifact(f'{meta_filename}-{version}-py3-none-any.whl', 'r'),
        ]
        payload = {'info': {'version': version}, 'urls': files}

        self.assertTrue(BUMP.accepted_pypi_file(
            client, artifact(f'{client}-{version}-cp312-cp312-macosx_11_0_arm64.whl', 'z')))
        self.assertCountEqual([digest * 64 for digest in 'abcdefg'],
                              BUMP.selected_hashes(client, payload))
        self.assertCountEqual([digest * 64 for digest in 'mno'],
                              BUMP.selected_hashes(runtime, payload))
        self.assertCountEqual([digest * 64 for digest in 'qr'],
                              BUMP.selected_hashes(meta, payload))

    def test_worker_mirror_module_loads_by_file_path(self) -> None:
        class Loader:
            def create_module(self, spec: ModuleSpec) -> None:
                return None

            def exec_module(self, module: object) -> None:
                setattr(module, 'crates_io_checksum', object())

        spec = ModuleSpec('check_worker_mirror', Loader())
        with mock.patch.object(BUMP.importlib.util, 'spec_from_file_location',
                               return_value=spec) as load:
            mirror = BUMP.load_worker_mirror()

        load.assert_called_once_with('check_worker_mirror', SCRIPT.with_name('check_worker_mirror.py'))
        self.assertTrue(hasattr(mirror, 'crates_io_checksum'))

    def test_pin_worker_lock_pins_only_monty_crates_present_in_lock(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            core = Path(directory)
            lock = core / 'native/worker/Cargo.lock'
            lock.parent.mkdir(parents=True)
            lock.write_text('''\
[[package]]
name = "monty"
version = "1.2.0"

[[package]]
name = "monty-macros"
version = "1.2.0"

[[package]]
name = "unrelated"
version = "1.2.0"
''')
            with mock.patch.object(BUMP, 'run') as run:
                BUMP.pin_worker_lock(core, '1.1.0')

        self.assertEqual([
            mock.call(['cargo', 'update', '-p', 'monty', '--precise', '1.1.0'],
                      cwd=lock.parent),
            mock.call(['cargo', 'update', '-p', 'monty-macros', '--precise', '1.1.0'],
                      cwd=lock.parent),
        ], run.call_args_list)

    def test_body_lists_evidence_and_manual_work(self) -> None:
        body = BUMP.render_body('v1.1.0', 'v1.1.1', 'a' * 40, 'b' * 40, [{
            'sha': 'c' * 40, 'subject': 'add thing', 'flags': ['PROTO'], 'verdict': 'green',
            'new_failures': ['web case'], 'fixed_failures': [],
        }], 'WATCHED x.rs changed')
        self.assertIn('Core version: 0.111.0.', body)
        self.assertIn('`cccccccccccc` add thing. Flags: PROTO. Verdict: green.', body)
        self.assertIn('New failures: web case. Fixed failures: none.', body)
        self.assertIn('- [ ] Port watched files.', body)


if __name__ == '__main__':
    unittest.main()
