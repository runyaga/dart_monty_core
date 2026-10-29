#!/usr/bin/env python3
"""Record upstream's outcome for each dump and load case into test/unit/worker/_restore_oracle.g.dart.

usage: PYTHON -I tool/generate_restore_oracle.py [--check]

PYTHON is an interpreter with pydantic-monty 1.2.0 installed (the oracle),
the release the pin in tool/upstream/requirements.lock names.
Each case is a script of steps on upstream's AsyncMonty: sessions checked
out, fed, started, dumped, loaded and resumed, and the outcome of each step.
The Dart side (test/unit/worker/_restore_cases.dart) runs the same steps on
core's pool and must reach the same outcomes on the VM, dart2js and
dart2wasm.

Since 1.2.0 a restore keeps the destination's ceilings: the dump's limits
and the loader's are tightened into the stricter of the two (upstream's
`ResourceTracker::tighten_limits`), so a session loaded under a duration
ceiling is still bounded by it.

The step language (each a list):
- ['open', s, settings]: checks out session s with the settings (a map of
  script_name, type_check, max_suspensions, max_total_sleep_secs,
  max_feed_duration_secs, max_turn_duration_secs);
- ['feed', s, code]: feed_run, the outcome its value (always a str) or error;
- ['feed_dumping', s, code]: as feed, with `ext(x)` a coroutine host
  function that dumps s while its call waits, then returns x + 1;
- ['chdir', s, path]: switches s's working directory to path (upstream:
  feed_run's cwd=; core, which has no cwd= yet: os.chdir answered by an OS
  handler that says path is a directory);
- ['start', s, code]: feed_start, the outcome the snapshot it returns;
- ['dump', s], ['snapdump', s] and ['olddump', s]: dumps s, s's current
  snapshot, or the snapshot the last resume took, and keeps the bytes
  under s;
- ['load_session', s, src] and ['load_snapshot', s, src]: loads into s the
  bytes kept under src, or with src '!garbage', the bytes b'garbage';
- ['resume', s, n]: resumes s's current snapshot with the int n (a call's
  return value, or a lookup's value), the outcome the next snapshot;
- ['close', s].

The time a feed took is left out of a time-limit message: it is measured.

--check writes nothing and exits 1 if the committed file differs.
"""

from __future__ import annotations

import asyncio
import re
import subprocess
import sys
from pathlib import Path
from typing import Any

import pydantic_monty as pm

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'test/unit/worker/_restore_oracle.g.dart'

SUSPEND = 'import time\ntime.sleep(0)\n'
# Finite, and some 50 times longer than the 10 ms ceiling the destination
# keeps: about 0.6 s on a native worker. (Were it ever faster, the
# retained-ceiling cases would pass vacuously; the scripted
# pool_session_test cases still pin the rule.)
WORK = 'n = 0\nfor i in range(30000000):\n    n += i\nrepr(n > 0)'
SPIN = 'while True:\n    pass'
# Upstream's default grace (a second), spelled out: the parent's backstop
# sits a second behind the worker's own duration limit, so the worker's
# TimeoutError is what reaches the oracle. With no grace the parent's
# backstop and the worker's limit expire together, and the race between them
# would decide the recorded outcome (the parent kills the worker instead).
GRACE = {'feed_duration_limit_grace': 1.0, 'turn_duration_limit_grace': 1.0}

