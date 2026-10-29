#!/usr/bin/env python3
"""Record upstream's pool outcomes into test/unit/worker/_pool_oracle.g.dart.

usage: PYTHON -I tool/generate_pool_oracle.py [--check]

PYTHON is an interpreter with the pydantic-monty that tool/upstream/requirements.lock pins installed (the oracle).
Each case is an AsyncMonty built with one setting, or a sequence of checkouts
on one, and upstream's outcome: the error the constructor raises, which of
three checkouts in turn got a worker of its own, what a checkout already
waiting when the pool closed did, the error a checkout past its timeout
raises, or the error a pool whose worker cannot spawn raises. The Dart side
(test/unit/worker/worker_pool_test.dart) builds the same settings as
`PoolOptions` and must reach the same outcome on the VM, dart2js and
dart2wasm.

--check writes nothing and exits 1 if the committed file differs.
"""

from __future__ import annotations

import asyncio
import subprocess
import sys
from pathlib import Path
from typing import Any

import pydantic_monty as pm

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'test/unit/worker/_pool_oracle.g.dart'

U32_MAX = 2**32 - 1

# A worker executable that does not exist; the Dart runner uses the same path.
MISSING_WORKER = '/nonexistent/dart_monty_worker'

# Constructions upstream refuses: (id, AsyncMonty kwargs).
REFUSED = [
    # The sizes are `usize` arguments, extracted before everything else.
    ('min_negative', {'min_processes': -1}),
    ('max_negative', {'max_processes': -1}),
    ('min_negative_before_duration', {'min_processes': -1, 'checkout_timeout': -1.0}),
    ('checkout_timeout_negative', {'checkout_timeout': -1.0}),
    ('request_timeout_negative', {'request_timeout': -1.0}),
    ('feed_grace_negative', {'feed_duration_limit_grace': -1.0}),
    ('turn_grace_negative', {'turn_duration_limit_grace': -1.0}),
    ('recycle_negative', {'max_checkouts_per_worker': -1}),
    ('recycle_too_large', {'max_checkouts_per_worker': U32_MAX + 1}),
    # The recycle count is extracted with the arguments, before any duration.
    ('recycle_before_duration', {'max_checkouts_per_worker': -1, 'checkout_timeout': -1.0}),
    # The durations are parsed before the sizes are checked.
    ('duration_before_size', {'min_processes': 3, 'max_processes': 2, 'checkout_timeout': -1.0}),
]

# Pools upstream accepts, and which of three checkouts in turn got a worker
# of its own: each checkout's worker as the index of the first checkout that
# had it (`worker_pid`). (id, AsyncMonty kwargs.)
RECYCLED = [
    ('recycle_zero', {'max_checkouts_per_worker': 0}),
    ('recycle_two', {'max_checkouts_per_worker': 2}),
    ('recycle_u32_max', {'max_checkouts_per_worker': U32_MAX}),
]


def refusal(kwargs: dict[str, Any]) -> str:
    try:
        pm.AsyncMonty(**kwargs)
    except BaseException as e:  # noqa: BLE001 - the oracle's outcome is the data
        return f'{type(e).__name__}: {e}'
    raise SystemExit(f'upstream accepted {kwargs}')


async def workers_of(kwargs: dict[str, Any]) -> str:
    pids = []
    async with pm.AsyncMonty(max_processes=1, **kwargs) as pool:
        for _ in range(3):
            async with pool.checkout() as session:
                pids.append(session.worker_pid)
    return 'workers: ' + ', '.join(str(pids.index(p)) for p in pids)


