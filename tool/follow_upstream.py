#!/usr/bin/env python3
"""Follow pydantic/monty main without moving dart_monty_core's upstream pin."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from datetime import date, datetime, timezone
from pathlib import Path
from typing import Any


MONTY_CRATES = (
    'monty', 'monty-proto', 'monty-types', 'monty-alloc', 'monty-fs',
    'monty-macros', 'monty-type-checking', 'monty-typeshed',
)
# The corpus runs last: a corpus failure on a test_cases change is digested, so no
# stage that must stay red may come after it.
ALL_STAGES = ('upstream-tests', 'worker-build', 'parity', 'corpus')
NEVER_BASELINE_FAILURES = frozenset((
    'upstream-tests', 'worker-build', 'parity:unparsed', 'corpus:unparsed',
    'gate:timeout', 'gate:no-report',
))


def command(cmd: list[str], cwd: Path | None = None,
            env: dict[str, str] | None = None, check: bool = True,
            timeout: float | None = None) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    try:
        return subprocess.run(cmd, cwd=cwd, env=merged, text=True, check=check, timeout=timeout,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    except subprocess.TimeoutExpired as exc:
        output = exc.stdout.decode(errors='replace') if isinstance(exc.stdout, bytes) else (exc.stdout or '')
        return subprocess.CompletedProcess(cmd, 124, output + '\nGATE RED stage=timeout\n')


def git(directory: Path, *args: str, check: bool = True) -> str:
    return command(['git', '-C', str(directory), *args], check=check).stdout.strip()


def load_pin(core: Path) -> dict[str, Any]:
    return json.loads((core / 'tool/upstream/upstream-pin.json').read_text())


def read_state_or_seed(state_file: Path | None, pin: dict[str, Any]) -> dict[str, Any]:
    """Read persistent state, or start at the immutable upstream pin."""
    data = json.loads(state_file.read_text()) if state_file is not None and state_file.is_file() else None
    return state_from_data(data, pin)


def state_from_data(data: dict[str, Any] | None, pin: dict[str, Any]) -> dict[str, Any]:
    """Validate state data, or provide the immutable pin as its seed."""
    if data is None:
        return {'sha': str(pin['commit']), 'advanced': '', 'via': 'pin'}
    if not isinstance(data.get('sha'), str) or not data['sha']:
        raise ValueError('last_good state has no sha')
    state: dict[str, Any] = {
        'sha': data['sha'],
        'advanced': str(data.get('advanced', '')),
        'via': str(data.get('via', '')),
    }
    baseline = data.get('baseline')
    if 'baseline' in data:
        if not isinstance(baseline, dict) or not all(isinstance(key, str) and isinstance(value, str)
                                                     for key, value in baseline.items()):
            raise ValueError('last_good state has a malformed baseline')
        state['baseline'] = baseline.copy()
    pending = data.get('pending')
    if 'pending' in data:
        if (not isinstance(pending, dict) or not isinstance(pending.get('sha'), str) or not pending['sha']
                or not isinstance(pending.get('failures'), list)
                or not isinstance(pending.get('fixed'), list)
                or not all(isinstance(item, str) for item in pending['failures'])
                or not all(isinstance(item, str) for item in pending['fixed'])):
            raise ValueError('last_good state has a malformed pending record')
        state['pending'] = {
            'sha': pending['sha'],
            'failures': pending['failures'].copy(),
            'fixed': pending['fixed'].copy(),
        }
    return state


_UNSET = object()


def write_state(state_file: Path | None, sha: str, via: str, *,
                baseline: dict[str, str] | None | object = _UNSET,
                pending: dict[str, Any] | None | object = _UNSET) -> None:
    if state_file is None:
        return
    old = state_from_data(json.loads(state_file.read_text()), {'commit': sha}) \
        if state_file.is_file() else {}
    if baseline is _UNSET:
        baseline = old.get('baseline')
    if pending is _UNSET:
        pending = old.get('pending')
    data: dict[str, Any] = {
        'sha': sha,
        'advanced': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'via': via,
    }
    if baseline is not None:
        data['baseline'] = baseline
    if pending is not None:
        data['pending'] = pending
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_text(json.dumps(data, indent=2) + '\n')


def selected_stages(value: str | None, parity: Path | None) -> tuple[str, ...]:
    if value is None:
        return tuple(name for name in ALL_STAGES if parity is not None or name != 'parity')
    selected = tuple(item for item in value.split(',') if item)
    bad = set(selected) - set(ALL_STAGES)
    if bad:
        raise ValueError(f'unknown stages: {", ".join(sorted(bad))}')
    if 'parity' in selected and parity is None:
        raise ValueError('parity selected without --parity')
    return selected


def workspace_version(upstream: Path) -> str:
    text = (upstream / 'Cargo.toml').read_text()
    match = re.search(r'(?ms)^\[workspace\.package\]\s*$.*?^version\s*=\s*"([^"]+)"', text)
    if not match:
        raise ValueError(f'{upstream}/Cargo.toml has no [workspace.package] version')
    return match.group(1)


def rewrite_monty_versions(text: str, pinned: str, candidate: str) -> str:
    """Replace only exact monty version requirements in a worker manifest."""
    pattern = re.compile(
        rf'(?m)^(\s*monty(?:-[\w-]+)?\s*=\s*(?:\{{\s*version\s*=\s*)?)"={re.escape(pinned)}"')
    return pattern.sub(rf'\1"={candidate}"', text)


def patch_table(upstream: Path) -> str:
    lines = ['[patch.crates-io]']
    for name in MONTY_CRATES:
        crate = upstream / 'crates' / name
        if crate.is_dir():
            lines.append(f'{name} = {{ path = {json.dumps(str(crate))} }}')
    return '\n'.join(lines) + '\n'


def with_patch_table(text: str, table: str) -> str:
    """Replace the crates.io patch table, leaving every other TOML table intact."""
    without = re.sub(r'(?ms)^\[patch\.crates-io\]\n.*?(?=^\[|\Z)', '', text)
    return without.rstrip() + '\n\n' + table


def prepare_worker(core: Path, upstream: Path) -> str:
    """Seed the worker from an upstream checkout. This never touches the pin."""
    command(['git', '-C', str(core), 'checkout', '--', 'native/worker/Cargo.toml',
             'native/worker/Cargo.lock'])
    pin = load_pin(core)
    version = workspace_version(upstream)
    manifest = core / 'native/worker/Cargo.toml'
    changed = rewrite_monty_versions(manifest.read_text(), str(pin['version']), version)
    manifest.write_text(with_patch_table(changed, patch_table(upstream)))
    shutil.copyfile(upstream / 'Cargo.lock', core / 'native/worker/Cargo.lock')
    print(f'UPSTREAM VERSION {version}')
    print('WORKER TREE patched from upstream lock and local crate paths')
    return version


def cargo_artifacts(output: str) -> tuple[Path, Path]:
    exe: list[Path] = []
    libraries: list[Path] = []
    for line in output.splitlines():
        try:
            message = json.loads(line)
        except json.JSONDecodeError:
            continue
        if message.get('reason') != 'compiler-artifact' or message.get('target', {}).get('name') != 'dart_monty_worker':
            continue
        if message.get('executable'):
            exe.append(Path(message['executable']))
        if 'cdylib' in message['target'].get('crate_types', []):
            libraries.extend(Path(item) for item in message.get('filenames', [])
                             if item.endswith(('.dylib', '.so', '.dll')))
    if len(exe) != 1 or len(libraries) != 1:
        raise ValueError('worker build did not report exactly one executable and one cdylib')
    return exe[0], libraries[0]


def worker_destinations(core: Path) -> tuple[Path, Path]:
    out = command(['bash', 'tool/build_worker.sh', '--print'], cwd=core).stdout.splitlines()
    if len(out) != 2:
        raise ValueError('tool/build_worker.sh --print did not produce two destinations')
    return core / out[0], core / out[1]


def copy_worker(core: Path, output: str) -> None:
    built_exe, built_lib = cargo_artifacts(output)
    exe, library = worker_destinations(core)
    exe.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(built_exe, exe)
    shutil.copyfile(built_lib, library)
    exe.chmod(exe.stat().st_mode | 0o111)


def prepare_wasm(core: Path, upstream: Path) -> None:
    """Patch core's worker crate to the upstream checkout and add the worker crate to the
    reseeded lock, so `cargo build --locked` in tool/build_worker_wasm.sh resolves."""
    print(prepare_worker(core, upstream))
    command(['cargo', 'update', '--workspace'], cwd=core / 'native/worker')


def failure_ids(stages: dict[str, str], output: dict[str, str]) -> list[str]:
    """Extract stable failure identifiers from captured stage output."""
    failures: list[str] = []
    for stage in ('upstream-tests', 'worker-build'):
        if stages.get(stage) == 'fail':
            failures.append(stage)
    if stages.get('parity') == 'fail':
        found = []
        for line in output.get('parity', '').splitlines():
            match = re.match(r'^FAIL current case (.+?) \(', line)
            if match is None:
                match = re.match(r'^FAIL current row (.+?)(?: \(.*|:| \.\.\.|$)', line)
            if match is not None and match.group(1) != 'PRESENT':
                found.append(f'parity:{match.group(1)}')
        failures.extend(dict.fromkeys(found) or ['parity:unparsed'])
    if stages.get('corpus') == 'fail':
        found = [f'corpus:{match.group(1)}' for line in output.get('corpus', '').splitlines()
                 if (match := re.search(r'REGRESSION\s+(\S+\.py)', line))]
        failures.extend(dict.fromkeys(found) or ['corpus:unparsed'])
    return failures


def read_gate_report(path: Path, returncode: int, expected_head: str,
                     selected: tuple[str, ...] = ALL_STAGES) -> dict[str, Any]:
    """Read a gate's self-report, turning an unreliable run into a red failure."""
    def failed(*failures: str) -> dict[str, Any]:
        return {
            'head': expected_head,
            'stages': {**{stage: 'skipped' for stage in ALL_STAGES}, 'gate': 'fail'},
            'failures': list(dict.fromkeys(failures)),
        }

    try:
        report = json.loads(path.read_text())
    except (OSError, UnicodeError, json.JSONDecodeError):
        return failed(*(('gate:timeout',) if returncode == 124 else ()), 'gate:no-report')
    if (not isinstance(report, dict) or report.get('head') != expected_head
            or not isinstance(report.get('stages'), dict)
            or not isinstance(report.get('failures'), list)
            or any(not isinstance(item, str) for item in report['failures'])
            or any(report['stages'].get(stage) not in ('pass', 'fail', 'skipped')
                   for stage in ALL_STAGES)):
        return failed('gate:no-report')
    stages = report['stages']
    selected_failures = any(stages[stage] == 'fail' for stage in selected)
    skipped_without_worker_failure = any(
        stages[stage] == 'skipped'
        and (stage not in ('parity', 'corpus') or stages['worker-build'] != 'fail')
        for stage in selected
    )
    if (returncode not in (0, 1)
            or returncode != (1 if selected_failures else 0)
            or skipped_without_worker_failure):
        report['failures'] = list(dict.fromkeys([*report['failures'], 'gate:no-report']))
    return report