# (id, pool kwargs, steps).
CASES: list[tuple[str, dict[str, Any], list[list[Any]]]] = [
    # Between feeds: globals survive the trip.
    ('idle_roundtrip', {}, [
        ['open', 'a', {}], ['feed', 'a', 'x = 41\nrepr(x)'], ['dump', 'a'],
        ['open', 'b', {}], ['load_session', 'b', 'a'], ['feed', 'b', 'repr(x + 1)'],
    ]),
    # A session never fed dumps and loads too.
    ('fresh_dump', {}, [
        ['open', 'a', {}], ['dump', 'a'], ['open', 'b', {}],
        ['load_session', 'b', 'a'], ['feed', 'b', 'repr(2 + 2)'],
    ]),
    # The same dump loaded twice: two independent sessions.
    ('fork', {}, [
        ['open', 'a', {}], ['feed', 'a', 'x = 41\nrepr(x)'], ['dump', 'a'],
        ['open', 'b', {}], ['open', 'c', {}],
        ['load_session', 'b', 'a'], ['load_session', 'c', 'a'],
        ['feed', 'b', 'x = 100\nrepr(x)'], ['feed', 'c', 'repr(x)'], ['feed', 'b', 'repr(x)'],
    ]),
    # A dump does not make a session used, though the worker then refuses.
    ('dump_then_load', {}, [
        ['open', 'a', {}], ['dump', 'a'], ['open', 'b', {}], ['dump', 'b'],
        ['load_session', 'b', 'a'], ['feed', 'b', 'repr(3)'],
    ]),
    # Freshness: a load only into a session never fed or loaded.
    ('load_twice', {}, [
        ['open', 'a', {}], ['dump', 'a'], ['open', 'b', {}],
        ['load_session', 'b', 'a'], ['load_session', 'b', 'a'], ['load_snapshot', 'b', 'a'],
        ['feed', 'b', 'repr(5)'],
    ]),
    ('load_after_feed', {}, [
        ['open', 'a', {}], ['dump', 'a'], ['open', 'b', {}], ['feed', 'b', 'repr(1)'],
        ['load_session', 'b', 'a'], ['load_snapshot', 'b', 'a'], ['feed', 'b', 'repr(2)'],
    ]),
    ('load_after_start', {}, [
        ['open', 'a', {}], ['dump', 'a'], ['open', 'b', {}], ['start', 'b', 'repr(1)'],
        ['load_session', 'b', 'a'],
    ]),
    # Bytes the worker cannot load: refused, and the session runs on.
    ('garbage', {}, [
        ['open', 'b', {}], ['load_session', 'b', '!garbage'], ['feed', 'b', 'repr(6)'],
        ['load_session', 'b', '!garbage'],
    ]),
    ('garbage_snapshot', {}, [
        ['open', 'b', {}], ['load_snapshot', 'b', '!garbage'], ['feed', 'b', 'repr(6)'],
    ]),
    # Mid-feed: the call is re-announced under the dump's script name.
    ('suspended_roundtrip', {}, [
        ['open', 'a', {'script_name': 'a.py'}],
        ['start', 'a', 'y = 5\nv = ext(1, k=2)\nrepr(v + y)'], ['snapdump', 'a'],
        ['open', 'b', {'script_name': 'b.py'}], ['load_snapshot', 'b', 'a'],
        ['resume', 'b', 37], ['feed', 'b', 'repr(v)'],
        # The original runs on, unaffected.
        ['resume', 'a', 1], ['feed', 'a', 'repr(v)'],
    ]),
    # The session's dump while it is suspended is the snapshot's.
    ('session_dump_suspended', {}, [
        ['open', 'a', {}], ['start', 'a', 'repr(ext(2) * 2)'], ['dump', 'a'],
        ['resume', 'a', 4], ['open', 'b', {}], ['load_snapshot', 'b', 'a'], ['resume', 'b', 10],
    ]),
    ('lookup_roundtrip', {}, [
        ['open', 'a', {}], ['start', 'a', 'repr(undefined_name + 1)'], ['snapdump', 'a'],
        ['open', 'b', {}], ['load_snapshot', 'b', 'a'], ['resume', 'b', 41],
    ]),
    ('dump_after_resume', {}, [
        ['open', 'a', {}], ['start', 'a', 'repr(ext(1))'], ['resume', 'a', 3], ['olddump', 'a'],
    ]),
    # The wrong kind of dump: refused, and the session is finished.
    ('suspended_into_load_session', {}, [
        ['open', 'a', {}], ['start', 'a', 'repr(ext(1))'], ['snapdump', 'a'],
        ['open', 'b', {}], ['load_session', 'b', 'a'], ['feed', 'b', 'repr(1)'], ['dump', 'b'],
    ]),
    ('idle_into_load_snapshot', {}, [
        ['open', 'a', {}], ['feed', 'a', 'repr(1)'], ['dump', 'a'],
        ['open', 'b', {}], ['load_snapshot', 'b', 'a'], ['feed', 'b', 'repr(1)'],
    ]),
    # A host function dumps its own session while its call waits.
    ('dump_from_host_function', {}, [
        ['open', 'a', {}], ['feed_dumping', 'a', 'repr(await ext(1))'],
        ['open', 'b', {}], ['load_snapshot', 'b', 'a'],
    ]),
    # The dump brings its working directory: the next feed keeps it.
    ('cwd', {}, [
        ['open', 'a', {}], ['chdir', 'a', '/data'], ['dump', 'a'],
        ['open', 'b', {}], ['load_session', 'b', 'a'], ['feed', 'b', 'import os\nrepr(os.getcwd())'],
    ]),
    # The dump brings its type check, on or off.
    ('type_check_from_dump', {}, [
        ['open', 'a', {'type_check': True}], ['feed', 'a', 'x: int = 1\nrepr(x)'], ['dump', 'a'],
        ['open', 'b', {}], ['load_session', 'b', 'a'], ['feed', 'b', 'y: int = "a"\nrepr(y)'],
    ]),
    ('no_type_check_from_dump', {}, [
        ['open', 'a', {}], ['dump', 'a'],
        ['open', 'b', {'type_check': True}], ['load_session', 'b', 'a'],
        ['feed', 'b', 'y: int = "a"\nrepr(y)'],
    ]),
    # A load aborted over budget still adopted the dump, type check included.
    ('type_check_after_aborted_load', {}, [
        ['open', 'a', {'type_check': True}],
        ['start', 'a', 'import os\nrepr(os.getenv("X"))'], ['snapdump', 'a'],
        ['open', 'b', {'max_suspensions': 0}], ['load_snapshot', 'b', 'a'],
        ['feed', 'b', 'x: int = "a"\nrepr(x)'], ['feed', 'b', 'repr(2)'],
    ]),
    # A load_session leaves feed_start's snapshots under the session's name.
    ('script_name_after_load_session', {}, [
        ['open', 'a', {'script_name': 'a.py'}], ['dump', 'a'],
        ['open', 'b', {'script_name': 'b.py'}], ['load_session', 'b', 'a'],
        ['start', 'b', 'repr(ext(1))'],
    ]),
    # The suspension budget: the dump's limit, under the loader's as a
    # ceiling; the count restarts and the re-announced call counts.
    *[
        (f'suspensions_loader_{name}', {}, [
            ['open', 'a', {'max_suspensions': 5}],
            ['start', 'a', 'ext(1)\next(2)\next(3)\nrepr("done")'], ['snapdump', 'a'],
            ['open', 'b', settings], ['load_snapshot', 'b', 'a'],
            *([] if name == '0' else [['resume', 'b', 0], ['resume', 'b', 1], ['resume', 'b', 2]]),
            ['feed', 'b', SUSPEND + 'repr(7)'],
        ])
        for name, settings in [
            ('default', {}), ('0', {'max_suspensions': 0}), ('1', {'max_suspensions': 1}),
            ('2', {'max_suspensions': 2}), ('10', {'max_suspensions': 10}),
        ]
    ],
    ('suspensions_from_idle_dump', {}, [
        ['open', 'a', {'max_suspensions': 1}], ['feed', 'a', 'repr(1)'], ['dump', 'a'],
        ['open', 'b', {}], ['load_session', 'b', 'a'],
        ['feed', 'b', SUSPEND + 'repr(1)'], ['feed', 'b', SUSPEND + 'repr(2)'],
    ]),
    ('suspensions_restart', {}, [
        ['open', 'a', {'max_suspensions': 2}], ['feed', 'a', SUSPEND + SUSPEND + 'repr(1)'],
        ['dump', 'a'], ['feed', 'a', SUSPEND + 'repr(2)'],
        ['open', 'b', {}], ['load_session', 'b', 'a'],
        ['feed', 'b', SUSPEND + SUSPEND + 'repr(1)'], ['feed', 'b', SUSPEND + 'repr(2)'],
    ]),
    # The sleep budget likewise: the dump's limit, the count restarted.
    ('total_sleep_from_dump', {}, [
        ['open', 'a', {'max_total_sleep_secs': 0.05}],
        ['feed', 'a', 'import time\ntime.sleep(0.03)\nrepr(0)'], ['dump', 'a'],
        ['open', 'b', {}], ['load_session', 'b', 'a'],
        ['feed', 'b', 'import time\ntime.sleep(0.03)\nrepr(1)'],
        ['feed', 'b', 'import time\ntime.sleep(0.03)\nrepr(2)'],
    ]),
    # The duration ceilings are the stricter of the dump's and the
    # destination's: the destination's 10 ms keeps bounding the restored
    # session, so the worker's own limit ends the feed. The grace keeps the
    # parent's backstop behind that limit, so the worker's TimeoutError is
    # what the oracle records. The ids are the 1.1.0 oracle's, where the
    # destination's ceilings were forgotten; upstream 1.2.0 keeps them.
    ('feed_duration_forgotten', GRACE, [
        ['open', 'a', {}], ['dump', 'a'],
        ['open', 'b', {'max_feed_duration_secs': 0.01}], ['load_session', 'b', 'a'],
        ['feed', 'b', WORK],
    ]),
    ('turn_duration_forgotten', GRACE, [
        ['open', 'a', {}], ['dump', 'a'],
        ['open', 'b', {'max_turn_duration_secs': 0.01}], ['load_session', 'b', 'a'],
        ['feed', 'b', WORK],
    ]),
    ('feed_duration_from_dump', {}, [
        ['open', 'a', {'max_feed_duration_secs': 0.1}], ['dump', 'a'],
        ['open', 'b', {}], ['load_session', 'b', 'a'], ['feed', 'b', SPIN],
    ]),
    # A finished session dumps nothing.
    ('dump_closed', {}, [['open', 'a', {}], ['close', 'a'], ['dump', 'a']]),
]


