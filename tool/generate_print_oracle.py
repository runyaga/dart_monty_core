#!/usr/bin/env python3
"""Record upstream's outcome for each print-sink case into test/unit/worker/_print_oracle.g.dart.

usage: PYTHON -I tool/generate_print_oracle.py [--check]

PYTHON is an interpreter with the pydantic-monty that tool/upstream/requirements.lock pins installed (the oracle).
Each case is one print sink, a collector or a print callback that raises,
used for every step of one checkout of upstream's AsyncMonty with
`print_flush_interval=0`, so each completed line is its own fragment. The
Dart side (test/unit/worker/_print_cases.dart) builds the same sink, a
CollectStreams, a CollectString or a throwing callback, and must reach the
same outcomes on the VM, dart2js and dart2wasm.

A case is (id, sink, steps):
- sink: ['streams', max_bytes] or ['string', max_bytes], a collector
  (max_bytes an int, None, or 'default' for the constructor's default);
  ['raise', exc], a callback that raises exc: ['typed', type, message] (the
  builtin exception type, message None for no argument), ['plain', text]
  (an exception of the host's own class, which upstream sends as
  `Exception`; the Dart side throws an object whose toString() is text),
  ['json', msg, doc, pos] (`json.JSONDecodeError(msg, doc, pos)`; the Dart
  side throws an ExternalException with its message and attributes) or
  ['monty'] (the MontyRuntimeError of an earlier `raise KeyError('k')`);
- steps: ['run', code] (feed_run with the sink); ['bare', code] (feed_run
  without one); ['start', code] (feed_start with the sink); ['resume', n]
  (resumes the name lookup feed_start stopped at with the int n).

An outcome is `value: <repr>`, `lookup <name>` (a suspension), or
`<ErrorClass>: <display('type-msg')>` (for a json case, then ` / ` and the
inner exception's type and attributes), then ` | ` and the collector's repr
(upstream's `__repr__`), or its size when that is long. A callback case has
no collector to show.

--check writes nothing and exits 1 if the committed file differs.
"""

from __future__ import annotations

import asyncio
import builtins
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import pydantic_monty as pm

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'test/unit/worker/_print_oracle.g.dart'

# Upstream's DEFAULT_MAX_PRINT_COLLECT_BYTES, the constructors' default.
DEFAULT_CAP = 10 * 1024 * 1024

# A repr longer than this is shown as its collector's size instead.
SHOWN = 400

MIXED = 'import sys\nprint("a")\nprint("b", file=sys.stderr)\nprint("c", end="")\n7'
UNICODE = 'print("q\'\\"\\\\\\x00\\t\\u00e9\\U0001F600\\u2028")\n1'
# Lines of 11, 101 and 2 bytes; a CollectStreams charges each 64 more.
LINES = 'print("a" * 10)\nprint("b" * 100)\nprint("c")\n5'
BIG = f'print("x" * {DEFAULT_CAP})\n3'
FAIL = 'print("about to fail")\nraise ValueError("boom")'
LOOKUP = 'print("before")\nx = fetch\nprint("after", x)\nx'

