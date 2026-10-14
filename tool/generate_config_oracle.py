#!/usr/bin/env python3
"""Record upstream's outcome for each session-settings case into test/unit/worker/_config_oracle.g.dart.

usage: PYTHON -I tool/generate_config_oracle.py [--check]

PYTHON is an interpreter with pydantic-monty 1.1.0 installed (the oracle).
Each case below is a checkout of upstream's AsyncMonty with one setting, and
upstream's outcome for it: the text of the error the checkout raises, or the
value a snippet returns, or the error a feed raises. The Dart side
(test/unit/worker/_config_cases.dart) builds the same settings as core's
session records, case by case, and must reach the same outcome on the VM,
dart2js and dart2wasm.

Only deterministic outcomes are recorded: frozen clocks, seeded generators,
sleep accounting. The text is passed through `dart format`.

--check writes nothing and exits 1 if the committed file differs.
"""

from __future__ import annotations

import asyncio
import datetime
import math
import subprocess
import sys
from pathlib import Path

import pydantic_monty as pm

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'test/unit/worker/_config_oracle.g.dart'

UTC = datetime.timezone.utc
# 2020-07-02 03:04:05.678 UTC: summer, so a named zone's daylight saving
# shows; whole milliseconds, which is all a DateTime holds on the web.
FROZEN = datetime.datetime(2020, 7, 2, 3, 4, 5, 678000, tzinfo=UTC)

CLOCK = (
    'import datetime, time\n'
    'repr((str(datetime.datetime.now()), datetime.date.today().isoformat(), '
    'time.tzname, time.timezone, time.time(), '
    'datetime.datetime.now().astimezone().strftime("%z %Z")))'
)
RANDOM = 'import random\nrepr((random.random(), random.randint(0, 10**6)))'

# Checkouts upstream refuses: (id, checkout kwargs).
REFUSED = [
    ('limits_negative_memory', {'limits': {'max_memory': -5}}),
    ('limits_negative_gc_interval', {'limits': {'gc_interval': -1}}),
    ('limits_negative_recursion', {'limits': {'max_recursion_depth': -1}}),
    ('limits_negative_suspensions', {'limits': {'max_suspensions': -1}}),
    ('limits_negative_feed', {'limits': {'max_feed_duration_secs': -1.0}}),
    ('limits_negative_turn', {'limits': {'max_turn_duration_secs': -1.0}}),
    ('limits_negative_total_sleep', {'limits': {'max_total_sleep_secs': -1.0}}),
    ('type_check_format_unknown', {'type_check': True, 'type_check_format': 'bogus'}),
    ('assert_annotations_negative', {'assert_message_annotations': -1}),
    ('assert_annotations_too_big', {'assert_message_annotations': 2**32}),
    ('print_flush_negative', {'print_flush_interval': -1.0}),
    ('datetime_unknown', {'os_policy': {'datetime': 'nope'}}),
    ('timezone_unknown', {'os_policy': {'timezone': 'Not/AZone'}}),
    ('timezone_offset_high', {'os_policy': {'timezone': {'offset_seconds': 86400}}}),
    ('timezone_offset_low', {'os_policy': {'timezone': {'offset_seconds': -86400}}}),
    ('sleep_unknown', {'os_policy': {'sleep': 'bad'}}),
    ('sleep_max_negative', {'os_policy': {'sleep_system_max': -1.0}}),
    ('sleep_max_with_zero', {'os_policy': {'sleep': 'zero', 'sleep_system_max': 1.0}}),
    ('sleep_max_with_call_host', {'os_policy': {'sleep': 'call_host', 'sleep_system_max': 1.0}}),
    ('process_time_unknown', {'os_policy': {'process_time': 'x'}}),
    ('random_start_unknown', {'os_policy': {'random_start': 'x'}}),
    ('seed_nan', {'os_policy': {'random_start': {'seed': math.nan}}}),
    ('seed_inf', {'os_policy': {'random_start': {'seed': math.inf}}}),
    ('seed_negative_inf', {'os_policy': {'random_start': {'seed': -math.inf}}}),
]