def checkout_kwargs(settings: dict[str, Any]) -> dict[str, Any]:
    kwargs: dict[str, Any] = {}
    limits = {}
    for key, value in settings.items():
        if key in ('script_name', 'type_check'):
            kwargs[key] = value
        else:
            limits[key] = value
    if limits:
        kwargs['limits'] = limits
    return kwargs


def args_text(args, kwargs) -> str:
    named = ', '.join(f'{k}: {v}' for k, v in sorted(kwargs.items()))
    return f'args={list(args)} kwargs={{{named}}}'


def describe(snapshot) -> str:
    if isinstance(snapshot, pm.MontyComplete):
        return f'complete: {snapshot.output}'
    p = snapshot.position
    at = f'script={snapshot.script_name} at={p.filename}:{p.start}-{p.end}'
    if isinstance(snapshot, pm.AsyncFunctionSnapshot):
        kind = 'os' if snapshot.is_os_function else 'call'
        return f'{kind} {snapshot.function_name} {args_text(snapshot.args, snapshot.kwargs)} {at}'
    if isinstance(snapshot, pm.AsyncNameLookupSnapshot):
        return f'lookup {snapshot.variable_name} {at}'
    return f'futures {snapshot.pending_call_ids} {at}'


def error_text(e: BaseException) -> str:
    if isinstance(e, pm.MontyTypingError):
        return f'MontyTypingError: {e.display()}'
    if isinstance(e, pm.MontyError):
        # A MontyError without a `display` (a crashed worker, say) still has
        # a message: the oracle records the outcome, it does not crash on it.
        display = getattr(e, 'display', None)
        rendered = display('type-msg') if display is not None else str(e)
        text = f'{type(e).__name__}: {rendered}'
        return re.sub(r'time limit exceeded: \S+ >', 'time limit exceeded: … >', text)
    if isinstance(e, RuntimeError) and str(e) == 'this checkout has already been finished':
        return 'finished'
    return f'{type(e).__name__}: {e}'