def gate(core: Path, upstream: Path, parity: Path | None, stages: tuple[str, ...],
         target_dir: Path | None, report_skips: bool = False,
         json_out: Path | None = None) -> int:
    head = git(upstream, 'rev-parse', 'HEAD')
    print(f'UPSTREAM HEAD {head}')
    root_target = target_dir or Path(tempfile.mkdtemp(prefix='follow-upstream-target-'))
    status = {name: 'skipped' for name in ALL_STAGES}
    output = {name: '' for name in ALL_STAGES}
    try:
        stage_order = tuple(name for name in ALL_STAGES if parity is not None or name != 'parity')
        for stage in stage_order:
            if stage not in stages:
                if report_skips:
                    print(f'GATE SKIP stage={stage}')
                continue
            if stage in ('parity', 'corpus') and status['worker-build'] != 'pass':
                print(f'GATE SKIP stage={stage}')
                continue
            print(f'GATE RUN stage={stage}')
            try:
                if stage == 'upstream-tests':
                    result = command(['cargo', 'test', '--locked', '-p', 'monty-fs', '-p', 'monty-alloc',
                                      '-p', 'monty-types', '-p', 'monty-proto',
                                      '-p', 'monty-type-checking', '--features', 'monty-proto/worker'],
                                     cwd=upstream,
                                     env={'CARGO_TARGET_DIR': str(root_target / 'upstream-tests')})
                    output[stage] += result.stdout
                    print(result.stdout, end='')
                elif stage == 'worker-build':
                    prepare_worker(core, upstream)
                    result = command(['cargo', 'build', '--release', '--bin', 'dart_monty_worker', '--lib',
                                      '--message-format=json-render-diagnostics'], cwd=core / 'native/worker',
                                     env={'CARGO_TARGET_DIR': str(root_target / 'worker-build')})
                    output[stage] += result.stdout
                    print(result.stdout, end='')
                    copy_worker(core, result.stdout)
                elif stage == 'corpus':
                    result = command(['bash', 'tool/test_corpus_worker.sh', 'native'], cwd=core)
                    output[stage] += result.stdout
                    print(result.stdout, end='')
                else:
                    assert parity is not None
                    with tempfile.TemporaryDirectory(prefix='follow-upstream-parity-') as temp:
                        out = Path(temp)
                        result = command(['python3', '-I', str(parity / 'tool/parity/run.py'), 'vm',
                                          '--core', str(core), '--out', str(out)])
                        output[stage] += result.stdout
                        print(result.stdout, end='')
                        result = command(['python3', '-I', str(parity / 'tool/parity/score.py'), str(out),
                                          '--backends', 'vm', '--json', str(out / 'score.json'), '--markdown', str(out / 'score.md'),
                                          '--assert-current', str(parity / 'tool/parity/baseline-current.json')])
                        output[stage] += result.stdout
                        print(result.stdout, end='')
            except (OSError, ValueError, subprocess.CalledProcessError) as exc:
                if isinstance(exc, subprocess.CalledProcessError) and exc.stdout:
                    output[stage] += exc.stdout
                    print(exc.stdout, end='')
                status[stage] = 'fail'
            else:
                status[stage] = 'pass'
        failures = failure_ids(status, output)
        if failures:
            first = next(stage for stage in stage_order if status[stage] == 'fail')
            print(f'GATE RED stage={first}')
            return 1
        if report_skips and set(stages) != set(stage_order):
            print('GATE INCOMPLETE')
            return 2
        print('GATE GREEN')
        return 0
    finally:
        if json_out is not None:
            json_out.parent.mkdir(parents=True, exist_ok=True)
            json_out.write_text(json.dumps({
                'head': head,
                'stages': status,
                'failures': failure_ids(status, output),
            }, indent=2) + '\n')
        if target_dir is None:
            shutil.rmtree(root_target, ignore_errors=True)


