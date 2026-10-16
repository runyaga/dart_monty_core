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
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


MONTY_CRATES = (
    'monty', 'monty-proto', 'monty-types', 'monty-alloc', 'monty-fs',
    'monty-macros', 'monty-type-checking', 'monty-typeshed',
)
ALL_STAGES = ('upstream-tests', 'worker-build', 'corpus', 'parity')


def command(cmd: list[str], cwd: Path | None = None,
            env: dict[str, str] | None = None, check: bool = True) -> subprocess.CompletedProcess[str]:
    merged = os.environ.copy()
    if env:
        merged.update(env)
    return subprocess.run(cmd, cwd=cwd, env=merged, text=True, check=check,
                          stdout=subprocess.PIPE, stderr=subprocess.STDOUT)


def git(directory: Path, *args: str, check: bool = True) -> str:
    return command(['git', '-C', str(directory), *args], check=check).stdout.strip()


def load_pin(core: Path) -> dict[str, Any]:
    return json.loads((core / 'tool/upstream/upstream-pin.json').read_text())


def read_state_or_seed(state_file: Path | None, pin: dict[str, Any]) -> dict[str, str]:
    """Read persistent state, or start at the immutable upstream pin."""
    data = json.loads(state_file.read_text()) if state_file is not None and state_file.is_file() else None
    return state_from_data(data, pin)


def state_from_data(data: dict[str, Any] | None, pin: dict[str, Any]) -> dict[str, str]:
    """Validate state data, or provide the immutable pin as its seed."""
    if data is None:
        return {'sha': str(pin['commit']), 'advanced': '', 'via': 'pin'}
    if not isinstance(data.get('sha'), str) or not data['sha']:
        raise ValueError('last_good state has no sha')
    return {key: str(value) for key, value in data.items()}


def write_state(state_file: Path | None, sha: str, via: str) -> None:
    if state_file is None:
        return
    state_file.parent.mkdir(parents=True, exist_ok=True)
    state_file.write_text(json.dumps({
        'sha': sha,
        'advanced': datetime.now(timezone.utc).isoformat(timespec='seconds'),
        'via': via,
    }, indent=2) + '\n')


def selected_stages(value: str | None, parity: Path | None) -> tuple[str, ...]:
    if value is None:
        return ALL_STAGES if parity is not None else ALL_STAGES[:-1]
    selected = tuple(item for item in value.split(',') if item)
    bad = set(selected) - set(ALL_STAGES)
    if bad:
        raise ValueError(f'unknown stages: {", ".join(sorted(bad))}')
    if 'parity' in selected and parity is None:
        raise ValueError('parity selected without --parity')
    return selected


def select_commits(pending: list[str], accept: str | None) -> tuple[str | None, list[str]]:
    """Return an accepted commit and the commits that still need a gate."""
    if accept is None:
        return None, pending
    if accept not in pending:
        raise ValueError(f'accepted SHA {accept} is not pending')
    return accept, pending[pending.index(accept) + 1:]


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


def gate(core: Path, upstream: Path, parity: Path | None, stages: tuple[str, ...],
         target_dir: Path | None, report_skips: bool = False) -> int:
    head = git(upstream, 'rev-parse', 'HEAD')
    print(f'UPSTREAM HEAD {head}')
    root_target = target_dir or Path(tempfile.mkdtemp(prefix='follow-upstream-target-'))
    try:
        stage_order = ALL_STAGES if parity is not None else ALL_STAGES[:-1]
        for stage in stage_order:
            if stage not in stages:
                if report_skips:
                    print(f'GATE SKIP stage={stage}')
                continue
            print(f'GATE RUN stage={stage}')
            try:
                if stage == 'upstream-tests':
                    result = command(['cargo', 'test', '--locked', '-p', 'monty-fs', '-p', 'monty-alloc',
                                      '-p', 'monty-types', '-p', 'monty-proto'], cwd=upstream,
                                     env={'CARGO_TARGET_DIR': str(root_target / 'upstream-tests')})
                    print(result.stdout, end='')
                elif stage == 'worker-build':
                    prepare_worker(core, upstream)
                    result = command(['cargo', 'build', '--release', '--bin', 'dart_monty_worker', '--lib',
                                      '--message-format=json-render-diagnostics'], cwd=core / 'native/worker',
                                     env={'CARGO_TARGET_DIR': str(root_target / 'worker-build')})
                    copy_worker(core, result.stdout)
                elif stage == 'corpus':
                    result = command(['bash', 'tool/test_corpus_worker.sh', 'native'], cwd=core)
                    print(result.stdout, end='')
                else:
                    assert parity is not None
                    with tempfile.TemporaryDirectory(prefix='follow-upstream-parity-') as temp:
                        out = Path(temp)
                        result = command(['python3', '-I', str(parity / 'tool/parity/run.py'), 'vm',
                                          '--core', str(core), '--out', str(out)])
                        print(result.stdout, end='')
                        result = command(['python3', '-I', str(parity / 'tool/parity/score.py'), str(out),
                                          '--json', str(out / 'score.json'), '--markdown', str(out / 'score.md'),
                                          '--assert-current', str(parity / 'tool/parity/baseline-current.json')])
                        print(result.stdout, end='')
            except (OSError, ValueError, subprocess.CalledProcessError) as exc:
                if isinstance(exc, subprocess.CalledProcessError) and exc.stdout:
                    print(exc.stdout, end='')
                print(f'GATE RED stage={stage}')
                return 1
        if report_skips and set(stages) != set(stage_order):
            print('GATE INCOMPLETE')
            return 2
        print('GATE GREEN')
        return 0
    finally:
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


