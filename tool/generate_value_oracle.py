#!/usr/bin/env python3
"""Record upstream's answers for the value family into test/unit/platform/_value_oracle.g.dart.

usage: PYTHON -I tool/generate_value_oracle.py [--check]

PYTHON is an interpreter with pydantic-monty 1.1.0 installed (the oracle).
The values a host sees are upstream's Python objects, so their equality is
Python's: this records, for each case,

- equality: whether two values are `==` in Python, and, when they are and
  both are hashable, whether their hashes agree (Python's numeric tower:
  `1 == 1.0 == True == 1+0j`, exact int/float comparison, named tuples as
  tuples, `set` and `frozenset` by contents, aware datetimes and times by
  instant, time zones by offset, paths as `PurePosixPath`, and a dict or
  set built with equal keys or members collapsing to one);
- file handles: what `pydantic_monty.MontyFileHandle(path, mode, position=)`
  makes of a mode (the canonical mode and the three flags, or the
  `ValueError` message), and its `repr`;
- paths: `str(PurePosixPath(text))`.

Each value is a spec, a nested list the Dart side builds the same value from
(test/unit/platform/monty_value_oracle_test.dart): ['int', digits],
['bool', b], ['float', text], ['complex', re, im], ['str', s],
['tuple', [specs]], ['namedtuple', name, [fields], [specs]], ['set', [specs]],
['frozenset', [specs]], ['dict', [[k, v], ...]], ['tz', offset, name],
['dt', y, mo, d, h, mi, s, us, offset, name], ['time', h, mi, s, us, offset,
fold], ['path', text]. A float's text is Python's repr, or 'nan', 'inf',
'-inf'.

--check writes nothing and exits 1 if the committed file differs.
"""

from __future__ import annotations

import collections
import datetime as dt
import itertools
import math
import pathlib
import subprocess
import sys
from pathlib import Path
from typing import Any

import pydantic_monty as pm

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'test/unit/platform/_value_oracle.g.dart'

NUMBERS: dict[str, list[Any]] = {
    'false': ['bool', False],
    'true': ['bool', True],
    'int_0': ['int', '0'],
    'int_1': ['int', '1'],
    'int_-1': ['int', '-1'],
    'int_2': ['int', '2'],
    'int_2^53': ['int', str(2**53)],
    'int_2^53+1': ['int', str(2**53 + 1)],
    'int_2^63-1': ['int', str(2**63 - 1)],
    'int_2^64': ['int', str(2**64)],
    'int_2^64+1': ['int', str(2**64 + 1)],
    'int_-2^64': ['int', str(-(2**64))],
    'float_0.0': ['float', '0.0'],
    'float_-0.0': ['float', '-0.0'],
    'float_1.0': ['float', '1.0'],
    'float_-1.0': ['float', '-1.0'],
    'float_1.5': ['float', '1.5'],
    'float_2^53': ['float', repr(float(2**53))],
    'float_2^64': ['float', repr(float(2**64))],
    'float_-2^64': ['float', repr(float(-(2**64)))],
    'float_inf': ['float', 'inf'],
    'float_-inf': ['float', '-inf'],
    'float_nan': ['float', 'nan'],
    'complex_0': ['complex', '0.0', '0.0'],
    'complex_1': ['complex', '1.0', '0.0'],
    'complex_1-0j': ['complex', '1.0', '-0.0'],
    'complex_1.5': ['complex', '1.5', '0.0'],
    'complex_1+1j': ['complex', '1.0', '1.0'],
    'complex_1+2j': ['complex', '1.0', '2.0'],
    'complex_2^64': ['complex', repr(float(2**64)), '0.0'],
    'complex_inf': ['complex', 'inf', '0.0'],
    'complex_nan': ['complex', 'nan', '0.0'],
    'complex_nan_imag': ['complex', '1.0', 'nan'],
}