def derive_flags(pin_version: str, candidate_version: str, mirror_red: bool,
                 proto_changed: bool, testcases_changed: bool) -> list[str]:
    flags = []
    if candidate_version != pin_version:
        flags.append('VERSION')
    if mirror_red:
        flags.append('MIRROR')
    if proto_changed:
        flags.append('PROTO')
    if testcases_changed:
        flags.append('TESTCASES')
    return flags


def mirrored_paths(core: Path) -> list[str]:
    mirror = json.loads((core / 'tool/upstream/worker-mirror.json').read_text())
    return [item['upstream'] for item in mirror['verbatim'] + mirror['watched']]


def testcases_drift(core: Path, upstream: Path) -> bool:
    """True when the upstream test_cases tree at HEAD differs from the pinned tree,
    which is the corpus core's own tests read."""
    pin = load_pin(core)
    wanted = next(item['git_tree'] for item in pin['trees'] if item['path'] == 'crates/monty/test_cases')
    return git(upstream, 'rev-parse', 'HEAD:crates/monty/test_cases') != wanted


def candidate_flags(core: Path, upstream: Path, base: str | None = None) -> list[str]:
    """Flags for the commit at upstream HEAD, measured against `base` (the previous
    last_good, or the pin when none is given), so one change raises one flag once."""
    pin = load_pin(core)
    base = base or str(pin['commit'])
    sha = git(upstream, 'rev-parse', 'HEAD')
    changed = git(upstream, 'diff', '--name-only', base, sha).splitlines()
    mirror_changed = any(path in changed for path in mirrored_paths(core))
    proto_changed = any(path.endswith('.proto') and path.startswith('crates/monty-proto/')
                        or path.endswith('PROTOCOL_VERSION') for path in changed)
    tests = 'crates/monty/test_cases'
    tests_changed = git(upstream, 'rev-parse', f'{base}:{tests}') != git(upstream, 'rev-parse', f'{sha}:{tests}')
    base_text = git(upstream, 'show', f'{base}:Cargo.toml')
    base_version = re.search(r'(?ms)^\[workspace\.package\]\s*$.*?^version\s*=\s*"([^"]+)"', base_text)
    flags = derive_flags(base_version.group(1) if base_version else str(pin['version']),
                         workspace_version(upstream), mirror_changed, proto_changed, tests_changed)
    for flag in flags:
        print(f'FLAG {flag}')
    if not flags:
        print('FLAGS none')
    return flags