CASES: list[tuple[str, list[Any], list[list[Any]]]] = [
    ('streams_mixed', ['streams', 'default'], [['run', MIXED]]),
    ('string_mixed', ['string', 'default'], [['run', MIXED]]),
    ('streams_unicode', ['streams', 'default'], [['run', UNICODE]]),
    ('string_unicode', ['string', 'default'], [['run', UNICODE]]),
    # The cap: equality accepted, one byte more refused whole.
    ('streams_cap_equal', ['streams', 65], [['run', 'print("x", end="")\n2']]),
    ('streams_cap_over', ['streams', 64],
     [['run', 'print("x", end="")\n2'], ['bare', '1 + 1']]),
    ('streams_cap_zero', ['streams', 0], [['run', 'print("x", end="")\n2']]),
    ('string_cap_equal', ['string', 1], [['run', 'print("x", end="")\n2']]),
    ('string_cap_over', ['string', 0],
     [['run', 'print("x", end="")\n2'], ['bare', '1 + 1']]),
    ('string_cap_empty', ['string', 0], [['run', 'print("", end="")\n2']]),
    # An overflow mid-turn: earlier fragments stay, later ones are dropped.
    ('streams_cap_midturn', ['streams', 200], [['run', LINES]]),
    ('string_cap_midturn', ['string', 112], [['run', LINES]]),
    ('streams_multibyte', ['streams', 66], [['run', 'print("\\u00e9", end="")\n2']]),
    ('string_multibyte', ['string', 1], [['run', 'print("\\u00e9", end="")\n2']]),
    # The charge is cumulative across feeds of one collector.
    ('string_cap_across_feeds', ['string', 10],
     [['run', 'print("12345")'], ['run', 'print("6789")'], ['run', 'print("")']]),
    ('streams_cap_across_feeds', ['streams', 140],
     [['run', 'print("12345")'], ['run', 'print("6789")'], ['run', 'print("")']]),
    # The default cap, and none.
    ('streams_default_cap', ['streams', 'default'], [['run', BIG]]),
    ('string_default_cap', ['string', 'default'], [['run', BIG]]),
    ('string_no_cap', ['string', None], [['run', BIG]]),
    ('streams_no_cap', ['streams', None], [['run', BIG]]),
    # Output collected before an error stays.
    ('streams_error_keeps', ['streams', 'default'], [['run', FAIL]]),
    ('string_error_keeps', ['string', 'default'], [['run', FAIL]]),
    # A collector keeps collecting across a suspension.
    ('streams_snapshot', ['streams', 'default'],
     [['start', LOOKUP], ['resume', 10]]),
    ('string_snapshot', ['string', 'default'],
     [['start', LOOKUP], ['resume', 10], ['run', 'print("again")']]),
    # An overflow at a suspension: the session is gone.
    ('string_cap_at_suspension', ['string', 3], [['start', LOOKUP]]),
    # A raising callback: classified as upstream classifies a host exception,
    # raised to the caller, and the session runs on.
    ('raise_value_error', ['raise', ['typed', 'ValueError', 'x']],
     [['run', 'print("a")\n2'], ['bare', '1 + 1']]),
    ('raise_key_error', ['raise', ['typed', 'KeyError', 'k']], [['run', 'print("a")\n2']]),
    ('raise_memory_error', ['raise', ['typed', 'MemoryError', 'm']], [['run', 'print("a")\n2']]),
    ('raise_no_message', ['raise', ['typed', 'RuntimeError', None]], [['run', 'print("a")\n2']]),
    ('raise_syntax_error', ['raise', ['typed', 'SyntaxError', 'bad']], [['run', 'print("a")\n2']]),
    ('raise_syntax_no_message', ['raise', ['typed', 'SyntaxError', None]],
     [['run', 'print("a")\n2']]),
    # A JSONDecodeError keeps its data, a pos past its document too.
    ('raise_json', ['raise', ['json', 'bad', 'ab', 1]], [['run', 'print("a")\n2']]),
    ('raise_json_pos_past_doc', ['raise', ['json', 'bad', '', 1]],
     [['run', 'print("a")\n2']]),
    ('raise_system_exit', ['raise', ['typed', 'SystemExit', '3']], [['run', 'print("a")\n2']]),
    ('raise_plain', ['raise', ['plain', 'host trouble']],
     [['run', 'print("a")\n2'], ['bare', '1 + 1']]),
    ('raise_monty_error', ['raise', ['monty']], [['run', 'print("a")\n2']]),
    # Python cannot catch it, and it wins over the run's own error.
    ('raise_uncatchable', ['raise', ['typed', 'ValueError', 'x']],
     [['run', 'try:\n    print("a")\nexcept BaseException:\n    pass\n2']]),
    ('raise_then_error', ['raise', ['typed', 'ValueError', 'x']],
     [['run', 'print("a")\nraise KeyError("k")']]),
]


class HostError(Exception):
    """An exception class of the host's own, which upstream sends as `Exception`."""


JSON_ATTRS = ('msg', 'doc', 'pos', 'lineno', 'colno')


def inner_text(e: Any) -> str:
    inner = e.exception()
    if isinstance(inner, json.JSONDecodeError):
        attrs = ', '.join(f'{a}={getattr(inner, a)!r}' for a in JSON_ATTRS)
        return f'json.JSONDecodeError({attrs})'
    return type(inner).__name__


def error_text(e: BaseException, sink_spec: list[Any]) -> str:
    if isinstance(e, pm.MontyError):
        text = f'{type(e).__name__}: {e.display("type-msg")}'
        if sink_spec[0] == 'raise' and sink_spec[1][0] == 'json':
            text += f' / {inner_text(e)}'
        return text
    return f'{type(e).__name__}: {e}'


def collector_text(sink: Any) -> str:
    if isinstance(sink, pm.CollectStreams):
        shown = repr(sink)
        if len(shown) <= SHOWN:
            return shown
        out = sink.output
        return f'CollectStreams: {len(out)} entries, {sum(len(t) for _, t in out)} chars'
    if isinstance(sink, pm.CollectString):
        shown = repr(sink)
        if len(shown) <= SHOWN:
            return shown
        return f'CollectString: {len(sink.output)} chars'
    return ''