UTC1 = 3600
OTHER: dict[str, list[Any]] = {
    'str_1': ['str', '1'],
    'tuple_12': ['tuple', [['int', '1'], ['int', '2']]],
    'tuple_1.0_2': ['tuple', [['float', '1.0'], ['int', '2']]],
    'nt_P_xy_12': ['namedtuple', 'P', ['x', 'y'], [['int', '1'], ['int', '2']]],
    'nt_Q_ab_12': ['namedtuple', 'Q', ['a', 'b'], [['int', '1'], ['int', '2']]],
    'nt_P_xy_13': ['namedtuple', 'P', ['x', 'y'], [['int', '1'], ['int', '3']]],
    'list_12': ['list', [['int', '1'], ['int', '2']]],
    'set_1': ['set', [['int', '1']]],
    'set_12': ['set', [['int', '1'], ['int', '2']]],
    'set_1_1.0_true': ['set', [['int', '1'], ['float', '1.0'], ['bool', True]]],
    'frozenset_1': ['frozenset', [['int', '1']]],
    'frozenset_1_complex': ['frozenset', [['int', '1'], ['complex', '1.0', '0.0']]],
    'frozenset_12': ['frozenset', [['int', '1'], ['int', '2']]],
    'dict_four_keys': [
        'dict',
        [
            [['int', '1'], ['str', 'a']],
            [['float', '1.0'], ['str', 'b']],
            [['bool', True], ['str', 'c']],
            [['complex', '1.0', '0.0'], ['str', 'd']],
        ],
    ],
    'dict_1_d': ['dict', [[['int', '1'], ['str', 'd']]]],
    'dict_1_a': ['dict', [[['int', '1'], ['str', 'a']]]],
    'dict_1a_2b': ['dict', [[['int', '1'], ['str', 'a']], [['int', '2'], ['str', 'b']]]],
    'dict_2b_1a': ['dict', [[['int', '2'], ['str', 'b']], [['int', '1'], ['str', 'a']]]],
    'tz_+1h_A': ['tz', UTC1, 'A'],
    'tz_+1h_B': ['tz', UTC1, 'B'],
    'tz_+1h': ['tz', UTC1, None],
    'tz_+2h': ['tz', 2 * UTC1, None],
    'dt_12_+1h': ['dt', 2024, 1, 1, 12, 0, 0, 0, UTC1, None],
    'dt_12_+1h_named': ['dt', 2024, 1, 1, 12, 0, 0, 0, UTC1, 'CET'],
    'dt_11_utc': ['dt', 2024, 1, 1, 11, 0, 0, 0, 0, None],
    'dt_11_utc_us': ['dt', 2024, 1, 1, 11, 0, 0, 1, 0, None],
    'dt_12_utc': ['dt', 2024, 1, 1, 12, 0, 0, 0, 0, None],
    'dt_12_naive': ['dt', 2024, 1, 1, 12, 0, 0, 0, None, None],
    'dt_11_naive': ['dt', 2024, 1, 1, 11, 0, 0, 0, None, None],
    'dt_2_+5h_next_day': ['dt', 2024, 1, 2, 2, 0, 0, 0, 5 * UTC1, None],
    'dt_21_utc': ['dt', 2024, 1, 1, 21, 0, 0, 0, 0, None],
    'time_1': ['time', 1, 0, 0, 0, None, 0],
    'time_1_fold': ['time', 1, 0, 0, 0, None, 1],
    'time_12_+1h': ['time', 12, 0, 0, 0, UTC1, 0],
    'time_11_utc': ['time', 11, 0, 0, 0, 0, 0],
    'time_12_naive': ['time', 12, 0, 0, 0, None, 0],
    'path_a//b': ['path', 'a//b'],
    'path_a/b': ['path', 'a/b'],
    'path_./a/': ['path', './a/'],
    'path_a': ['path', 'a'],
    'path_//a': ['path', '//a'],
    'path_/a': ['path', '/a'],
    'path_///a': ['path', '///a'],
}

# The pairs outside the numbers, whose every pair is recorded.
OTHER_PAIRS = [
    ('tuple_12', 'nt_P_xy_12'),
    ('nt_P_xy_12', 'nt_Q_ab_12'),
    ('nt_P_xy_12', 'nt_P_xy_13'),
    ('tuple_1.0_2', 'nt_Q_ab_12'),
    ('list_12', 'tuple_12'),
    ('set_1', 'frozenset_1'),
    ('set_12', 'frozenset_1'),
    ('set_1_1.0_true', 'set_1'),
    ('set_1_1.0_true', 'frozenset_1'),
    ('frozenset_1_complex', 'frozenset_1'),
    ('frozenset_12', 'set_12'),
    ('dict_four_keys', 'dict_1_d'),
    ('dict_four_keys', 'dict_1_a'),
    ('dict_1a_2b', 'dict_2b_1a'),
    ('dict_1_a', 'dict_1_d'),
    ('tz_+1h_A', 'tz_+1h_B'),
    ('tz_+1h_A', 'tz_+1h'),
    ('tz_+1h', 'tz_+2h'),
    ('dt_12_+1h', 'dt_11_utc'),
    ('dt_12_+1h_named', 'dt_11_utc'),
    ('dt_12_+1h', 'dt_11_utc_us'),
    ('dt_12_+1h', 'dt_12_utc'),
    ('dt_12_naive', 'dt_12_utc'),
    ('dt_12_naive', 'dt_12_+1h'),
    ('dt_12_naive', 'dt_11_naive'),
    ('dt_2_+5h_next_day', 'dt_21_utc'),
    ('time_1', 'time_1_fold'),
    ('time_12_+1h', 'time_11_utc'),
    ('time_12_naive', 'time_11_utc'),
    ('time_12_naive', 'time_12_+1h'),
    ('path_a//b', 'path_a/b'),
    ('path_./a/', 'path_a'),
    ('path_//a', 'path_/a'),
    ('path_///a', 'path_/a'),
    ('int_1', 'str_1'),
]