async def run_case(pool_kwargs, steps) -> list[str]:
    outcomes = []
    sessions: dict[str, Any] = {}
    contexts: dict[str, Any] = {}
    snapshots: dict[str, Any] = {}
    spent: dict[str, Any] = {}
    dumps: dict[str, bytes] = {}
    async with pm.AsyncMonty(max_processes=3, **pool_kwargs) as pool:
        try:
            for step in steps:
                op, name = step[0], step[1]
                try:
                    outcomes.append(await run_step(pool, op, name, step[2:], sessions, contexts, snapshots, spent, dumps))
                except BaseException as e:  # noqa: BLE001 - the oracle's outcome is the data
                    outcomes.append(error_text(e))
        finally:
            for context in contexts.values():
                await context.__aexit__(None, None, None)
    return outcomes


async def run_step(pool, op, name, rest, sessions, contexts, snapshots, spent, dumps) -> str:
    if op == 'open':
        context = pool.checkout(**checkout_kwargs(rest[0]))
        sessions[name] = await context.__aenter__()
        contexts[name] = context
        return 'ok'
    session = sessions[name]
    if op == 'close':
        await contexts.pop(name).__aexit__(None, None, None)
        return 'ok'
    if op == 'feed':
        return f'value: {await session.feed_run(rest[0])}'
    if op == 'feed_dumping':
        async def ext(x):
            dumps[name] = await session.dump()
            return x + 1
        return f'value: {await session.feed_run(rest[0], external_lookup={"ext": ext})}'
    if op == 'chdir':
        await session.feed_run('None', cwd=rest[0])
        return 'ok'
    if op == 'start':
        snapshots[name] = await session.feed_start(rest[0])
        return describe(snapshots[name])
    if op == 'dump':
        dumps[name] = await session.dump()
        return 'dumped'
    if op in ('snapdump', 'olddump'):
        dumps[name] = (snapshots if op == 'snapdump' else spent)[name].dump()
        return 'dumped'
    if op in ('load_session', 'load_snapshot'):
        state = b'garbage' if rest[0] == '!garbage' else dumps[rest[0]]
        if op == 'load_session':
            await session.load_session(state)
            return 'ok'
        snapshots[name] = await session.load_snapshot(state)
        return describe(snapshots[name])
    if op == 'resume':
        snapshot = spent[name] = snapshots[name]
        if isinstance(snapshot, pm.AsyncNameLookupSnapshot):
            snapshots[name] = await snapshot.resume(value=rest[0])
        else:
            snapshots[name] = await snapshot.resume({'return_value': rest[0]})
        return describe(snapshots[name])
    raise SystemExit(f'unknown step {op}')