def failure_stage(failure: str) -> str:
    return failure.split(':', 1)[0]


def judge(known: dict[str, str] | None, failures: list[str], skipped_stages: set[str],
          sha: str) -> dict[str, Any]:
    """Judge a gate result against its recorded baseline."""
    failures = list(dict.fromkeys(failures))
    skipped_stages = set(skipped_stages)
    if 'parity:unparsed' in failures:
        skipped_stages.add('parity')
    if 'corpus:unparsed' in failures:
        skipped_stages.add('corpus')
    if known is None:
        baseline = {failure: sha for failure in failures if failure not in NEVER_BASELINE_FAILURES}
        if not failures:
            return {'kind': 'green', 'new': [], 'fixed': [], 'baseline': baseline}
        kind = 'red' if any(failure in NEVER_BASELINE_FAILURES for failure in failures) else 'baseline'
        return {'kind': kind, 'new': failures, 'fixed': [], 'baseline': baseline}
    new = [failure for failure in failures
           if failure in NEVER_BASELINE_FAILURES or failure not in known]
    fixed = [failure for failure in known
             if failure not in failures and failure_stage(failure) not in skipped_stages]
    baseline = {failure: introduced for failure, introduced in known.items()
                if failure not in fixed and failure not in NEVER_BASELINE_FAILURES}
    return {'kind': 'red' if new else 'green', 'new': new, 'fixed': fixed, 'baseline': baseline}