# Modes for MontyFileHandle, valid and not.
MODES = [
    'r', 'rb', 'rt', 'tr', 'br', 'w', 'wb', 'wt', 'a', 'ab', 'at', 'bw',
    '', 'b', 't', 'z', 'rr', 'rw', 'rwb', 'x', 'xb', 'r+', 'rb+', 'w+', 'a+',
    'bb', 'tt', 'bt', 'rbt', 'é', "'", '"', '\\', '\n', '\x00', ' r', 'R',
]

# Paths for the repr, as upstream's StringRepr quotes them.
REPR_PATHS = ['/x', "/a'b", '/a"b', '/a\'"b', '/a\\b', '/a\nb', '/a\tb', '/é', '/\x7f', '/\x01', '']


def float_of(text: str) -> float:
    return float(text)


def build(spec: list[Any]) -> Any:
    kind = spec[0]
    if kind == 'bool':
        return spec[1]
    if kind == 'int':
        return int(spec[1])
    if kind == 'float':
        return float_of(spec[1])
    if kind == 'complex':
        return complex(float_of(spec[1]), float_of(spec[2]))
    if kind == 'str':
        return spec[1]
    if kind == 'tuple':
        return tuple(build(s) for s in spec[1])
    if kind == 'list':
        return [build(s) for s in spec[1]]
    if kind == 'namedtuple':
        return collections.namedtuple(spec[1], spec[2])(*(build(s) for s in spec[3]))
    if kind == 'set':
        return {build(s) for s in spec[1]}
    if kind == 'frozenset':
        return frozenset(build(s) for s in spec[1])
    if kind == 'dict':
        return {build(k): build(v) for k, v in spec[1]}
    if kind == 'tz':
        return dt.timezone(dt.timedelta(seconds=spec[1]), *([spec[2]] if spec[2] is not None else []))
    if kind == 'dt':
        y, mo, d, h, mi, s, us, off, name = spec[1:]
        tz = None if off is None else dt.timezone(dt.timedelta(seconds=off), *([name] if name else []))
        return dt.datetime(y, mo, d, h, mi, s, us, tzinfo=tz)
    if kind == 'time':
        h, mi, s, us, off, fold = spec[1:]
        tz = None if off is None else dt.timezone(dt.timedelta(seconds=off))
        return dt.time(h, mi, s, us, tzinfo=tz, fold=fold)
    if kind == 'path':
        return pathlib.PurePosixPath(spec[1])
    raise ValueError(kind)


def hashable(v: Any) -> bool:
    try:
        hash(v)
    except TypeError:
        return False
    return True


def relation(a: Any, b: Any) -> str:
    """'eq+hash', 'eq', or 'ne': Python's == and, when equal and hashable, whether hashes agree."""
    if a == b:
        if hashable(a) and hashable(b):
            return 'eq+hash' if hash(a) == hash(b) else 'eq-nohash'
        return 'eq'
    return 'ne'


def equalities() -> list[tuple[str, str, str]]:
    out = []
    for x, y in itertools.combinations_with_replacement(NUMBERS, 2):
        out.append((x, y, relation(build(NUMBERS[x]), build(NUMBERS[y]))))
    specs = {**NUMBERS, **OTHER}
    for x, y in OTHER_PAIRS:
        out.append((x, y, relation(build(specs[x]), build(specs[y]))))
    return out


def file_modes() -> list[tuple[str, str]]:
    out = []
    for mode in MODES:
        try:
            h = pm.MontyFileHandle('/x', mode)
        except ValueError as e:
            out.append((mode, f'ValueError: {e}'))
            continue
        out.append((mode, f'mode={h.mode} binary={h.binary} readable={h.readable} writable={h.writable}'))
    return out