async def close_with_a_waiter() -> dict[str, str]:
    """A checkout waiting for the only worker when the pool closes."""
    pool = pm.AsyncMonty(max_processes=1)
    await pool.__aenter__()
    held = pool.checkout()
    held_pid = (await held.__aenter__()).worker_pid
    waiting = asyncio.ensure_future(pool.checkout().__aenter__())
    await asyncio.sleep(0.2)
    await pool.__aexit__(None, None, None)
    try:
        await pool.checkout().__aenter__()
        after = 'accepted'
    except BaseException as e:  # noqa: BLE001 - the oracle's outcome is the data
        after = type(e).__name__
    await held.__aexit__(None, None, None)
    session = await waiting
    value = await session.feed_run('1 + 2')
    worker = 'the released one' if session.worker_pid == held_pid else 'a new one'
    return {
        'close_new_checkout': after,
        'close_waiting_checkout': f'value: {value!r}',
        'close_waiting_worker': f'worker: {worker}',
    }


async def checkout_timed_out() -> str:
    """A second checkout on a one-worker pool, past its checkout_timeout."""
    async with pm.AsyncMonty(max_processes=1, checkout_timeout=0.05) as pool:
        async with pool.checkout():
            try:
                async with pool.checkout():
                    pass
            except BaseException as e:  # noqa: BLE001 - the oracle's outcome is the data
                return f'{type(e).__name__}: {e}'
    raise SystemExit('the second checkout got a worker')


async def spawn_failed() -> str:
    """A pool whose worker executable does not exist."""
    try:
        async with pm.AsyncMonty(binary_path=MISSING_WORKER):
            pass
    except BaseException as e:  # noqa: BLE001 - the oracle's outcome is the data
        return f'{type(e).__name__}: {e}'
    raise SystemExit('a missing worker started')


async def record() -> dict[str, str]:
    out = {case_id: refusal(kwargs) for case_id, kwargs in REFUSED}
    for case_id, kwargs in RECYCLED:
        out[case_id] = await workers_of(kwargs)
    out.update(await close_with_a_waiter())
    out['checkout_timeout'] = await checkout_timed_out()
    out['spawn_missing_worker'] = await spawn_failed()
    return out


def dart_str(s: str) -> str:
    out = ["'"]
    for ch in s:
        o = ord(ch)
        if ch == '\\':
            out.append('\\\\')
        elif ch == "'":
            out.append("\\'")
        elif ch == '$':
            out.append('\\$')
        elif ch == '\n':
            out.append('\\n')
        elif o < 0x20 or o == 0x7f or o > 0x7e:
            out.append(f'\\u{{{o:x}}}')
        else:
            out.append(ch)
    out.append("'")
    return ''.join(out)


HEADER = """\
// Upstream's pool outcomes, recorded from pydantic-monty 1.1.0 (the oracle)
// by tool/generate_pool_oracle.py, which holds the Python form of each case.
//
// An outcome is `<ErrorClass>: <str(error)>` for a construction upstream
// refuses; `workers: a, b, c` for three checkouts in turn, each as the index
// of the first checkout that had its worker; the error class a checkout
// started after close raises; or `value: <repr>` for what a checkout that
// was already waiting when the pool closed then ran, and which worker it
// got (`worker: the released one` or `worker: a new one`); or
// `<ErrorClass>: <str(error)>` for a checkout past its timeout and for a
// pool whose worker executable does not exist.
//
// Generated by tool/generate_pool_oracle.py; do not edit by hand.

/// Per case id: upstream's outcome.
const Map<String, String> poolOracle = {
"""


def render(recorded: dict[str, str]) -> str:
    body = ''.join(f'  {dart_str(k)}: {dart_str(v)},\n' for k, v in recorded.items())
    text = HEADER + body + '};\n'
    formatted = subprocess.run(
        ['dart', 'format', '--stdin-name', str(OUT)],
        input=text, capture_output=True, text=True, check=True, cwd=ROOT,
    )
    return formatted.stdout


def main() -> int:
    check = '--check' in sys.argv[1:]
    text = render(asyncio.run(record()))
    if check:
        if OUT.read_text() != text:
            print(f'{OUT.relative_to(ROOT)} differs from the oracle', file=sys.stderr)
            return 1
        return 0
    OUT.write_text(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