def require_pending_acceptance(state: dict[str, Any], sha: str) -> None:
    """Ensure an acceptance names the exact commit awaiting review."""
    pending = state.get('pending')
    if not isinstance(pending, dict) or pending.get('sha') != sha:
        raise ValueError(f'accepted SHA {sha} does not match the pending SHA')


def accept_pending(state: dict[str, Any], sha: str) -> dict[str, str]:
    """Record a reviewed pending failure set in the baseline."""
    require_pending_acceptance(state, sha)
    pending = state['pending']
    baseline = dict(state.get('baseline', {}))
    for failure in pending['fixed']:
        baseline.pop(failure, None)
    baseline.update({failure: sha for failure in pending['failures']
                     if failure not in NEVER_BASELINE_FAILURES})
    state['baseline'] = baseline
    state.pop('pending', None)
    return baseline


def append_evidence(state_file: Path | None, record: dict[str, Any]) -> None:
    if state_file is None:
        return
    evidence = state_file.with_name('evidence.jsonl')
    evidence.parent.mkdir(parents=True, exist_ok=True)
    item = {key: record[key] for key in ('sha', 'subject', 'flags', 'verdict', 'new', 'fixed')}
    item['date'] = datetime.now(timezone.utc).date().isoformat()
    with evidence.open('a') as handle:
        handle.write(json.dumps(item, separators=(',', ':')) + '\n')


def flagged_entries(commits: list[dict[str, Any]], run_url: str = '') -> list[dict[str, Any]]:
    """The commits that advance with flags, recorded failures, or fixes."""
    entries = []
    for commit in commits:
        if commit['verdict'] == 'red' or not (commit['flags'] or commit['verdict'] in ('accepted', 'baseline')
                                               or commit['fixed']):
            continue
        reasons = list(commit['flags'])
        baseline = commit.get('baseline', {})
        if commit['verdict'] == 'baseline':
            details = ', '.join(f'{failure} (introduced by {baseline[failure]})'
                                for failure in commit['new'])
            reasons.append(f'baseline recorded: {len(commit["new"])} failures: {details}')
        if commit['verdict'] == 'accepted':
            details = ', '.join(f'{failure} (introduced by {baseline.get(failure, "unknown")})'
                                for failure in commit['new'])
            reasons.append(f'accepted failures: {details}')
        if commit['fixed']:
            details = ', '.join(f'{failure} (introduced by {baseline.get(failure, "unknown")})'
                                for failure in commit['fixed'])
            reasons.append(f'fixed: {details}')
        entries.append({'sha': commit['sha'], 'subject': commit['subject'], 'reason': ', '.join(reasons),
                        'url': f"https://github.com/pydantic/monty/commit/{commit['sha']}",
                        'evidence': run_url})
    return entries