async def record() -> list[tuple[str, dict[str, Any], list[tuple[list[Any], str]]]]:
    out = []
    for case_id, pool_kwargs, steps in CASES:
        outcomes = await run_case(pool_kwargs, steps)
        out.append((case_id, pool_kwargs, list(zip(steps, outcomes))))
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


def dart_value(v: Any) -> str:
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, (int, float)):
        return repr(v)
    if isinstance(v, str):
        return dart_str(v)
    if isinstance(v, list):
        return '[' + ', '.join(dart_value(x) for x in v) + ']'
    if isinstance(v, dict):
        return '<String, Object>{' + ', '.join(f'{dart_str(k)}: {dart_value(x)}' for k, x in v.items()) + '}'
    raise SystemExit(f'no Dart form for {v!r}')


HEADER = """\
// Upstream's outcome for each dump and load case, recorded from
// pydantic-monty 1.2.0 (the oracle) by tool/generate_restore_oracle.py, which
// also defines the step language. The Dart runner is in _restore_cases.dart.
//
// Each case is the pool's settings and a list of steps, each with
// upstream's outcome: `ok`, `dumped`, `value: <str>`, a snapshot as
// `call|os <name> args=[..] kwargs={..} script=<name> at=<file>:<start>-<end>`,
// `lookup <name> ...` or `complete: <str>`, `finished`, or
// `<ErrorClass>: <message>` (`display('type-msg')` for a MontyError).
//
// Generated by tool/generate_restore_oracle.py; do not edit by hand.

/// Per case id: the pool's settings, and the steps with their outcomes.
const Map<
  String,
  ({Map<String, Object> pool, List<({List<Object> step, String outcome})> steps})
>
restoreOracle = {
"""


def render(recorded) -> str:
    body = ''.join(
        f'  {dart_str(case_id)}: (pool: {dart_value(pool_kwargs)}, steps: [\n'
        + ''.join(f'    (step: {dart_value(step)}, outcome: {dart_str(outcome)}),\n' for step, outcome in steps)
        + '  ]),\n'
        for case_id, pool_kwargs, steps in recorded
    )
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
