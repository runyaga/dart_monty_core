#!/usr/bin/env python3
"""Record upstream's members of the worker classes into test/unit/worker/_worker_class_oracle.g.dart.

usage: PYTHON -I tool/generate_worker_class_oracle.py [--check]

PYTHON is an interpreter with pydantic-monty 1.1.0 installed (the oracle).
Each case reads one member of an upstream class that core mirrors in
lib/src/worker/: `ExternalReturnValue` equality, `FunctionSnapshot.kwargs`
and `.args`, `SourceRange`'s constructor, and `str()` of a traceback's
`Frame`. The Dart side (monty_snapshot_test.dart, monty_error_test.dart)
builds the same values on core and must reach the same outcomes on the VM,
dart2js and dart2wasm.

An outcome is `value: <repr>` or `<ErrorClass>: <str(error)>`. A frame is
recorded as its fields and its `str()`.

--check writes nothing and exits 1 if the committed file differs.
"""

from __future__ import annotations

import asyncio
import subprocess
import sys
from pathlib import Path
from typing import Any, Callable

import pydantic_monty as pm

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'test/unit/worker/_worker_class_oracle.g.dart'

# The call every snapshot case suspends on; the Dart side's scripted worker
# sends the same call.
CALL = 'f(1, a=2, b=3)'

# The snippet every MontyComplete case completes with.
COMPLETE = '[1, 2]'

# The traceback every frame case reads.
RAISES = 'def g():\n    1/0\ng()'

# A hand-built range keeps its file name: 200 two-byte characters, 400 bytes,
# past the 256 a decoded range is cut to.
LONG_NAME = 'é' * 200

U32_MAX = 2**32 - 1


def outcome(f: Callable[[], Any]) -> str:
    try:
        return f'value: {f()!r}'
    except Exception as e:  # noqa: BLE001 - the oracle's outcome is the data
        return f'{type(e).__name__}: {e}'


def source_range(start: int, end: int) -> Callable[[], Any]:
    return lambda: pm.SourceRange(filename='f', start=start, end=end)


def plain_cases() -> list[tuple[str, str]]:
    erv = pm.ExternalReturnValue
    return [
        ('return_value_equal', outcome(lambda: erv(return_value=1) == erv(return_value=1))),
        ('return_value_unequal', outcome(lambda: erv(return_value=1) == erv(return_value=2))),
        ('range_start_negative', outcome(source_range(-1, 0))),
        ('range_end_negative', outcome(source_range(0, -1))),
        ('range_start_too_large', outcome(source_range(U32_MAX + 1, 0))),
        ('range_end_too_large', outcome(source_range(0, U32_MAX + 1))),
        ('range_u32_max', outcome(source_range(U32_MAX, U32_MAX))),
        ('range_reversed', outcome(source_range(5, 1))),
        (
            'range_long_filename_bytes',
            outcome(lambda: len(pm.SourceRange(filename=LONG_NAME, start=0, end=0).filename.encode())),
        ),
    ]


async def snapshot_cases() -> list[tuple[str, str]]:
    out = []
    async with pm.AsyncMonty(max_processes=1) as pool:
        async with pool.checkout() as s:
            snap = await s.feed_start(CALL)
            out.append(('kwargs_same_object', outcome(lambda: snap.kwargs is snap.kwargs)))
            out.append(('kwargs', outcome(lambda: dict(snap.kwargs))))

            def set_c() -> Any:
                snap.kwargs['c'] = 4
                return dict(snap.kwargs)

            out.append(('kwargs_after_set', outcome(set_c)))

            def del_a() -> Any:
                del snap.kwargs['a']
                return dict(snap.kwargs)

            out.append(('kwargs_after_del', outcome(del_a)))
            out.append(('args_same_object', outcome(lambda: snap.args is snap.args)))

            def set_arg() -> Any:
                snap.args[0] = 9  # a tuple

            out.append(('args_set', outcome(set_arg)))
            await snap.resume(pm.ExternalReturnValue(return_value=None))
            # MontyComplete: output converted on each access, identity
            # equality (snapshot.rs:1360-1379).
            done = await s.feed_start(COMPLETE)
            again = await s.feed_start(COMPLETE)
            out.append(('complete_repr', outcome(lambda: done)))
            out.append(('complete_output_same_object', outcome(lambda: done.output is done.output)))
            out.append(('complete_output_equal', outcome(lambda: done.output == done.output)))
            out.append(('complete_equal_self', outcome(lambda: done == done)))
            out.append(('complete_equal_other', outcome(lambda: done == again)))
    return out


async def frames() -> list[dict[str, Any]]:
    async with pm.AsyncMonty(max_processes=1) as pool:
        async with pool.checkout() as s:
            try:
                await s.feed_run(RAISES)
            except pm.MontyRuntimeError as e:
                return [
                    {
                        'filename': f.filename,
                        'line': f.line,
                        'column': f.column,
                        'endLine': f.end_line,
                        'endColumn': f.end_column,
                        'functionName': f.function_name,
                        'str': str(f),
                    }
                    for f in e.traceback()
                ]
    raise SystemExit(f'{RAISES!r} did not raise')


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


def dart_field(v: Any) -> str:
    if v is None:
        return 'null'
    if isinstance(v, int):
        return repr(v)
    return dart_str(v)


HEADER = f"""// Upstream's members of the worker classes, recorded from pydantic-monty
// 1.1.0 (the oracle) by tool/generate_worker_class_oracle.py, which holds the
// Python form of each case.
//
// An outcome is `value: <repr>` or `<ErrorClass>: <str(error)>`. The
// snapshot cases read the suspension of {dart_str(CALL)[1:-1]}; the frames are the
// traceback of {dart_str(RAISES)[1:-1]}.
//
// Generated by tool/generate_worker_class_oracle.py; do not edit by hand.

/// Per case id: upstream's outcome.
const Map<String, String> workerClassOracle = {{
"""

FRAMES_HEADER = """

/// The frames of upstream's traceback, innermost last, with `str()` of each.
const List<
  ({
    String filename,
    int line,
    int column,
    int endLine,
    int endColumn,
    String? functionName,
    String str,
  })
>
workerClassFrames = [
"""


async def record() -> tuple[list[tuple[str, str]], list[dict[str, Any]]]:
    return plain_cases() + await snapshot_cases(), await frames()


def render(recorded) -> str:
    cases, frame_list = recorded
    body = ''.join(f'  {dart_str(k)}: {dart_str(v)},\n' for k, v in cases)
    frame_body = ''.join(
        '  (' + ', '.join(f'{k}: {dart_field(v)}' for k, v in f.items()) + '),\n' for f in frame_list
    )
    text = HEADER + body + '};\n' + FRAMES_HEADER + frame_body + '];\n'
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