def run_url() -> str:
    server, repo, run = (os.environ.get(k, '') for k in ('GITHUB_SERVER_URL', 'GITHUB_REPOSITORY', 'GITHUB_RUN_ID'))
    return f'{server}/{repo}/actions/runs/{run}' if server and repo and run else ''


def week_label(day: date) -> str:
    year, week, _ = day.isocalendar()
    return f'{year}-W{week:02d}'


def digest_marker(week: str) -> str:
    return f'<!-- upstream-follow-digest {week} -->'


def format_digest(week: str, entries: list[dict[str, Any]], existing: str | None = None) -> str:
    """The week's digest comment. Entries already in `existing` (by sha) are kept once."""
    seen: dict[str, str] = {}
    if existing:
        for line in existing.splitlines():
            found = re.match(r'- \[`([0-9a-f]{12})`\]', line)
            if found:
                seen[found.group(1)] = line
    for entry in entries:
        short = str(entry['sha'])[:12]
        text = f"- [`{short}`]({entry['url']}) {entry['subject']}. Reason: {entry['reason']}."
        if entry.get('evidence'):
            text += f" Evidence: {entry['evidence']}"
        seen[short] = text
    lines = [digest_marker(week), f'Flagged upstream commits, week {week}', '', *seen.values()]
    return '\n'.join(lines) + '\n'


def result_status(at_head: bool, advanced: bool, stopped: str | None, budget: bool) -> str:
    if stopped is not None:
        return stopped
    if budget:
        return 'budget'
    if at_head:
        return 'advanced' if advanced else 'caught-up'
    return 'advanced' if advanced else 'budget'


def last_good_after(start: str, commits: list[dict[str, Any]]) -> str:
    """Return the last eligible commit, stopping at the first red gate."""
    last_good = start
    for commit in commits:
        if commit['gate'] == 'red':
            break
        last_good = str(commit['sha'])
    return last_good


def summary(result: dict[str, Any]) -> str:
    lines = [f"## Upstream follow: {result['status']}", '',
             f"- Start: `{result['start']}`", f"- Last good: `{result['last_good']}`",
             f"- Head: `{result['head']}`", f"- Behind: {result['behind']}"]
    for item in result['commits']:
        flags = ', '.join(item['flags']) or 'none'
        lines.append(f"- `{item['sha']}` {item['subject']} | {item['verdict']} {item['stage']} | flags: {flags}")
    return '\n'.join(lines) + '\n'


def write_result(path: Path, result: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=2) + '\n')
    step_summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if step_summary:
        Path(step_summary).open('a').write(summary(result))