# Checkouts upstream accepts, and a snippet whose value or error shows the
# setting: (id, checkout kwargs, code).
RUNS = [
    ('type_check_format_upper', {'type_check': True, 'type_check_format': 'JSON'}, 'x: int = "a"'),
    ('type_check_format_dashed', {'type_check': True, 'type_check_format': 'json-lines'}, 'x: int = "a"'),
    ('frozen_utc', {'os_policy': {'datetime': FROZEN}}, CLOCK),
    ('frozen_offset_named',
     {'os_policy': {'datetime': FROZEN, 'timezone': {'offset_seconds': 7200, 'name': 'X'}}}, CLOCK),
    ('frozen_offset_unnamed',
     {'os_policy': {'datetime': FROZEN, 'timezone': {'offset_seconds': -12600}}}, CLOCK),
    ('frozen_aware',
     {'os_policy': {'datetime': FROZEN.astimezone(datetime.timezone(datetime.timedelta(hours=2), 'X'))}},
     CLOCK),
    ('frozen_named_zone', {'os_policy': {'datetime': FROZEN, 'timezone': 'Europe/London'}}, CLOCK),
    ('frozen_zone_utc_upper', {'os_policy': {'datetime': FROZEN, 'timezone': 'UTC'}}, CLOCK),
    ('frozen_zone_utc', {'os_policy': {'datetime': FROZEN, 'timezone': 'utc'}}, CLOCK),
    ('datetime_call_host', {'os_policy': {'datetime': 'call_host'}}, CLOCK),
    ('seed_int', {'os_policy': {'random_start': {'seed': 42}}}, RANDOM),
    ('seed_negative_int', {'os_policy': {'random_start': {'seed': -5}}}, RANDOM),
    ('seed_big_int', {'os_policy': {'random_start': {'seed': 2**70}}}, RANDOM),
    ('seed_float', {'os_policy': {'random_start': {'seed': 1.5}}}, RANDOM),
    ('seed_integral_float', {'os_policy': {'random_start': {'seed': 42.0}}}, RANDOM),
    # Equal to 2**70 as a number, but a float seed hashes differently.
    ('seed_big_float', {'os_policy': {'random_start': {'seed': 2.0**70}}}, RANDOM),
    ('seed_str', {'os_policy': {'random_start': {'seed': 'abc'}}}, RANDOM),
    ('seed_bytes', {'os_policy': {'random_start': {'seed': b'abc'}}}, RANDOM),
    ('random_call_host', {'os_policy': {'random_start': 'call_host'}}, RANDOM),
    ('process_time_zero', {'os_policy': {'process_time': 'zero'}},
     'import time\nsum(range(300000))\nrepr(time.process_time())'),
    ('process_time_elapsed', {'os_policy': {'process_time': 'elapsed'}},
     'import time\nsum(range(300000))\nrepr(time.process_time() > 0)'),
    ('sleep_zero', {'os_policy': {'sleep': 'zero'}, 'limits': {'max_total_sleep_secs': 0.001}},
     'import time\ntime.sleep(30)\nrepr("slept")'),
    ('sleep_call_host', {'os_policy': {'sleep': 'call_host'}}, 'import time\ntime.sleep(30)'),
    ('total_sleep_exceeded', {'limits': {'max_total_sleep_secs': 0.1}},
     'import time\ntime.sleep(0.15)'),
    ('total_sleep_accumulates', {'limits': {'max_total_sleep_secs': 0.1}},
     'import time\ntime.sleep(0.04)\ntime.sleep(0.04)\ntime.sleep(0.04)'),
    ('total_sleep_charges_the_cap',
     {'os_policy': {'sleep_system_max': 0.05}, 'limits': {'max_total_sleep_secs': 0.12}},
     'import time\ntime.sleep(10)\ntime.sleep(10)\ntime.sleep(10)'),
    ('total_sleep_uncapped',
     {'os_policy': {'sleep_system_max': math.inf}, 'limits': {'max_total_sleep_secs': 1.0}},
     'import time\ntime.sleep(5.5)'),
    # Charged in nanoseconds, as upstream's Duration.
    ('total_sleep_sub_micro', {'limits': {'max_total_sleep_secs': 0.000001}},
     'import time\ntime.sleep(0.0000014)'),
    # Uncapped: the charge is the request itself, refused before any wait.
    ('total_sleep_uncapped_huge',
     {'os_policy': {'sleep_system_max': math.inf}, 'limits': {'max_total_sleep_secs': 1.0}},
     'import time\ntime.sleep(9.1e9)'),
    ('total_sleep_uncatchable', {'limits': {'max_total_sleep_secs': 0.01}},
     'import time\ntry:\n    time.sleep(1)\nexcept BaseException:\n    pass\nrepr("caught")'),
    ('recursion_limit', {'limits': {'max_recursion_depth': 20}},
     'def f(n):\n    return f(n + 1)\nf(0)'),
]


async def outcome_of_checkout(pool, kwargs) -> str:
    try:
        async with pool.checkout(**kwargs) as session:
            await session.feed_run('1')
    except BaseException as e:  # noqa: BLE001 - the oracle's outcome is the data
        return f'{type(e).__name__}: {e}'
    raise SystemExit(f'upstream accepted {kwargs}')


async def outcome_of_run(pool, kwargs, code) -> str:
    async with pool.checkout(**kwargs) as session:
        try:
            value = await session.feed_run(code)
        except pm.MontyTypingError as e:
            return f'MontyTypingError: {e.display()}'
        except pm.MontyError as e:
            return f'{type(e).__name__}: {e.display("type-msg")}'
        return f'value: {value}' if isinstance(value, str) else f'value: {value!r}'


async def record() -> list[tuple[str, str | None, str]]:
    out = []
    async with pm.AsyncMonty(max_processes=1) as pool:
        for case_id, kwargs in REFUSED:
            out.append((case_id, None, await outcome_of_checkout(pool, kwargs)))
        for case_id, kwargs, code in RUNS:
            out.append((case_id, code, await outcome_of_run(pool, kwargs, code)))
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
// Upstream's outcome for each session-settings case, recorded from
// pydantic-monty 1.1.0 (the oracle) by tool/generate_config_oracle.py, which
// also holds the Python form of each case. The Dart form of each is in
// _config_cases.dart.
//
// Each case is the code fed after the checkout (null: the checkout itself
// is refused) and upstream's outcome, one of:
// - `<ErrorClass>: <str(error)>` for a checkout or feed upstream refuses
//   (`display('type-msg')` for a MontyError);
// - `value: <the snippet's value>` (each snippet returns a repr).
//
// Generated by tool/generate_config_oracle.py; do not edit by hand.

/// Per case id: the code fed, and upstream's outcome.
const Map<String, ({String? code, String outcome})> configOracle = {
"""


def render(outcomes: list[tuple[str, str | None, str]]) -> str:
    body = ''.join(
        f'  {dart_str(k)}: (code: {"null" if c is None else dart_str(c)}, outcome: {dart_str(v)}),\n'
        for k, c, v in outcomes
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
