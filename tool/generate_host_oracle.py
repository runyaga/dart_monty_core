#!/usr/bin/env python3
"""Record upstream's outcome for each host-object case into test/unit/worker/_host_oracle.g.dart.

usage: PYTHON -I tool/generate_host_oracle.py [--check]

PYTHON is an interpreter with pydantic-monty 1.1.0 installed (the oracle).
Each case builds host objects and their ClassInstance / ClassType wrappers,
then runs steps on upstream's AsyncMonty. The Dart side
(test/unit/worker/_host_cases.dart) builds the same objects and wrappers on
core's pool and must reach the same outcomes on the VM, dart2js and
dart2wasm.

The host class is `Point` (below), mirrored in Dart by _host_cases.dart.

A case is (id, objects, wrappers, steps):
- objects: name -> [x, y], a Point;
- wrappers, built in order: [name, spec], where spec is
  ['I', object, policies, options] (a ClassInstance; options: 'id' an int
  for uuid.UUID(int=n), 'class' a wrapper name for class_type) or
  ['T', policies, options] (a ClassType of Point; options: 'id', 'init',
  'instance' the instance policies, 'convert': 'redact' to send every
  attribute 'x' as '***');
- policies: {'eager': .., 'lazy': .., 'methods': ..}, each None, 'all' or a
  list of names;
- steps: ['open', s]; ['feed', s, code, [input names]] (each input bound to
  the wrapper of that name); ['dump', s] (kept under s);
  ['load_session', s, src]; ['close', s].

An outcome is `ok`, `dumped`, `value: <shown>` or `<ErrorClass>: <message>`
(`display('type-msg')` for a MontyError). A value is shown as its repr,
except that a host object is `is:<name>` (the object of that name) and a
proxy `proxy:<class>`, inside lists and tuples too.

--check writes nothing and exits 1 if the committed file differs.
"""

from __future__ import annotations

import asyncio
import subprocess
import sys
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import pydantic_monty as pm

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'test/unit/worker/_host_oracle.g.dart'


@dataclass
class Point:
    """The host class every case uses; _host_cases.dart mirrors it."""

    x: int
    y: int

    ORIGIN_NAME = 'origin'

    def sum(self) -> int:
        return self.x + self.y

    def shifted(self, dx: int, *, dy: int = 0) -> list[int]:
        return [self.x + dx, self.y + dy]

    async def later(self) -> int:
        return self.x * 10

    def fails(self) -> int:
        raise ValueError('no sum today')

    @property
    def norm1(self) -> int:
        return abs(self.x) + abs(self.y)

    @property
    def boom(self) -> int:
        raise KeyError('boom')

    @property
    def missing(self) -> int:
        raise AttributeError('missing')

    @classmethod
    def describe(cls) -> str:
        return 'Point class'

    @staticmethod
    def add(a: int, b: int) -> int:
        return a + b


class Redact(pm.ClassType):
    """A ClassType whose hook sends every attribute 'x' as '***'."""

    def convert_value(self, name: str, value: Any) -> Any:
        return '***' if name == 'x' else value


def P(eager=None, lazy=None, methods=None) -> dict[str, Any]:
    return {'eager': eager, 'lazy': lazy, 'methods': methods}


def feed(s: str, code: str, inputs: list[str] | None = None) -> list[Any]:
    return ['feed', s, code, inputs or []]


ALL = P('all', 'all', 'all')