def _run_follow(core: Path, workdir: Path, parity: Path | None, max_commits: int,
               time_budget_min: float, accept: str | None, state_file: Path | None,
               out: Path, records: list[dict[str, Any]]) -> int:
    pin = load_pin(core)
    state = read_state_or_seed(state_file, pin)
    start = state['sha']
    if accept is not None:
        try:
            require_pending_acceptance(state, accept)
        except ValueError as exc:
            result = {'pin': pin['commit'], 'start': start, 'last_good': start, 'head': '', 'behind': 0,
                      'commits': [], 'status': 'error', 'error': str(exc)}
            write_result(out, result)
            return 1
    repo = workdir / 'monty'
    try:
        workdir.mkdir(parents=True, exist_ok=True)
        if repo.is_dir():
            command(['git', '-C', str(repo), 'fetch', '--filter=blob:none', 'origin', 'main'])
        else:
            command(['git', 'clone', '--filter=blob:none', 'https://github.com/pydantic/monty.git', str(repo)])
            command(['git', '-C', str(repo), 'fetch', '--filter=blob:none', 'origin', 'main'])
        head = git(repo, 'rev-parse', 'origin/main')
        ancestor = command(['git', '-C', str(repo), 'merge-base', '--is-ancestor', start, 'origin/main'], check=False)
        if ancestor.returncode:
            raise ValueError(f'last_good {start} is not an ancestor of origin/main')
        commits = git(repo, 'rev-list', '--first-parent', '--reverse', f'{start}..origin/main').splitlines()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        result = {'pin': pin['commit'], 'start': start, 'last_good': start, 'head': '', 'behind': 0,
                  'commits': [], 'status': 'error', 'error': str(exc)}
        write_result(out, result)
        return 1

    pending = state.get('pending')
    pending_red = pending is not None and accept is None
    if accept is not None:
        accepted = accept
        try:
            accepted_index = commits.index(accepted)
        except ValueError:
            result = {'pin': pin['commit'], 'start': start, 'last_good': start, 'head': head,
                      'behind': len(commits), 'commits': [], 'status': 'error',
                      'error': f'accepted SHA {accepted} is not pending on origin/main'}
            write_result(out, result)
            return 1
        accepted_pending = {
            'failures': pending['failures'].copy(),
            'fixed': pending['fixed'].copy(),
        }
        introductions = dict(state.get('baseline', {}))
        accept_pending(state, accepted)
        introductions.update({failure: accepted for failure in accepted_pending['failures']})
        record = {
            'sha': accepted,
            'subject': git(repo, 'show', '-s', '--format=%s', accepted),
            'flags': [],
            'failures': accepted_pending['failures'],
            'new': accepted_pending['failures'],
            'fixed': accepted_pending['fixed'],
            'verdict': 'accepted',
            'baseline': introductions,
            'stage': 'accepted',
            'seconds': 0.0,
        }
        records.append(record)
        append_evidence(state_file, record)
        state['sha'] = accepted
        write_state(state_file, accepted, 'accepted', baseline=state.get('baseline'), pending=None)
        commits = commits[accepted_index + 1:]
        pending = None

    current = state['sha']
    advanced = current != start
    stopped: str | None = 'red' if pending_red else None
    deadline = time.monotonic() + time_budget_min * 60
    attempted = 0
    for sha in commits:
        if attempted >= max_commits or time.monotonic() >= deadline:
            break
        attempted += 1
        subject = git(repo, 'show', '-s', '--format=%s', sha)
        began = time.monotonic()
        command(['git', '-C', str(repo), 'checkout', '--detach', '--quiet', sha])
        flags = candidate_flags(core, repo, current)
        target = workdir / 'targets'
        gate_report = workdir / 'gate.json'
        gate_report.unlink(missing_ok=True)
        gate_cmd = [sys.executable, '-I', str(Path(__file__).resolve()), 'gate', '--core', str(core),
                    '--upstream', str(repo), '--target-dir', str(target), '--json-out', str(gate_report)]
        if parity is not None:
            gate_cmd.extend(['--parity', str(parity)])
        outcome = command(gate_cmd, check=False, timeout=max(60.0, deadline - time.monotonic()))
        print(outcome.stdout, end='')
        report = read_gate_report(gate_report, outcome.returncode, sha,
                                  selected_stages(None, parity))
        stage_status = report['stages']
        known = state.get('baseline')
        verdict = judge(known, report['failures'],
                        {stage for stage, value in stage_status.items() if value == 'skipped'}, sha)
        failed = [stage for stage, value in stage_status.items() if value == 'fail']
        introductions = dict(known or {})
        introductions.update(verdict['baseline'] or {})
        record = {'sha': sha, 'subject': subject, 'flags': flags, 'failures': report['failures'],
                  'new': verdict['new'], 'fixed': verdict['fixed'], 'verdict': verdict['kind'],
                  'baseline': introductions, 'stage': failed[0] if failed else 'all',
                  'seconds': round(time.monotonic() - began, 3)}
        records.append(record)
        append_evidence(state_file, record)
        if verdict['kind'] == 'red':
            state['pending'] = {'sha': sha, 'failures': verdict['new'], 'fixed': verdict['fixed']}
            write_state(state_file, current, 'pending', baseline=state.get('baseline'), pending=state['pending'])
            stopped = 'red'
            break
        if pending is not None and pending['sha'] == sha:
            state.pop('pending', None)
            pending = None
            stopped = None
        state['baseline'] = verdict['baseline']
        current = sha
        advanced = True
        write_state(state_file, current, 'baseline' if verdict['kind'] == 'baseline' else 'green',
                    baseline=state.get('baseline'), pending=None)

    remaining = git(repo, 'rev-list', '--first-parent', f'{current}..origin/main').splitlines()
    budget = stopped is None and bool(remaining)
    status = result_status(not remaining, advanced, stopped, budget)
    result = {'pin': pin['commit'], 'start': start, 'last_good': current, 'head': head,
              'behind': len(remaining), 'commits': records, 'status': status,
              'flagged': flagged_entries(records, run_url()),
              'new': records[-1]['new'] if records else (pending or {}).get('failures', [])}
    if state.get('pending') is not None:
        result['pending'] = state['pending']
    write_result(out, result)
    return 0 if status in ('caught-up', 'advanced', 'budget') else 1