async def make_sink(spec: list[Any], pool: Any) -> Any:
    kind = spec[0]
    if kind in ('streams', 'string'):
        cls = pm.CollectStreams if kind == 'streams' else pm.CollectString
        return cls() if spec[1] == 'default' else cls(max_bytes=spec[1])
    exc_spec = spec[1]
    if exc_spec[0] == 'typed':
        exc_type = getattr(builtins, exc_spec[1])
        exc = exc_type() if exc_spec[2] is None else exc_type(exc_spec[2])
    elif exc_spec[0] == 'json':
        exc = json.JSONDecodeError(exc_spec[1], exc_spec[2], exc_spec[3])
    elif exc_spec[0] == 'plain':
        exc = HostError(exc_spec[1])
    else:
        async with pool.checkout() as other:
            try:
                await other.feed_run('raise KeyError("k")')
            except pm.MontyRuntimeError as e:
                exc = e
            else:
                raise SystemExit('the earlier run did not raise')

    def callback(stream: str, text: str) -> None:
        raise exc

    return callback


def describe(snapshot: Any) -> str:
    if isinstance(snapshot, pm.MontyComplete):
        return f'value: {snapshot.output!r}'
    if isinstance(snapshot, pm.AsyncNameLookupSnapshot):
        return f'lookup {snapshot.variable_name}'
    raise SystemExit(f'unexpected snapshot {snapshot!r}')


async def run_case(pool: Any, sink_spec: list[Any], steps: list[list[Any]]) -> list[str]:
    sink = await make_sink(sink_spec, pool)
    outcomes = []
    snapshot = None
    async with pool.checkout(print_flush_interval=0) as session:
        for op, arg in steps:
            try:
                if op == 'run':
                    text = f'value: {await session.feed_run(arg, print_callback=sink)!r}'
                elif op == 'bare':
                    text = f'value: {await session.feed_run(arg)!r}'
                elif op == 'start':
                    snapshot = await session.feed_start(arg, print_callback=sink)
                    text = describe(snapshot)
                elif op == 'resume':
                    snapshot = await snapshot.resume(value=arg)
                    text = describe(snapshot)
                else:
                    raise SystemExit(f'unknown step {op}')
            except BaseException as e:  # noqa: BLE001 - the oracle's outcome is the data
                if isinstance(e, SystemExit):
                    raise
                text = error_text(e, sink_spec)
            shown = collector_text(sink)
            outcomes.append(f'{text} | {shown}' if shown else text)
    return outcomes


async def record() -> list[tuple[str, list[Any], list[tuple[list[Any], str]]]]:
    out = []
    async with pm.AsyncMonty(max_processes=2) as pool:
        for case_id, sink, steps in CASES:
            outcomes = await run_case(pool, sink, steps)
            out.append((case_id, sink, list(zip(steps, outcomes))))
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
    if v is None:
        return 'null'
    if isinstance(v, str):
        return dart_str(v)
    if isinstance(v, bool):
        raise SystemExit(f'no bools in cases: {v!r}')
    if isinstance(v, int):
        return str(v)
    if isinstance(v, list):
        return '[' + ', '.join(dart_value(x) for x in v) + ']'
    raise SystemExit(f'cannot render {v!r}')


HEADER = """\
// Upstream's outcome for each print-sink case, recorded from pydantic-monty
// 1.1.0 (the oracle) by tool/generate_print_oracle.py, which also holds the
// Python form of each case and the meaning of each sink and step. The Dart
// form of each is in _print_cases.dart.
//
// An outcome is `value: <repr>`, `lookup <name>` (a suspension) or
// `<ErrorClass>: <display('type-msg')>` (for a json case, then ` / ` and
// the inner exception's type and attributes), then ` | ` and the
// collector's repr, or its size when that is long; a callback case shows no
// collector.
//
// Generated by tool/generate_print_oracle.py; do not edit by hand.

/// Per case id: the sink, and each step with upstream's outcome.
const Map<String, ({List<Object?> sink, List<({List<Object> step, String outcome})> steps})>
printOracle = {
"""


def render(recorded) -> str:
    body = ''.join(
        f'  {dart_str(k)}: (sink: {dart_value(sink)}, steps: [\n'
        + ''.join(f'    (step: {dart_value(step)}, outcome: {dart_str(o)}),\n' for step, o in steps)
        + '  ]),\n'
        for k, sink, steps in recorded
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
