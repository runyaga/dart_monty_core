#!/usr/bin/env python3
"""Record upstream's outcome for each session-surface case into test/unit/worker/_session_oracle.g.dart.

usage: PYTHON -I tool/generate_session_oracle.py [--check]

PYTHON is an interpreter with pydantic-monty 1.1.0 installed (the oracle).
Each case runs steps on one checkout of upstream's AsyncMonty, exercising
`feed_run` / `feed_start`'s `external_lookup` and `cwd`. The Dart side
(test/unit/worker/_session_cases.dart) builds the same lookups on core's
pool and must reach the same outcomes on the VM, dart2js and dart2wasm.

A step is [op, code, lookup, cwd, inputs]:
- op: 'run' (feed_run), or 'start' (feed_start, then resume_auto() on each
  snapshot until it completes or fails);
- lookup: None (no external_lookup), or name -> entry, an entry being
  ['v', value] (a plain value), ['f'] (a host function returning
  `(args, kwargs)`), ['c'] (a coroutine host function doubling its one
  argument), ['cyclic'] (a list holding itself), ['k', kind] (a value of
  one of the KINDS below, mirrored in Dart), ['from', code] (the value
  feed_run(code) returns in the same session, fed just before the step), ['I'] (a ClassInstance of
  Point(1, 2), eager 'all') or ['T'] (a ClassType of Point, init);
- cwd: None or the string passed;
- inputs: None or name -> value.

An outcome is `value: <str>` (each case's code returns a str), `finished`
(a call on a checkout already finished), `<ErrorClass>: <message>`
(`display('type-msg')` for a MontyError), or for 'start' the snapshots
passed, `lookup:<name>` / `call:<name>`, then the end, joined by ` > `.

--check writes nothing and exits 1 if the committed file differs.
"""

from __future__ import annotations

import asyncio
import collections
import datetime
import pathlib
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pydantic_monty as pm

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'test/unit/worker/_session_oracle.g.dart'


@dataclass
class Point:
    """The host class of the ['I'] and ['T'] entries; _session_cases.dart mirrors it."""

    x: int
    y: int


GETCWD = 'import os\nrepr(os.getcwd())'

Pt = collections.namedtuple('Pt', 'x y')

# One value per host type, by kind; _session_cases.dart builds the same.
KINDS: dict[str, Any] = {
    'big': 2**100,
    'bool': True,
    'bytes': b'x',
    'date': datetime.date(2020, 1, 2),
    'datetime': datetime.datetime(2020, 1, 2, 3, 4, 5),
    'dict': {1: 2},
    'ellipsis': ...,
    'exception': ValueError('x'),
    'float': 1.5,
    'frozenset': frozenset({1}),
    'namedtuple': Pt(1, 2),
    'notimplemented': NotImplemented,
    'path': pathlib.PurePosixPath('/a'),
    'set': {1},
    'time': datetime.time(1, 2, 3),
    'timedelta': datetime.timedelta(days=1),
    'timezone': datetime.timezone.utc,
    'tuple': (1,),
}


def run(code, lookup=None, cwd=None, inputs=None):
    return ['run', code, lookup, cwd, inputs]


def start(code, lookup=None, cwd=None, inputs=None):
    return ['start', code, lookup, cwd, inputs]