# (id, objects, wrappers, steps).
CASES: list[tuple[str, dict[str, Any], list[Any], list[list[Any]]]] = [
    ('eager_all', {'o': [1, 2]}, [['p', ['I', 'o', P(eager='all'), {}]]], [
        ['open', 's'],
        feed('s', '(p.x, p.y)', ['p']),
        feed('s', 'p.norm1'),
    ]),
    ('eager_named', {'o': [1, 2]}, [['p', ['I', 'o', P(eager=['y', 'norm1']), {}]]], [
        ['open', 's'],
        feed('s', '(p.y, p.norm1)', ['p']),
        feed('s', 'p.x'),
    ]),
    ('eager_unknown_name', {'o': [1, 2]}, [['p', ['I', 'o', P(eager=['nope']), {}]]], [
        ['open', 's'],
        feed('s', '1', ['p']),
    ]),
    ('lazy_named', {'o': [1, -2]}, [['p', ['I', 'o', P(lazy=['norm1', 'x']), {}]]], [
        ['open', 's'],
        feed('s', '(p.norm1, p.x)', ['p']),
        feed('s', 'p.y'),
        feed('s', "getattr(p, 'y', 'dflt')"),
    ]),
    ('lazy_denied', {'o': [1, 2]}, [['p', ['I', 'o', P(), {}]]], [
        ['open', 's'],
        feed('s', 'p.norm1', ['p']),
        feed('s', "hasattr(p, 'norm1')"),
    ]),
    ('lazy_raises', {'o': [1, 2]}, [['p', ['I', 'o', P(lazy='all'), {}]]], [
        ['open', 's'],
        feed('s', 'p.boom', ['p']),
        feed('s', "getattr(p, 'boom', 5)"),
        feed('s', "try:\n    p.boom\nexcept KeyError as e:\n    r = repr(e)\nr"),
        feed('s', "hasattr(p, 'missing')"),
        feed('s', 'p.missing'),
        feed('s', "getattr(p, '_hidden', 'dflt')"),
    ]),
    ('methods', {'o': [3, 4]}, [['p', ['I', 'o', P(methods=['sum', 'shifted', 'fails']), {}]]], [
        ['open', 's'],
        feed('s', 'p.sum()', ['p']),
        feed('s', 'p.shifted(1, dy=2)'),
        feed('s', 'p.fails()'),
        feed('s', 'p.later()'),
        feed('s', 'p.nope()'),
    ]),
    ('methods_all', {'o': [3, 4]}, [['p', ['I', 'o', P(methods='all'), {}]]], [
        ['open', 's'],
        feed('s', 'p.sum()', ['p']),
        feed('s', 'await p.later()'),
        feed('s', 'import asyncio\nasync def f():\n    return await asyncio.gather(p.later(), p.later())\nawait f()'),
        feed('s', 'p()'),
        feed('s', 'p.describe()'),
    ]),
    ('methods_denied', {'o': [3, 4]}, [['p', ['I', 'o', P(), {}]]], [
        ['open', 's'],
        feed('s', 'p.sum()', ['p']),
    ]),
    ('class_methods', {}, [['T', ['T', P(eager='all', methods='all'), {}]]], [
        ['open', 's'],
        feed('s', '(T.describe(), T.add(2, 3), T.ORIGIN_NAME)', ['T']),
        feed('s', 'T.sum()'),
        feed('s', 'T(1, 2)'),
        feed('s', 'T.nope'),
    ]),
    ('class_construct', {}, [['T', ['T', P(), {'init': True, 'instance': P(eager='all', methods=['sum'])}]]], [
        ['open', 's'],
        feed('s', 'q = T(3, 4)\n(q.x, q.y, q.sum(), type(q) is T)', ['T']),
        feed('s', 'q.norm1'),
        feed('s', 'T(1)'),
    ]),
    ('type_identity', {'o': [1, 2]}, [
        ['T', ['T', P(), {'init': True}]],
        ['p', ['I', 'o', P(eager='all'), {'class': 'T'}]],
    ], [
        ['open', 's'],
        feed('s', '(type(p) is T, type(p).__name__)', ['p', 'T']),
    ]),
    ('class_grant_kept', {'o': [1, 2]}, [
        ['T', ['T', P(), {'init': True, 'instance': P(eager='all')}]],
        ['p', ['I', 'o', P(eager='all'), {'class': 'U'}]],
    ], [
        ['open', 's'],
        feed('s', 'T(5, 6).x', ['T']),
        feed('s', 'p.x', ['p']),
        feed('s', 'T(7, 8).y'),
    ]),
    ('convert_hook', {'o': [1, 2]}, [
        ['T', ['T', P(eager='all'), {'convert': 'redact'}]],
        ['p', ['I', 'o', P(eager=['x', 'y'], lazy=['norm1']), {'class': 'T'}]],
    ], [
        ['open', 's'],
        feed('s', '(p.x, p.y, p.norm1)', ['p']),
    ]),
    ('identity', {'o': [1, 2], 'o2': [5, 6]}, [
        ['p', ['I', 'o', P(eager='all'), {}]],
        ['q', ['I', 'o2', P(), {}]],
    ], [
        ['open', 's'],
        feed('s', 'p', ['p']),
        feed('s', '[p, (p, p)]'),
        feed('s', '(p is p, q)', ['q']),
        feed('s', 'class C:\n    pass\nC()'),
    ]),
    ('rewrap_replaces_policy', {'o': [1, 2]}, [
        ['p', ['I', 'o', P(), {'id': 1}]],
        ['p2', ['I', 'o', P(methods=['sum']), {'id': 1}]],
    ], [
        ['open', 's'],
        feed('s', 'p.sum()', ['p']),
        feed('s', '1', ['p2']),
        feed('s', 'p.sum()'),
    ]),
    ('alias_refused', {'o': [1, 2], 'o2': [3, 4]}, [
        ['p', ['I', 'o', P(eager='all'), {'id': 2}]],
        ['q', ['I', 'o2', P(eager='all'), {'id': 2}]],
    ], [
        ['open', 's'],
        feed('s', 'p.x', ['p']),
        feed('s', 'q.x', ['q']),
        feed('s', 'p.x'),
    ]),
    ('restore_store_empty', {'o': [1, 2]}, [
        ['p', ['I', 'o', P(eager='all', lazy=['norm1'], methods=['sum']), {'id': 3}]],
    ], [
        ['open', 's'],
        feed('s', 'p.sum()', ['p']),
        ['dump', 's'],
        ['open', 't'],
        ['load_session', 't', 's'],
        feed('t', 'p.x'),
        feed('t', 'p.sum()'),
        feed('t', 'p.norm1'),
        feed('t', 'p'),
        feed('s', 'p'),
    ]),
]


