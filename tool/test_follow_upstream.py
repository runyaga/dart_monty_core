#!/usr/bin/env python3
"""Offline controls for tool/follow_upstream.py."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name('follow_upstream.py')
SPEC = importlib.util.spec_from_file_location('follow_upstream', SCRIPT)
assert SPEC and SPEC.loader
FOLLOW = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(FOLLOW)


class FollowUpstreamTest(unittest.TestCase):
    def test_failure_ids_parse_parity_and_corpus_fixtures(self) -> None:
        stages = {'upstream-tests': 'pass', 'worker-build': 'pass', 'parity': 'fail', 'corpus': 'fail'}
        output = {
            'parity': 'FAIL current case list-basic (vm)\nFAIL current PRESENT aggregate\nFAIL current row os-path mismatch\n',
            'corpus': ('  REGRESSION crates/monty/test_cases/a.py\n'
                       "  - 'REGRESSION fstring__all.py: not an expected failure'\n"
                       'REGRESSION b.py expected\n'
                       'REGRESSION b.py repeated\n'),
        }
        self.assertEqual(['parity:list-basic', 'parity:os-path mismatch',
                          'corpus:crates/monty/test_cases/a.py', 'corpus:fstring__all.py',
                          'corpus:b.py'],
                         FOLLOW.failure_ids(stages, output))

    def test_failure_ids_use_unparsed_when_needed(self) -> None:
        self.assertEqual(['parity:unparsed', 'corpus:unparsed'], FOLLOW.failure_ids(
            {'upstream-tests': 'skipped', 'worker-build': 'skipped', 'parity': 'fail', 'corpus': 'fail'}, {}))

    def test_judge_persistent_red_is_green(self) -> None:
        verdict = FOLLOW.judge({'parity:case': 'old'}, ['parity:case'], set(), 'next')
        self.assertEqual('green', verdict['kind'])
        self.assertEqual([], verdict['new'])
        self.assertEqual({'parity:case': 'old'}, verdict['baseline'])

    def test_judge_new_failure_is_red(self) -> None:
        verdict = FOLLOW.judge({'parity:case': 'old'}, ['parity:case', 'corpus:x.py'], set(), 'next')
        self.assertEqual('red', verdict['kind'])
        self.assertEqual(['corpus:x.py'], verdict['new'])

    def test_judge_fixed_failure_drops_it_and_its_return_is_new(self) -> None:
        verdict = FOLLOW.judge({'corpus:x.py': 'old'}, [], set(), 'next')
        self.assertEqual('green', verdict['kind'])
        self.assertEqual(['corpus:x.py'], verdict['fixed'])
        self.assertEqual({}, verdict['baseline'])
        returned = FOLLOW.judge(verdict['baseline'], ['corpus:x.py'], set(), 'later')
        self.assertEqual('red', returned['kind'])
        self.assertEqual(['corpus:x.py'], returned['new'])

    def test_first_failure_records_a_baseline(self) -> None:
        verdict = FOLLOW.judge(None, ['parity:case'], set(), 'first')
        self.assertEqual('baseline', verdict['kind'])
        self.assertEqual({'parity:case': 'first'}, verdict['baseline'])

    def test_first_clean_commit_records_an_empty_baseline(self) -> None:
        verdict = FOLLOW.judge(None, [], set(), 'first')
        self.assertEqual('green', verdict['kind'])
        self.assertEqual({}, verdict['baseline'])
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'last_good.json'
            FOLLOW.write_state(path, 'first', 'green', baseline=verdict['baseline'])
            self.assertEqual({}, json.loads(path.read_text())['baseline'])

    def test_stage_failures_are_always_red_and_not_baselined(self) -> None:
        failures = ['upstream-tests', 'worker-build', 'parity:unparsed',
                    'corpus:unparsed', 'gate:timeout', 'gate:no-report']
        verdict = FOLLOW.judge({}, failures, set(), 'next')
        self.assertEqual('red', verdict['kind'])
        self.assertEqual(failures, verdict['new'])
        self.assertEqual({}, verdict['baseline'])

    def test_unparsed_stages_carry_their_known_cases(self) -> None:
        known = {'parity:case': 'old', 'corpus:x.py': 'old'}
        verdict = FOLLOW.judge(known, ['parity:unparsed', 'corpus:unparsed'], set(), 'next')
        self.assertEqual([], verdict['fixed'])
        self.assertEqual(known, verdict['baseline'])

    def test_skipped_stage_carries_baseline_ids(self) -> None:
        verdict = FOLLOW.judge({'parity:case': 'old', 'corpus:x.py': 'old'}, [], {'parity'}, 'next')
        self.assertEqual(['corpus:x.py'], verdict['fixed'])
        self.assertEqual({'parity:case': 'old'}, verdict['baseline'])

    def test_accept_merges_pending_and_applies_its_fixes(self) -> None:
        state = {'baseline': {'worker-build': 'old'},
                 'pending': {'sha': 'new', 'failures': ['corpus:x.py', 'gate:timeout'],
                             'fixed': ['worker-build']}}
        self.assertEqual({'corpus:x.py': 'new'}, FOLLOW.accept_pending(state, 'new'))
        self.assertNotIn('pending', state)

    def test_state_round_trip_keeps_baseline_and_pending(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'last_good.json'
            FOLLOW.write_state(path, 'good', 'green', baseline={'parity:case': 'old'},
                               pending={'sha': 'red', 'failures': ['corpus:x.py'], 'fixed': []})
            FOLLOW.write_state(path, 'later', 'green')
            state = FOLLOW.read_state_or_seed(path, {'commit': 'pin'})
        self.assertEqual('later', state['sha'])
        self.assertEqual({'parity:case': 'old'}, state['baseline'])
        self.assertEqual({'sha': 'red', 'failures': ['corpus:x.py'], 'fixed': []}, state['pending'])

    def test_evidence_line_is_appended(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            state = Path(temporary) / 'missing' / 'last_good.json'
            record = {'sha': 'a', 'subject': 'subject', 'flags': ['PROTO'], 'verdict': 'green',
                      'new': [], 'fixed': []}
            FOLLOW.append_evidence(state, record)
            FOLLOW.append_evidence(state, record)
            lines = state.with_name('evidence.jsonl').read_text().splitlines()
        self.assertEqual(2, len(lines))
        self.assertEqual('a', json.loads(lines[0])['sha'])

    def test_accept_requires_the_pending_sha(self) -> None:
        with self.assertRaisesRegex(ValueError, 'pending'):
            FOLLOW.require_pending_acceptance({}, 'missing')
        with self.assertRaisesRegex(ValueError, 'pending'):
            FOLLOW.require_pending_acceptance(
                {'pending': {'sha': 'pending', 'failures': [], 'fixed': []}}, 'other')

    def test_invalid_accept_ends_the_run_as_an_error(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            core = Path(temp) / 'core'
            (core / 'tool/upstream').mkdir(parents=True)
            (core / 'tool/upstream/upstream-pin.json').write_text(
                json.dumps({'commit': 'a' * 40, 'version': '1.1.0', 'trees': []}))
            out = Path(temp) / 'result.json'
            original = FOLLOW.command
            FOLLOW.command = lambda *args, **kwargs: (_ for _ in ()).throw(AssertionError('gate was run'))
            try:
                status = FOLLOW.run_follow(core, Path(temp) / 'work', None, 1, 1, 'other',
                                           Path(temp) / 'last_good.json', out)
            finally:
                FOLLOW.command = original
            result = json.loads(out.read_text())
        self.assertEqual(1, status)
        self.assertEqual('error', result['status'])
        self.assertIn('does not match the pending SHA', result['error'])

    def test_state_rejects_malformed_baseline_or_pending(self) -> None:
        for data in (
            {'sha': 'good', 'baseline': []},
            {'sha': 'good', 'pending': []},
            {'sha': 'good', 'pending': {'sha': 'red', 'failures': []}},
            {'sha': 'good', 'pending': {'sha': 'red', 'failures': [1], 'fixed': []}},
        ):
            with self.subTest(data=data):
                with self.assertRaises(ValueError):
                    FOLLOW.state_from_data(data, {'commit': 'pin'})

    def test_gate_report_rejects_timeout_missing_invalid_and_wrong_head(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'gate.json'
            self.assertEqual(['gate:timeout', 'gate:no-report'],
                             FOLLOW.read_gate_report(path, 124, 'wanted')['failures'])
            self.assertEqual(['gate:no-report'], FOLLOW.read_gate_report(path, 1, 'wanted')['failures'])
            path.write_text('{bad')
            self.assertEqual(['gate:no-report'], FOLLOW.read_gate_report(path, 1, 'wanted')['failures'])
            path.write_text(json.dumps({'head': 'other', 'stages': {}, 'failures': []}))
            self.assertEqual(['gate:no-report'], FOLLOW.read_gate_report(path, 1, 'wanted')['failures'])

    def test_gate_report_rejects_interrupted_all_skipped_run(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / 'gate.json'
            path.write_text(json.dumps({
                'head': 'wanted',
                'stages': {stage: 'skipped' for stage in FOLLOW.ALL_STAGES},
                'failures': [],
            }))
            report = FOLLOW.read_gate_report(path, 130, 'wanted')
        self.assertIn('gate:no-report', report['failures'])

    def test_unexpected_failure_still_writes_a_result(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            core = Path(temp) / 'core'
            (core / 'tool/upstream').mkdir(parents=True)
            (core / 'tool/upstream/upstream-pin.json').write_text(json.dumps({'commit': 'a' * 40, 'version': '1.1.0', 'trees': []}))
            out = Path(temp) / 'result.json'
            original = FOLLOW._run_follow
            FOLLOW._run_follow = lambda *args: (_ for _ in ()).throw(OSError('boom'))
            try:
                status = FOLLOW.run_follow(core, Path(temp) / 'work', Path(temp) / 'parity', 1, 1, None,
                                           Path(temp) / 'last_good.json', out)
            finally:
                FOLLOW._run_follow = original
            result = json.loads(out.read_text())
        self.assertEqual(1, status)
        self.assertEqual('error', result['status'])
        self.assertIn('boom', result['error'])

    def test_malformed_state_file_still_writes_a_result(self) -> None:
        with tempfile.TemporaryDirectory() as temp:
            core = Path(temp) / 'core'
            (core / 'tool/upstream').mkdir(parents=True)
            (core / 'tool/upstream/upstream-pin.json').write_text(json.dumps({'commit': 'a' * 40, 'version': '1.1.0', 'trees': []}))
            state = Path(temp) / 'last_good.json'
            state.write_text('{not json')
            out = Path(temp) / 'result.json'
            status = FOLLOW.run_follow(core, Path(temp) / 'work', Path(temp) / 'parity', 1, 1, None, state, out)
            result = json.loads(out.read_text())
        self.assertEqual(1, status)
        self.assertEqual('error', result['status'])

    def test_hung_command_is_a_red_timeout(self) -> None:
        result = FOLLOW.command(['sleep', '5'], check=False, timeout=0.01)
        self.assertEqual(124, result.returncode)
        self.assertIn('GATE RED stage=timeout', result.stdout)

    def test_flagged_entries_include_baselines_and_fixes(self) -> None:
        commits = [
            {'sha': 'b' * 40, 'subject': 'baseline', 'flags': [], 'verdict': 'baseline',
             'new': ['corpus:x.py'], 'fixed': [], 'baseline': {'corpus:x.py': 'b' * 40}},
            {'sha': 'c' * 40, 'subject': 'fix', 'flags': [], 'verdict': 'green',
             'new': [], 'fixed': ['corpus:x.py'], 'baseline': {'corpus:x.py': 'b' * 40}},
        ]
        entries = FOLLOW.flagged_entries(commits, 'run')
        self.assertIn('baseline recorded: 1 failures', entries[0]['reason'])
        self.assertIn('introduced by ' + 'b' * 40, entries[1]['reason'])

    def test_accept_records_evidence_and_flagged_entry(self) -> None:
        accepted = 'b' * 40
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = root / 'core'
            (core / 'tool/upstream').mkdir(parents=True)
            (core / 'tool/upstream/upstream-pin.json').write_text(
                json.dumps({'commit': 'a' * 40, 'version': '1.1.0', 'trees': []}))
            state = root / 'last_good.json'
            FOLLOW.write_state(state, 'a' * 40, 'pending', baseline={'parity:old': 'a' * 40}, pending={
                'sha': accepted, 'failures': ['corpus:x.py'], 'fixed': ['parity:old'],
            })
            original_command, original_git = FOLLOW.command, FOLLOW.git
            FOLLOW.command = self._follow_command
            FOLLOW.git = self._follow_git(accepted, [accepted])
            try:
                status = FOLLOW.run_follow(core, root / 'work', None, 1, 1, accepted, state, root / 'result.json')
            finally:
                FOLLOW.command, FOLLOW.git = original_command, original_git
            result = json.loads((root / 'result.json').read_text())
            evidence = json.loads(state.with_name('evidence.jsonl').read_text())
            saved = json.loads(state.read_text())
        self.assertEqual(0, status)
        self.assertEqual('accepted', evidence['verdict'])
        self.assertEqual(['corpus:x.py'], evidence['new'])
        self.assertEqual(['parity:old'], evidence['fixed'])
        self.assertEqual({'corpus:x.py': accepted}, saved['baseline'])
        self.assertTrue(result['flagged'])
        self.assertIn('corpus:x.py', result['flagged'][0]['reason'])
        self.assertIn(accepted, result['flagged'][0]['reason'])

    def test_successful_pending_retry_clears_it_and_advances(self) -> None:
        retry = 'b' * 40
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            core = root / 'core'
            (core / 'tool/upstream').mkdir(parents=True)
            (core / 'tool/upstream/upstream-pin.json').write_text(
                json.dumps({'commit': 'a' * 40, 'version': '1.1.0', 'trees': []}))
            state = root / 'last_good.json'
            FOLLOW.write_state(state, 'a' * 40, 'pending', baseline={}, pending={
                'sha': retry, 'failures': ['corpus:x.py'], 'fixed': [],
            })
            original_command, original_git = FOLLOW.command, FOLLOW.git
            original_flags, original_report = FOLLOW.candidate_flags, FOLLOW.read_gate_report
            FOLLOW.command = self._follow_command
            FOLLOW.git = self._follow_git(retry, [retry])
            FOLLOW.candidate_flags = lambda *args: []
            FOLLOW.read_gate_report = lambda *args: {
                'stages': {stage: 'pass' for stage in FOLLOW.ALL_STAGES}, 'failures': [],
            }
            try:
                status = FOLLOW.run_follow(core, root / 'work', None, 1, 1, None, state, root / 'result.json')
            finally:
                FOLLOW.command, FOLLOW.git = original_command, original_git
                FOLLOW.candidate_flags, FOLLOW.read_gate_report = original_flags, original_report
            result = json.loads((root / 'result.json').read_text())
            saved = json.loads(state.read_text())
        self.assertEqual(0, status)
        self.assertIn(result['status'], ('advanced', 'caught-up'))
        self.assertNotIn('pending', result)
        self.assertNotIn('pending', saved)

    @staticmethod
    def _follow_command(cmd, **kwargs):
        return subprocess.CompletedProcess(cmd, 0, '')

    @staticmethod
    def _follow_git(head, commits):
        def fake_git(_directory, *args, **_kwargs):
            if args[:2] == ('rev-parse', 'origin/main'):
                return head
            if args and args[0] == 'rev-list':
                return '\n'.join(commits) if args[-1].startswith('a' * 40) else ''
            if args[:3] == ('show', '-s', '--format=%s'):
                return 'subject'
            raise AssertionError(f'unexpected git call: {args}')
        return fake_git

    def test_digest_formatting_and_weekly_merge(self) -> None:
        import datetime
        self.assertEqual('2026-W42', FOLLOW.week_label(datetime.date(2026, 10, 16)))
        first = [{'sha': 'b' * 40, 'subject': 'proto', 'reason': 'PROTO', 'url': 'u1', 'evidence': 'run1'}]
        body = FOLLOW.format_digest('2026-W42', first)
        self.assertIn('Reason: PROTO.', body)
        self.assertEqual(body, FOLLOW.format_digest('2026-W42', first, body))

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

    def test_corpus_remains_last(self) -> None:
        self.assertEqual('corpus', FOLLOW.ALL_STAGES[-1])
        self.assertEqual(('upstream-tests', 'worker-build', 'corpus'), FOLLOW.selected_stages(None, None))

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
            after = pin.read_bytes()
        self.assertEqual(before, after)


if __name__ == '__main__':
    unittest.main()