def result_status(at_head: bool, advanced: bool, stopped: str | None, budget: bool) -> str:
    if stopped is not None:
        return stopped
    if budget:
        return 'budget'
    if at_head:
        return 'advanced' if advanced else 'caught-up'
    return 'advanced' if advanced else 'budget'


def last_good_after(start: str, commits: list[dict[str, Any]]) -> str:
    """Return the last eligible commit, stopping at the first flag or red gate."""
    last_good = start
    for commit in commits:
        if commit['flags'] or commit['gate'] != 'green':
            break
        last_good = str(commit['sha'])
    return last_good


def summary(result: dict[str, Any]) -> str:
    lines = [f"## Upstream follow: {result['status']}", '',
             f"- Start: `{result['start']}`", f"- Last good: `{result['last_good']}`",
             f"- Head: `{result['head']}`", f"- Behind: {result['behind']}"]
    for item in result['commits']:
        flags = ', '.join(item['flags']) or 'none'
        lines.append(f"- `{item['sha']}` {item['subject']} | {item['gate']} {item['stage']} | flags: {flags}")
    return '\n'.join(lines) + '\n'


def write_result(path: Path, result: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result, indent=2) + '\n')
    step_summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if step_summary:
        Path(step_summary).open('a').write(summary(result))


def run_follow(core: Path, workdir: Path, parity: Path | None, max_commits: int,
               time_budget_min: float, accept: str | None, state_file: Path | None,
               out: Path) -> int:
    pin = load_pin(core)
    state = read_state_or_seed(state_file, pin)
    start = state['sha']
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

    try:
        accepted, commits = select_commits(commits, accept)
    except ValueError as exc:
        result = {'pin': pin['commit'], 'start': start, 'last_good': start, 'head': head,
                  'behind': len(commits), 'commits': [], 'status': 'error', 'error': str(exc)}
        write_result(out, result)
        return 1
    if accepted:
        state['sha'] = accepted
        write_state(state_file, accepted, 'accepted')

    records: list[dict[str, Any]] = []
    current = state['sha']
    resume_start = current
    advanced = current != start
    stopped: str | None = None
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
        target = workdir / 'targets' / sha
        gate_cmd = [sys.executable, '-I', str(Path(__file__).resolve()), 'gate', '--core', str(core),
                    '--upstream', str(repo), '--target-dir', str(target)]
        if parity is not None:
            gate_cmd.extend(['--parity', str(parity)])
        outcome = command(gate_cmd, check=False)
        print(outcome.stdout, end='')
        gate_ok = outcome.returncode == 0 and 'GATE GREEN' in outcome.stdout
        stage_match = re.search(r'GATE RED stage=([\w-]+)', outcome.stdout)
        stage = stage_match.group(1) if stage_match else ('all' if gate_ok else 'unknown')
        records.append({'sha': sha, 'subject': subject, 'flags': flags,
                        'gate': 'green' if gate_ok else 'red', 'stage': stage,
                        'seconds': round(time.monotonic() - began, 3)})
        if flags:
            stopped = 'flagged'
            break
        if not gate_ok:
            stopped = 'red'
            break
        current = sha
        advanced = True
        write_state(state_file, current, 'green')

    current = last_good_after(resume_start, records)
    remaining = git(repo, 'rev-list', '--first-parent', f'{current}..origin/main').splitlines()
    budget = stopped is None and bool(remaining)
    status = result_status(not remaining, advanced, stopped, budget)
    result = {'pin': pin['commit'], 'start': start, 'last_good': current, 'head': head,
              'behind': len(remaining), 'commits': records, 'status': status}
    write_result(out, result)
    return 0 if status in ('caught-up', 'advanced', 'budget') else 1


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='command', required=True)
    gate_parser = sub.add_parser('gate')
    gate_parser.add_argument('--core', type=Path, required=True)
    gate_parser.add_argument('--upstream', type=Path, required=True)
    gate_parser.add_argument('--parity', type=Path)
    gate_parser.add_argument('--stages')
    gate_parser.add_argument('--target-dir', type=Path)
    flags_parser = sub.add_parser('flags')
    flags_parser.add_argument('--core', type=Path, required=True)
    flags_parser.add_argument('--upstream', type=Path, required=True)
    flags_parser.add_argument('--base')
    run_parser = sub.add_parser('run')
    run_parser.add_argument('--core', type=Path, required=True)
    run_parser.add_argument('--workdir', type=Path, required=True)
    run_parser.add_argument('--parity', type=Path)
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
                    args.stages is not None)
    if args.command == 'flags':
        candidate_flags(args.core.resolve(), args.upstream.resolve(), args.base)
        return 0
    return run_follow(args.core.resolve(), args.workdir.resolve(),
                      args.parity.resolve() if args.parity else None, args.max_commits,
                      args.time_budget_min, args.accept, args.state_file, args.out)


if __name__ == '__main__':
    sys.exit(main())
