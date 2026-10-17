#!/usr/bin/env python3
"""Offline controls for tool/follow_upstream.py."""

from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name('follow_upstream.py')
SPEC = importlib.util.spec_from_file_location('follow_upstream', SCRIPT)
assert SPEC and SPEC.loader
FOLLOW = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FOLLOW)


class FollowUpstreamTest(unittest.TestCase):
    def test_red_stops_without_advance(self) -> None:
        commits = [
            {'sha': 'green', 'flags': [], 'gate': 'green'},
            {'sha': 'red', 'flags': [], 'gate': 'red'},
            {'sha': 'later', 'flags': [], 'gate': 'green'},
        ]
        self.assertEqual('green', FOLLOW.last_good_after('old', commits))

    def test_flagged_commit_advances_and_red_stops(self) -> None:
        commits = [
            {'sha': 'a', 'flags': ['PROTO'], 'gate': 'green'},
            {'sha': 'b', 'flags': ['TESTCASES'], 'gate': 'exempt'},
            {'sha': 'c', 'flags': [], 'gate': 'red'},
            {'sha': 'd', 'flags': [], 'gate': 'green'},
        ]
        self.assertEqual('b', FOLLOW.last_good_after('old', commits))
        self.assertEqual('red', FOLLOW.result_status(False, True, 'red', False))

    def test_accept_takes_only_the_oldest_pending_commit(self) -> None:
        pending = ['flagged', 'next']
        self.assertEqual(('flagged', ['next']), FOLLOW.select_commits(pending, 'flagged'))
        with self.assertRaisesRegex(ValueError, 'oldest pending'):
            FOLLOW.select_commits(pending, 'next')
        with self.assertRaisesRegex(ValueError, 'oldest pending'):
            FOLLOW.select_commits(pending, 'not-a-commit')

    def test_unexpected_failure_still_writes_a_result(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            core = Path(temp) / 'core'
            (core / 'tool/upstream').mkdir(parents=True)
            (core / 'tool/upstream/upstream-pin.json').write_text(json.dumps(
                {'commit': 'a' * 40, 'version': '1.1.0', 'trees': []}))
            out = Path(temp) / 'result.json'
            original = FOLLOW._run_follow
            FOLLOW._run_follow = lambda *args: (_ for _ in ()).throw(OSError('boom'))
            try:
                status = FOLLOW.run_follow(core, Path(temp) / 'work', Path(temp) / 'parity', 1, 1,
                                           None, Path(temp) / 'last_good.json', out)
            finally:
                FOLLOW._run_follow = original
            result = json.loads(out.read_text())
        self.assertEqual(1, status)
        self.assertEqual('error', result['status'])
        self.assertEqual('a' * 40, result['last_good'])
        self.assertIn('boom', result['error'])

    def test_malformed_state_file_still_writes_a_result(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            core = Path(temp) / 'core'
            (core / 'tool/upstream').mkdir(parents=True)
            (core / 'tool/upstream/upstream-pin.json').write_text(json.dumps(
                {'commit': 'a' * 40, 'version': '1.1.0', 'trees': []}))
            state = Path(temp) / 'last_good.json'
            state.write_text('{not json')
            out = Path(temp) / 'result.json'
            status = FOLLOW.run_follow(core, Path(temp) / 'work', Path(temp) / 'parity', 1, 1, None, state, out)
            result = json.loads(out.read_text())
        self.assertEqual(1, status)
        self.assertEqual('error', result['status'])

    def test_verdicts_separate_flagged_from_red(self) -> None:
        self.assertEqual('green', FOLLOW.gate_verdict(True, 'all', ['MIRROR']))
        self.assertEqual('red', FOLLOW.gate_verdict(False, 'upstream-tests', ['MIRROR']))
        self.assertEqual('red', FOLLOW.gate_verdict(False, 'corpus', []))
        self.assertEqual('exempt', FOLLOW.gate_verdict(False, 'corpus', ['TESTCASES']))
        self.assertEqual('red', FOLLOW.gate_verdict(False, 'worker-build', ['TESTCASES']))
        self.assertIsNone(FOLLOW.stop_reason(True, 'all', ['MIRROR']))
        self.assertIsNone(FOLLOW.stop_reason(False, 'corpus', ['TESTCASES']))
        self.assertEqual('red', FOLLOW.stop_reason(False, 'parity', ['TESTCASES']))

    def test_flagged_entries_skip_red_and_plain_green(self) -> None:
        commits = [
            {'sha': 'a' * 40, 'subject': 'plain', 'flags': [], 'gate': 'green'},
            {'sha': 'b' * 40, 'subject': 'proto', 'flags': ['PROTO', 'VERSION'], 'gate': 'green'},
            {'sha': 'c' * 40, 'subject': 'cases', 'flags': ['TESTCASES'], 'gate': 'exempt'},
            {'sha': 'd' * 40, 'subject': 'broken', 'flags': ['PROTO'], 'gate': 'red'},
        ]
        entries = FOLLOW.flagged_entries(commits, 'https://example.test/run/1')
        self.assertEqual(['b' * 40, 'c' * 40], [e['sha'] for e in entries])
        self.assertEqual('PROTO, VERSION', entries[0]['reason'])
        self.assertIn('corpus differs', entries[1]['reason'])
        self.assertEqual('https://github.com/pydantic/monty/commit/' + 'b' * 40, entries[0]['url'])

    def test_digest_formatting_and_weekly_merge(self) -> None:
        import datetime
        self.assertEqual('2026-W42', FOLLOW.week_label(datetime.date(2026, 10, 16)))
        self.assertEqual('2027-W01', FOLLOW.week_label(datetime.date(2027, 1, 4)))
        first = [{'sha': 'b' * 40, 'subject': 'proto', 'reason': 'PROTO', 'url': 'u1', 'evidence': 'run1'}]
        body = FOLLOW.format_digest('2026-W42', first)
        self.assertEqual('<!-- upstream-follow-digest 2026-W42 -->', body.splitlines()[0])
        self.assertIn('- [`' + 'b' * 12 + '`](u1) proto. Reason: PROTO. Evidence: run1', body)
        second = [{'sha': 'b' * 40, 'subject': 'proto', 'reason': 'PROTO', 'url': 'u1', 'evidence': 'run2'},
                  {'sha': 'c' * 40, 'subject': 'cases', 'reason': 'TESTCASES', 'url': 'u2', 'evidence': ''}]
        merged = FOLLOW.format_digest('2026-W42', second, body)
        self.assertEqual(2, sum(line.startswith('- [') for line in merged.splitlines()))
        self.assertIn('Evidence: run2', merged)
        self.assertNotIn('Evidence: run1', merged)
        self.assertEqual(FOLLOW.format_digest('2026-W42', second, merged), merged)

    def test_a_hung_command_is_a_red_timeout(self) -> None:
        result = FOLLOW.command(['sleep', '5'], check=False, timeout=0.2)
        self.assertEqual(124, result.returncode)
        self.assertIn('GATE RED stage=timeout', result.stdout)

    def test_version_rewrite_changes_exact_requirements_only(self) -> None:
        source = 'monty = "=1.1.0"\nother = "=1.1.0"\n'
        self.assertEqual('monty = "=1.2.0"\nother = "=1.1.0"\n',
                         FOLLOW.rewrite_monty_versions(source, '1.1.0', '1.2.0'))

    def test_patch_table_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            upstream = Path(temporary)
            (upstream / 'crates/monty').mkdir(parents=True)
            table = FOLLOW.patch_table(upstream)
            once = FOLLOW.with_patch_table('[package]\nname = "x"\n', table)
            self.assertEqual(once, FOLLOW.with_patch_table(once, table))
            self.assertIn('monty = { path = ', once)

    def test_missing_state_seeds_from_pin(self) -> None:
        state = FOLLOW.state_from_data(None, {'commit': 'pin'})
        self.assertEqual('pin', state['sha'])
        self.assertEqual('pin', state['via'])

    def test_flag_derivation(self) -> None:
        self.assertEqual(['VERSION', 'MIRROR', 'PROTO', 'TESTCASES'],
                         FOLLOW.derive_flags('1.1.0', '1.2.0', True, True, True))

    def test_pin_file_is_never_written(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pin = root / 'upstream-pin.json'
            pin.write_text(json.dumps({'commit': 'pin'}))
            before = pin.read_bytes()
            FOLLOW.write_state(root / 'last_good.json', 'new', 'green')
            self.assertEqual(before, pin.read_bytes())


if __name__ == '__main__':
    unittest.main()