def file_reprs() -> list[tuple[str, str]]:
    return [(p, repr(pm.MontyFileHandle(p, 'rb', position=2**64 - 1))) for p in REPR_PATHS]


def file_positions() -> list[tuple[str, str]]:
    out = []
    for text in ['0', '1', str(2**53 + 1), str(2**64 - 1), '-1', str(2**64)]:
        try:
            out.append((text, f'position={pm.MontyFileHandle("/x", "r", position=int(text)).position}'))
        except OverflowError as e:
            out.append((text, f'OverflowError: {e}'))
    return out


PATH_TEXTS = ['', '.', './', 'a', 'a/', 'a//b', 'a/./b', 'a/../b', '/', '//', '///', '//a', '///a//b/', './a/./', '/./a']


def paths() -> list[tuple[str, str]]:
    return [(p, str(pathlib.PurePosixPath(p))) for p in PATH_TEXTS]


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
        elif o < 0x20 or o == 0x7F or o > 0x7E:
            out.append(f'\\u{{{o:x}}}')
        else:
            out.append(ch)
    out.append("'")
    return ''.join(out)


def dart_lit(v: Any) -> str:
    if v is None:
        return 'null'
    if v is True:
        return 'true'
    if v is False:
        return 'false'
    if isinstance(v, int):
        return str(v)
    if isinstance(v, str):
        return dart_str(v)
    if isinstance(v, list):
        return '[' + ', '.join(dart_lit(x) for x in v) + ']'
    raise TypeError(v)


HEADER = """\
// Upstream's answers for the value family, recorded from pydantic-monty 1.1.0
// (the oracle) by tool/generate_value_oracle.py, which also documents the
// spec form each value is written in. The Dart side builds each spec in
// monty_value_oracle_test.dart.
//
// Generated by tool/generate_value_oracle.py; do not edit by hand.

/// Each value's spec, by name.
const Map<String, List<Object?>> valueSpecs = {
"""


def render() -> str:
    specs = ''.join(f'  {dart_str(k)}: {dart_lit(v)},\n' for k, v in {**NUMBERS, **OTHER}.items())
    eqs = ''.join(f'  ({dart_str(a)}, {dart_str(b)}, {dart_str(r)}),\n' for a, b, r in equalities())
    modes = ''.join(f'  {dart_str(m)}: {dart_str(o)},\n' for m, o in file_modes())
    reprs = ''.join(f'  {dart_str(p)}: {dart_str(o)},\n' for p, o in file_reprs())
    positions = ''.join(f'  {dart_str(p)}: {dart_str(o)},\n' for p, o in file_positions())
    ps = ''.join(f'  {dart_str(p)}: {dart_str(o)},\n' for p, o in paths())
    text = (
        HEADER
        + specs
        + '};\n\n'
        + "/// (a, b, Python's relation): 'eq+hash' (equal, hashes agree), 'eq'\n"
        + "/// (equal, one side unhashable) or 'ne'.\n"
        + 'const List<(String, String, String)> valueEqualities = [\n'
        + eqs
        + '];\n\n'
        + "/// `MontyFileHandle('/x', mode)`: the canonical mode and flags, or the\n"
        + '/// ValueError.\n'
        + 'const Map<String, String> fileModeOracle = {\n'
        + modes
        + '};\n\n'
        + "/// `repr(MontyFileHandle(path, 'rb', position=2**64-1))` by path.\n"
        + 'const Map<String, String> fileReprOracle = {\n'
        + reprs
        + '};\n\n'
        + '/// `MontyFileHandle(\'/x\', \'r\', position=n).position`, or the error, by n.\n'
        + 'const Map<String, String> filePositionOracle = {\n'
        + positions
        + '};\n\n'
        + '/// `str(PurePosixPath(text))` by text.\n'
        + 'const Map<String, String> pathOracle = {\n'
        + ps
        + '};\n'
    )
    formatted = subprocess.run(
        ['dart', 'format', '--stdin-name', str(OUT)],
        input=text,
        capture_output=True,
        text=True,
        check=True,
        cwd=ROOT,
    )
    return formatted.stdout


def main() -> int:
    check = '--check' in sys.argv[1:]
    # NaN is the one float whose Python == is not reflexive; record it as is.
    assert math.isnan(build(NUMBERS['float_nan']))
    text = render()
    if check:
        if not OUT.exists() or OUT.read_text() != text:
            print(f'{OUT.relative_to(ROOT)} differs from the oracle', file=sys.stderr)
            return 1
        return 0
    OUT.write_text(text)
    return 0


if __name__ == '__main__':
    sys.exit(main())