def policies(spec: dict[str, Any], prefix: str = '') -> dict[str, Any]:
    return {
        f'{prefix}eager_attrs': spec['eager'],
        f'{prefix}lazy_attrs': spec['lazy'],
        f'{prefix}allowed_methods': spec['methods'],
    }


def build(objects: dict[str, Any], wrappers: list[Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    objs = {name: Point(*xy) for name, xy in objects.items()}
    built: dict[str, Any] = {}
    for name, spec in wrappers:
        opts = spec[-1]
        ident = uuid.UUID(int=opts['id']) if 'id' in opts else None
        if spec[0] == 'T':
            cls = Redact if opts.get('convert') == 'redact' else pm.ClassType
            built[name] = cls(
                Point,
                id=ident,
                init=opts.get('init', False),
                **policies(spec[1]),
                **policies(opts.get('instance', P()), 'instance_'),
            )
        else:
            class_type = built.get(opts['class']) if 'class' in opts else None
            if 'class' in opts and class_type is None:
                class_type = pm.ClassType(Point)
            built[name] = pm.ClassInstance(
                objs[spec[1]],
                **({'id': ident} if ident else {}),
                class_type=class_type,
                **policies(spec[2]),
            )
    return objs, built


def show(v: Any, objs: dict[str, Any]) -> str:
    for name, obj in objs.items():
        if v is obj:
            return f'is:{name}'
    if isinstance(v, pm.MontyClassProxy):
        return f'proxy:{v.name}'
    if isinstance(v, list):
        return '[' + ', '.join(show(x, objs) for x in v) + ']'
    if isinstance(v, tuple):
        inner = ', '.join(show(x, objs) for x in v)
        return f'({inner},)' if len(v) == 1 else f'({inner})'
    return repr(v)


def error_text(e: BaseException) -> str:
    if isinstance(e, pm.MontyError):
        return f'{type(e).__name__}: {e.display("type-msg")}'
    return f'{type(e).__name__}: {e}'


async def run_case(objects, wrappers, steps) -> list[str]:
    objs, built = build(objects, wrappers)
    outcomes = []
    sessions: dict[str, Any] = {}
    contexts: dict[str, Any] = {}
    dumps: dict[str, bytes] = {}
    async with pm.AsyncMonty(max_processes=2) as pool:
        try:
            for step in steps:
                op, name, rest = step[0], step[1], step[2:]
                try:
                    if op == 'open':
                        contexts[name] = pool.checkout()
                        sessions[name] = await contexts[name].__aenter__()
                        outcomes.append('ok')
                    elif op == 'feed':
                        inputs = {n: built[n] for n in rest[1]}
                        value = await sessions[name].feed_run(rest[0], inputs=inputs or None)
                        outcomes.append(f'value: {show(value, objs)}')
                    elif op == 'dump':
                        dumps[name] = await sessions[name].dump()
                        outcomes.append('dumped')
                    elif op == 'load_session':
                        await sessions[name].load_session(dumps[rest[0]])
                        outcomes.append('ok')
                    elif op == 'close':
                        await contexts.pop(name).__aexit__(None, None, None)
                        outcomes.append('ok')
                    else:
                        raise SystemExit(f'unknown step {op}')
                except BaseException as e:  # noqa: BLE001 - the oracle's outcome is the data
                    if isinstance(e, SystemExit):
                        raise
                    outcomes.append(error_text(e))
        finally:
            for context in contexts.values():
                await context.__aexit__(None, None, None)
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
// Upstream's outcome for each host-object case, recorded from
// pydantic-monty 1.1.0 (the oracle) by tool/generate_host_oracle.py, which
// also defines the case language and the host class. The Dart runner is in
// _host_cases.dart.
//
// Generated by tool/generate_host_oracle.py; do not edit by hand.

/// Per case id: the objects, the wrappers, and the steps with their
/// outcomes.
const Map<
  String,
  ({
    Map<String, Object?> objects,
    List<Object?> wrappers,
    List<({List<Object?> step, String outcome})> steps,
  })
>
hostOracle = {
"""


def render(recorded) -> str:
    body = ''.join(
        f'  {dart_str(case_id)}: (objects: {dart_value(objects)}, wrappers: {dart_value(wrappers)}, steps: [\n'
        + ''.join(f'    (step: {dart_value(step)}, outcome: {dart_str(outcome)}),\n' for step, outcome in steps)
        + '  ]),\n'
        for case_id, objects, wrappers, steps in recorded
    )
    text = HEADER + body + '};\n'
    formatted = subprocess.run(
        ['dart', 'format', '--stdin-name', str(OUT)],
        input=text, capture_output=True, text=True, check=True, cwd=ROOT,
    )
    return formatted.stdout


async def record() -> list[Any]:
    out = []
    for case_id, objects, wrappers, steps in CASES:
        outcomes = await run_case(objects, wrappers, steps)
        out.append((case_id, objects, wrappers, list(zip(steps, outcomes))))
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