CASES: list[tuple[str, list[list[Any]]]] = [
    # external_lookup: a plain value is converted when the name is read,
    # and the read binds it as a global for later feeds.
    ('lookup_value', [run('repr(x + 1)', {'x': ['v', 41]})]),
    ('lookup_binds_global', [
        run('y.append(3)\nrepr(y)', {'y': ['v', [1, 2]]}),
        run('repr(y)'),
    ]),
    ('lookup_read_once', [run('a = x\nb = x\nrepr(a is b)', {'x': ['v', [1]]})]),
    ('lookup_none_value', [run('repr(x)', {'x': ['v', None]})]),
    ('lookup_absent', [run('nope', {'x': ['v', 1]}), run('repr(1)')]),
    ('lookup_no_map', [run('nope')]),
    ('lookup_inputs_win', [run('repr(x)', {'x': ['v', 2]}, inputs={'x': 1})]),
    # A host function is renamed to its lookup key.
    ('lookup_function_call', [run("repr(alias(1, k='v'))", {'alias': ['f']})]),
    ('lookup_function_repr', [run('repr(alias)', {'alias': ['f']})]),
    ('lookup_function_bound', [
        run('g = alias\nrepr(g(2))', {'alias': ['f']}),
    ]),
    # Calling a name whose entry is not a function: the host calls the
    # object, which is not callable.
    ('call_int', [run('p()', {'p': ['v', 3]}), run('repr(1)')]),
    ('call_list', [run('p()', {'p': ['v', [1]]})]),
    ('call_none', [run('p()', {'p': ['v', None]})]),
    ('call_str', [run('p()', {'p': ['v', 's']})]),
    ('call_instance', [run('p()', {'p': ['I']})]),
    ('call_type', [run('p(1, 2)', {'p': ['T']})]),
    # The name is the host object's type, as CPython's error gives it.
    *[(f'call_{kind}', [run('p()', {'p': ['k', kind]})]) for kind in KINDS],
    # Values the sandbox returned: upstream decodes them to its own proxy
    # classes, except a builtin type, which is the type itself (calling it
    # by name runs on the host, which core cannot: _session_cases.dart
    # tests that divergence apart).
    ('call_std_function', [run('p("42")', {'p': ['from', 'abs']})]),
    ('read_std_function', [run('repr(p)', {'p': ['from', 'abs']})]),
    ('call_class_proxy', [run('p()', {'p': ['from', 'class B:\n    pass\nB()']})]),
    ('read_std_type', [run('q = p\nrepr(q("42"))', {'p': ['from', 'int']})]),
    ('read_instance', [run('repr(p)', {'p': ['I']})]),
    ('read_type', [run('repr(p)', {'p': ['T']})]),
    # Read first, the class is a proxy, which constructs.
    ('read_type_then_call', [run('q = p\nrepr(q(1, 2).x)', {'p': ['T']})]),
    # A value the binding cannot convert ends the checkout; a sandbox `try`
    # does not see it.
    ('lookup_cyclic', [run('x', {'x': ['cyclic']}), run('repr(1)')]),
    ('lookup_cyclic_try', [
        run("try:\n    x\nexcept Exception:\n    r = 'caught'\nr", {'x': ['cyclic']}),
    ]),
    ('lookup_surrogate', [run('x', {'x': ['v', 'a\ud800']}), run('repr(1)')]),
    # Coroutine host functions.
    ('coroutine_await', [run('repr(await c(5))', {'c': ['c']})]),
    ('coroutine_gather', [
        run('import asyncio\nrepr(await asyncio.gather(c(1), c(2)))', {'c': ['c']}),
    ]),
    # feed_start keeps the lookup for resume_auto().
    ('start_lookup_value', [start('repr(x + 1)', {'x': ['v', 41]})]),
    ('start_function', [start('repr(al())', {'al': ['f']})]),
    ('start_lookup_cyclic', [start('x', {'x': ['cyclic']}), run('repr(1)')]),
    # cwd: an absolute path, trailing slashes trimmed, normalized; it lasts
    # until a feed switches it.
    ('cwd_set', [run(GETCWD, cwd='/tmp/a/'), run(GETCWD)]),
    ('cwd_switch', [run(GETCWD, cwd='/x'), run(GETCWD), run(GETCWD, cwd='/y')]),
    ('cwd_root', [run(GETCWD, cwd='///')]),
    ('cwd_dots', [run(GETCWD, cwd='/a/./b/../c')]),
    ('cwd_chars', [run(GETCWD, cwd='/a"b\\c\té​')]),
    ('cwd_relative_path', [run('from pathlib import Path\nPath("f.txt").exists()', cwd='/data')]),
    ('cwd_start', [start(GETCWD, cwd='/z'), run(GETCWD)]),
    # Refused before anything is sent; the session runs on.
    ('cwd_relative', [run(GETCWD, cwd='rel'), run(GETCWD)]),
    ('cwd_empty', [run(GETCWD, cwd='')]),
    ('cwd_nul', [run(GETCWD, cwd='/a\x00b')]),
    ('cwd_escaped', [run(GETCWD, cwd='rel\x7f\u0085퟿"\\\n')]),
    ('cwd_refused_keeps', [run(GETCWD, cwd='/k'), run(GETCWD, cwd='k'), run(GETCWD)]),
    ('cwd_after_input_refusal', [run(GETCWD, cwd='rel', inputs={'a': ['cyclic']})]),
    # A str Python cannot encode is refused while the arguments are read,
    # before anything else.
    ('cwd_surrogate', [run(GETCWD, cwd='/a\ud800'), run(GETCWD)]),
    ('cwd_surrogate_first', [run(GETCWD, cwd='r\ud800', inputs={'a': ['cyclic']})]),
]


def host_function(*args: Any, **kwargs: Any) -> Any:
    return (args, kwargs)


async def doubling(x: Any) -> Any:
    await asyncio.sleep(0.01)
    return x * 2