def run_follow(core: Path, workdir: Path, parity: Path | None, max_commits: int,
               time_budget_min: float, accept: str | None, state_file: Path | None,
               out: Path) -> int:
    """Runs the loop; any unexpected failure still writes result.json, so the
    workflow keeps the greens already recorded and reports the error."""
    pin_commit = start = ''
    records: list[dict[str, Any]] = []
    try:
        pin = load_pin(core)
        pin_commit = str(pin['commit'])
        start = read_state_or_seed(state_file, pin)['sha']
        return _run_follow(core, workdir, parity, max_commits, time_budget_min, accept, state_file, out, records)
    except Exception as exc:  # noqa: BLE001 - the report must be written whatever failed
        try:
            last_good = read_state_or_seed(state_file, load_pin(core))['sha']
        except Exception:  # noqa: BLE001 - a malformed state file is part of what is reported
            last_good = start
        result = {'pin': pin_commit, 'start': start, 'last_good': last_good, 'head': '', 'behind': 0,
                  'commits': records, 'status': 'error', 'error': f'{type(exc).__name__}: {exc}',
                  'flagged': flagged_entries(records, run_url())}
        write_result(out, result)
        return 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    gate_parser = sub.add_parser('gate')
    gate_parser.add_argument('--core', type=Path, required=True)
    gate_parser.add_argument('--upstream', type=Path, required=True)
    gate_parser.add_argument('--parity', type=Path)
    gate_parser.add_argument('--stages')
    gate_parser.add_argument('--target-dir', type=Path)
    gate_parser.add_argument('--json-out', type=Path)
    flags_parser = sub.add_parser('flags')
    flags_parser.add_argument('--core', type=Path, required=True)
    flags_parser.add_argument('--upstream', type=Path, required=True)
    flags_parser.add_argument('--base')
    digest_parser = sub.add_parser('digest')
    digest_parser.add_argument('--result', type=Path, required=True)
    digest_parser.add_argument('--existing', type=Path)
    digest_parser.add_argument('--week')
    digest_parser.add_argument('--out', type=Path, required=True)
    wasm_parser = sub.add_parser('prepare-wasm')
    wasm_parser.add_argument('--core', type=Path, required=True)
    wasm_parser.add_argument('--upstream', type=Path, required=True)
    run_parser = sub.add_parser('run')
    run_parser.add_argument('--core', type=Path, required=True)
    run_parser.add_argument('--workdir', type=Path, required=True)
    run_parser.add_argument('--parity', type=Path, required=True)
    run_parser.add_argument('--max-commits', type=int, default=10)
    run_parser.add_argument('--time-budget-min', type=float, default=330)
    run_parser.add_argument('--accept')
    run_parser.add_argument('--state-file', type=Path)
    run_parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    if args.command == 'gate':
        return gate(args.core.resolve(), args.upstream.resolve(),
                    args.parity.resolve() if args.parity else None,
                    selected_stages(args.stages, args.parity), args.target_dir,
                    args.stages is not None, args.json_out)
    if args.command == 'digest':
        result = json.loads(args.result.read_text())
        week = args.week or week_label(date.today())
        existing = args.existing.read_text() if args.existing and args.existing.is_file() else None
        args.out.write_text(format_digest(week, result.get('flagged', []), existing))
        print(week)
        return 0
    if args.command == 'prepare-wasm':
        prepare_wasm(args.core.resolve(), args.upstream.resolve())
        return 0
    if args.command == 'flags':
        candidate_flags(args.core.resolve(), args.upstream.resolve(), args.base)
        return 0
    return run_follow(args.core.resolve(), args.workdir.resolve(),
                      args.parity.resolve() if args.parity else None, args.max_commits,
                      args.time_budget_min, args.accept, args.state_file, args.out)


if __name__ == '__main__':
    sys.exit(main())