def entry(spec: list[Any]) -> Any:
    kind = spec[0]
    if kind == 'v':
        return spec[1]
    if kind == 'f':
        return host_function
    if kind == 'c':
        return doubling
    if kind == 'k':
        return KINDS[spec[1]]
    if kind == 'cyclic':
        cyclic: list[Any] = []
        cyclic.append(cyclic)
        return cyclic
    if kind == 'I':
        return pm.ClassInstance(Point(1, 2), eager_attrs='all')
    if kind == 'T':
        return pm.ClassType(Point, init=True)
    raise SystemExit(f'unknown entry {spec!r}')


def built(values: dict[str, Any] | None) -> dict[str, Any] | None:
    if values is None:
        return None
    return {
        k: entry(v) if isinstance(v, list) else v
        for k, v in values.items()
        if not (isinstance(v, list) and v[0] == 'from')
    }


def error_text(e: BaseException) -> str:
    if isinstance(e, RuntimeError) and str(e) == 'this checkout has already been finished':
        return 'finished'
    if isinstance(e, pm.MontyError):
        return f'{type(e).__name__}: {e.display("type-msg")}'
    return f'{type(e).__name__}: {e}'


def shown(value: Any) -> str:
    return f'value: {value}' if isinstance(value, str) else f'nonstr: {value!r}'


async def run_step(session: Any, step: list[Any]) -> str:
    op, code, lookup, cwd, inputs = step
    returned = {
        name: await session.feed_run(spec[1])
        for name, spec in (lookup or {}).items()
        if spec[0] == 'from'
    }
    kwargs: dict[str, Any] = {
        'external_lookup': None if lookup is None else {**built(lookup), **returned},
        'inputs': built(inputs),
    }
    if cwd is not None:
        kwargs['cwd'] = cwd
    if op == 'run':
        return shown(await session.feed_run(code, **kwargs))
    passed = []
    try:
        snap = await session.feed_start(code, **kwargs)
        while not isinstance(snap, pm.MontyComplete):
            if isinstance(snap, pm.AsyncNameLookupSnapshot):
                passed.append(f'lookup:{snap.variable_name}')
            elif isinstance(snap, pm.AsyncFunctionSnapshot):
                passed.append(f'call:{snap.function_name}')
            else:
                raise SystemExit(f'unexpected snapshot {snap!r}')
            snap = await snap.resume_auto()
        passed.append(shown(snap.output))
    except BaseException as e:  # noqa: BLE001 - the oracle's outcome is the data
        if isinstance(e, SystemExit):
            raise
        passed.append(error_text(e))
    return ' > '.join(passed)


async def run_case(steps: list[list[Any]]) -> list[str]:
    outcomes = []
    async with pm.AsyncMonty(max_processes=1) as pool, pool.checkout() as session:
        for step in steps:
            try:
                outcomes.append(await run_step(session, step))
            except BaseException as e:  # noqa: BLE001 - the oracle's outcome is the data
                if isinstance(e, SystemExit):
                    raise
                outcomes.append(error_text(e))
    return outcomes


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
    if v is None:
        return 'null'
    if isinstance(v, bool):
        return 'true' if v else 'false'
    if isinstance(v, int):
        return repr(v)
    if isinstance(v, str):
        return dart_str(v)
    if isinstance(v, list):
        return '<Object?>[' + ', '.join(dart_value(x) for x in v) + ']'
    if isinstance(v, dict):
        return '<String, Object?>{' + ', '.join(f'{dart_str(k)}: {dart_value(x)}' for k, x in v.items()) + '}'
    raise SystemExit(f'no Dart form for {v!r}')


HEADER = """\
// Upstream's outcome for each session-surface case (external_lookup, cwd),
// recorded from pydantic-monty 1.1.0 (the oracle) by
// tool/generate_session_oracle.py, which also defines the case language.
// The Dart runner is in _session_cases.dart.
//
// Generated by tool/generate_session_oracle.py; do not edit by hand.

/// Per case id: the steps with their outcomes.
const Map<String, List<({List<Object?> step, String outcome})>>
sessionOracle = {
"""


def render(recorded) -> str:
    body = ''.join(
        f'  {dart_str(case_id)}: [\n'
        + ''.join(f'    (step: {dart_value(step)}, outcome: {dart_str(outcome)}),\n' for step, outcome in steps)
        + '  ],\n'
        for case_id, steps in recorded
    )
    text = HEADER + body + '};\n'
    formatted = subprocess.run(
        ['dart', 'format', '--stdin-name', str(OUT)],
        input=text, capture_output=True, text=True, check=True, cwd=ROOT,
    )
    return formatted.stdout


async def record() -> list[Any]:
    out = []
    for case_id, steps in CASES:
        outcomes = await run_case(steps)
        out.append((case_id, list(zip(steps, outcomes))))
    return out


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
