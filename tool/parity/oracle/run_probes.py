#!/usr/bin/env python3
"""Reference probes: API-level parity probes through upstream pydantic/monty 1.1.0.

usage: python -I tool/parity/oracle/run_probes.py OUTDIR

Probes cover what a single feed-and-compare case cannot: suspensions resumed by
hand, futures, async host functions, feeding while suspended, mounts and
callback files, session forks, the type checker. Each probe writes
OUTDIR/<probe>/ref-py.json = {probe, engine, backend, events, runner_error};
packages/monty_parity/lib/src/api_probes.dart emits the same events through
dart_monty_core, and tool/parity/probes_compare.py compares the two.

Event vocabulary: suspend{kind,name,args,kwargs,position,pending},
complete{value}, error{type,message,tb_last}, refused{}, handler{who,args},
unsupported{what}, plus probe-specific observation events.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import sys
import tempfile
import traceback
import uuid
from pathlib import Path, PurePosixPath
from typing import Any

import pydantic_monty as pm

sys.path.insert(0, str(Path(__file__).resolve().parent))
from run_cases import canon, stable  # noqa: E402


def pos(s: Any) -> Any:
    return s.position.dict() if hasattr(s, 'position') else None


def ev_of(s: Any) -> dict[str, Any]:
    if isinstance(s, pm.MontyComplete):
        return {'ev': 'complete', 'value': canon(s.output)}
    if isinstance(s, pm.FunctionSnapshot):
        return {
            'ev': 'suspend',
            'kind': 'os' if s.is_os_function else 'function',
            'name': str(s.function_name),
            'args': [canon(a) for a in s.args],
            'kwargs': {k: canon(v) for k, v in s.kwargs.items()},
            'position': pos(s),
        }
    if isinstance(s, pm.NameLookupSnapshot):
        return {'ev': 'suspend', 'kind': 'name', 'name': s.variable_name, 'position': pos(s)}
    if isinstance(s, pm.FutureSnapshot):
        return {'ev': 'suspend', 'kind': 'future', 'pending': list(s.pending_call_ids), 'position': pos(s)}
    return {'ev': 'other', 'repr': repr(s)}


def err_ev(e: BaseException) -> dict[str, Any]:
    if isinstance(e, (pm.MontyRuntimeError, pm.MontySyntaxError)):
        msg = e.display('msg')
        tm = e.display('type-msg')
        typ = tm[: -(len(msg) + 2)] if msg and tm.endswith(': ' + msg) else tm.split(':', 1)[0]
        tb = e.traceback()
        last = tb[-1].dict() if tb else None
        return {
            'ev': 'error',
            'type': typ,
            'message': msg,
            'tb_last': None if last is None else {'line': last.get('line'), 'function': last.get('function_name')},
        }
    return {'ev': 'refused', 'cls': type(e).__name__, 'msg': str(e)}


def exc_obs(e: BaseException) -> dict[str, Any]:
    """An exception as type + message (the Python exception inside a pydantic_monty error)."""
    inner = e.exception() if isinstance(e, pm.MontyError) else e
    return {'type': type(inner).__name__, 'message': str(inner)}


class T:
    """Transcript recorder."""

    def __init__(self) -> None:
        self.events: list[dict[str, Any]] = []

    def add(self, e: dict[str, Any]) -> None:
        self.events.append(e)

    def step(self, fn: Any) -> Any:
        try:
            s = fn()
        except Exception as e:  # noqa: BLE001 - recorded
            self.add(err_ev(e))
            return None
        self.add(ev_of(s))
        return s


PROBES: dict[str, Any] = {}


def probe(fn: Any) -> Any:
    PROBES[fn.__name__] = fn
    return fn


# ------------------------------------------------------- suspensions (kinds, positions)
@probe
def k_function(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        x = t.step(lambda: s.feed_start("g = 1\ny = f(2, k='é')\ny"))
        t.step(lambda: x.resume({'return_value': 5}))


@probe
def k_os(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        x = t.step(lambda: s.feed_start("from pathlib import Path\nPath('/x').read_text()"))
        t.step(lambda: x.resume({'return_value': 'hi'}))


@probe
def k_os_not_handled(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        x = t.step(lambda: s.feed_start("from pathlib import Path\nPath('/x').read_text()"))
        t.step(lambda: x.resume_not_handled())


@probe
def k_name(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        x = t.step(lambda: s.feed_start('total = 1 + missing\ntotal'))
        t.step(lambda: x.resume(value=41))


@probe
def k_future(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        x = t.step(lambda: s.feed_start('async def m():\n    a = await f(1)\n    return a + 1\nawait m()'))
        y = t.step(lambda: x.resume({'future': ...}))
        t.step(lambda: y.resume({y.pending_call_ids[0]: {'return_value': 9}}))


@probe
def pos_utf8(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        t.step(lambda: s.feed_start("x = 'é'\ny = add(x, 2)"))


@probe
def pos_earlier_feed(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        s.feed_run('def helper(n):\n    return fetch(n)')
        t.step(lambda: s.feed_start('helper(3)'))


@probe
def pos_eval(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        t.step(lambda: s.feed_start("eval('  1 + fetch()')"))


@probe
def inputs_typed(pool: pm.Monty, t: T) -> None:
    shared = [1]
    with pool.checkout() as s:
        x = t.step(lambda: s.feed_start('f(b, n, s)\n', inputs={'b': b'\x00\xff', 'n': 2**70, 's': [shared, shared]}))
        t.step(lambda: x.resume({'return_value': None}))


@probe
def auto_interleave(pool: pm.Monty, t: T) -> None:
    def ha(n: int) -> int:
        t.add({'ev': 'handler', 'who': 'A', 'args': [canon(n)]})
        return n * 10

    def hb(n: int) -> int:
        t.add({'ev': 'handler', 'who': 'B', 'args': [canon(n)]})
        return n * 100

    with pool.checkout() as s1, pool.checkout() as s2:
        code = 'r = [h(1), h(2)]\nr'
        a = t.step(lambda: s1.feed_start(code, external_lookup={'h': ha}))
        b = t.step(lambda: s2.feed_start(code, external_lookup={'h': hb}))
        a2 = t.step(a.resume_auto)
        t.step(a.resume_auto)  # consumed: must refuse before the handler runs
        b2 = t.step(b.resume_auto)
        t.step(lambda: a2.resume({'return_value': 7}))  # manual step after auto
        while b2 is not None and not isinstance(b2, pm.MontyComplete):
            b2 = t.step(b2.resume_auto)


@probe
def async_gather(pool: pm.Monty, t: T) -> None:
    async def main() -> None:
        async def af(n: int) -> int:
            t.add({'ev': 'handler', 'who': 'af', 'args': [canon(n)]})
            await asyncio.sleep(0.01 * (3 - n))
            return n * 10

        async with pm.AsyncMonty() as apool, apool.checkout() as s:
            try:
                v = await s.feed_run('import asyncio\nawait asyncio.gather(af(1), af(2))', external_lookup={'af': af})
                t.add({'ev': 'complete', 'value': canon(v)})
            except Exception as e:  # noqa: BLE001
                t.add(err_ev(e))

    asyncio.run(main())


@probe
def abortctl_future(pool: pm.Monty, t: T) -> None:
    """A pending future resolved with an ordinary (catchable) error, then the session continues."""
    code = 'async def m():\n    try:\n        return await f(1)\n    except BaseException as e:\n        return "caught"\nawait m()'
    with pool.checkout() as s:
        s.feed_run('g = 1')
        x = t.step(lambda: s.feed_start(code))
        x = t.step(lambda: x.resume({'future': ...}))
        t.step(lambda: x.resume({x.pending_call_ids[0]: {'exc_type': 'RuntimeError', 'message': 'aborted'}}))
        t.step(lambda: s.feed_start('g'))


@probe
def abandon(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        x = t.step(lambda: s.feed_start('g = 2\nf(1)'))
        t.step(lambda: s.feed_start('g'))  # feed while suspended
        t.step(lambda: x.resume({'return_value': 5}))  # the suspension survived
        t.step(lambda: s.feed_start('g'))


# ------------------------------------------------------- API surface
@probe
def api_run_blocking(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        t.add({'ev': 'complete', 'value': canon(s.feed_run('x * 2', inputs={'x': 21}))})
        try:
            s.feed_run('1 / 0')
        except pm.MontyError as e:
            t.add({'ev': 'error', **exc_obs(e)})
    with pool.checkout() as s:
        t.add({'ev': 'complete', 'value': canon(s.feed_run('x * 2', inputs={'x': 21}))})


@probe
def api_start_program(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        snap = s.feed_start('y = fetch(1, k=2)\ny + 1')
        t.add({'ev': 'suspend', 'name': str(snap.function_name), 'args': [canon(a) for a in snap.args],
               'kwargs': {k: canon(v) for k, v in snap.kwargs.items()}})
        t.add({'ev': 'complete', 'value': canon(snap.resume({'return_value': 10}).output)})


@probe
def api_create_repl(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        s.feed_run('x = 41\ndef inc(v):\n    return v + 1')
        t.add({'ev': 'complete', 'value': canon(s.feed_run('inc(x)'))})


@probe
def api_recover_repl_after_error(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        s.feed_run('x = 1')
        for code in ('1 / 0', 'def r():\n    return r()\nr()', 'x = (', 'undefined_name'):
            try:
                s.feed_run(code)
                t.add({'ev': 'no_error', 'code': code})
            except pm.MontyError as e:
                t.add({'ev': 'error', 'code': code, **exc_obs(e), 'after': canon(s.feed_run('x + 1'))})


EXT_RESULT_CODE = ('try:\n    r = f()\nexcept ValueError as e:\n    r = "caught ValueError: " + str(e)\n'
                   'except NameError as e:\n    r = "caught NameError: " + str(e)\nr')


@probe
def api_ext_result_resume(pool: pm.Monty, t: T) -> None:
    """Low-level resume paths: a value, an exception, a future, not-found."""
    with pool.checkout() as s:
        t.add({'ev': 'complete', 'value': canon(s.feed_start(EXT_RESULT_CODE).resume({'return_value': 5}).output)})
        t.add({'ev': 'complete', 'value': canon(
            s.feed_start(EXT_RESULT_CODE).resume({'exc_type': 'ValueError', 'message': 'bad'}).output)})
        snap = s.feed_start('r = await f()\nr')
        fut = snap.resume({'future': ...})
        t.add({'ev': 'complete', 'value': canon(fut.resume({snap.call_id: {'return_value': 7}}).output)})
        t.add({'ev': 'complete', 'value': canon(s.feed_start(EXT_RESULT_CODE, external_lookup={}).resume_auto().output)})


@probe
def api_ext_result_callback(pool: pm.Monty, t: T) -> None:
    """A host callback that raises ValueError: the guest sees ValueError."""
    def boom(*a: Any, **k: Any) -> Any:
        raise ValueError('bad')

    with pool.checkout() as s:
        try:
            t.add({'ev': 'complete', 'value': canon(s.feed_run(EXT_RESULT_CODE, external_lookup={'f': boom}))})
        except pm.MontyError as e:
            t.add({'ev': 'error', **exc_obs(e)})


EXT_ARGS_CODE = "a = [1]\nf(1, 'a', a, a, k=3, m={'x': 1.5}, n=None)"


@probe
def api_ext_args_values(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        snap = s.feed_start(EXT_ARGS_CODE)
        t.add({'ev': 'suspend', 'name': str(snap.function_name),
               'args': [canon(a) for a in snap.args], 'kwargs': {k: canon(v) for k, v in snap.kwargs.items()}})
        snap.resume({'return_value': None})


@probe
def api_ext_args_identity(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        snap = s.feed_start(EXT_ARGS_CODE)
        t.add({'ev': 'identity', 'shared': snap.args[2] is snap.args[3]})
        snap.resume({'return_value': None})


@probe
def api_futures_gather(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        snap = s.feed_start('import asyncio\nr = await asyncio.gather(f(1), f(2))\nr')
        ids = []
        while isinstance(snap, pm.FunctionSnapshot):
            ids.append(snap.call_id)
            snap = snap.resume({'future': ...})
        t.add({'ev': 'pending', 'count': len(snap.pending_call_ids)})
        t.add({'ev': 'complete', 'value': canon(
            snap.resume({ids[0]: {'return_value': 10}, ids[1]: {'return_value': 20}}).output)})


@probe
def api_futures_error(pool: pm.Monty, t: T) -> None:
    code = ('try:\n    r = await f(1)\nexcept ValueError as e:\n    r = "caught ValueError: " + str(e)\n'
            'except RuntimeError as e:\n    r = "caught RuntimeError: " + str(e)\nr')
    with pool.checkout() as s:
        snap = s.feed_start(code)
        cid = snap.call_id
        fut = snap.resume({'future': ...})
        t.add({'ev': 'complete', 'value': canon(fut.resume({cid: {'exc_type': 'ValueError', 'message': 'boom'}}).output)})


W_CODE = ("from pathlib import Path\nres = []\nfor n in ('a', 'b'):\n    try:\n"
          "        Path('/data/' + n + '.txt').write_text('xxxxxx')\n        res.append('ok')\n"
          "    except Exception as e:\n        res.append(type(e).__name__ + ': ' + str(e))\nres")
M_CODE = ("from pathlib import Path\nres = []\ndef w(n):\n    try:\n"
          "        Path('/data/' + n).write_text('y' * 300)\n        res.append('ok')\n"
          "    except Exception as e:\n        res.append(type(e).__name__ + ': ' + str(e))\n"
          "w('a')\nw('b')\nw('c')\nw('d')\ntry:\n    Path('/data/a').unlink()\n    res.append('unlinked')\n"
          "except Exception as e:\n    res.append(type(e).__name__ + ': ' + str(e))\nw('d')\nres")


def _write_budget(pool: pm.Monty, t: T, feed: int) -> None:
    with tempfile.TemporaryDirectory() as d, \
            pm.MountDir(host_path=Path(d), virtual_path='/data', write_bytes_limit=10) as m, pool.checkout() as s:
        for n in (1, 2):
            v = s.feed_run(W_CODE, mount=m)
            if n == feed:
                t.add({'ev': 'complete', 'value': canon(v)})


@probe
def api_write_budget_feed1(pool: pm.Monty, t: T) -> None:
    _write_budget(pool, t, 1)


@probe
def api_write_budget_feed2(pool: pm.Monty, t: T) -> None:
    _write_budget(pool, t, 2)


@probe
def api_memory_budget(pool: pm.Monty, t: T) -> None:
    with tempfile.TemporaryDirectory() as d, \
            pm.MountDir(host_path=Path(d), virtual_path='/data', memory_usage_limit=1000) as m, pool.checkout() as s:
        t.add({'ev': 'complete', 'value': canon(s.feed_run(M_CODE, mount=m))})


@probe
def api_callback_files(pool: pm.Monty, t: T) -> None:
    store = {'v': 'initial'}

    def rd(p: PurePosixPath) -> str:
        t.add({'ev': 'host', 'op': 'read', 'path': str(p)})
        return store['v']

    def wr(p: PurePosixPath, c: object) -> None:
        t.add({'ev': 'host', 'op': 'write', 'path': str(p), 'type': type(c).__name__, 'text': c})
        store['v'] = 'callback-saw:' + str(c)

    fs = pm.OSAccess([pm.CallbackFile('/cb/f.txt', read=rd, write=wr)])
    code = ("from pathlib import Path\np = Path('/cb/f.txt')\na = p.read_text()\n"
            "p.write_text('new')\nb = p.read_text()\n(a, b, p.exists())")
    with pool.checkout() as s:
        t.add({'ev': 'complete', 'value': canon(s.feed_run(code, os=fs))})


@probe
def api_boundary_uuid(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        s.feed_run('class A:\n    pass\na1 = A()\na2 = A()')
        i1 = s.feed_run('a1')
        i1b = s.feed_run('a1')
        i2 = s.feed_run('a2')
        t.add({'ev': 'ids', 'is_uuid': isinstance(i1.id, uuid.UUID), 'stable': i1.id == i1b.id,
               'distinct': i1.id != i2.id})


@probe
def api_fork_session(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        s.feed_run('x = [1]')
        b = s.dump()
    h = hashlib.sha256(b).hexdigest()
    with pool.checkout() as s2:
        s2.load_session(b)
        s2.feed_run('x.append(2)')
        v2 = s2.feed_run('x')
    with pool.checkout() as s3:
        s3.load_session(b)
        v3 = s3.feed_run('x')
    t.add({'ev': 'fork', 'fork_a': canon(v2), 'fork_b': canon(v3), 'bytes_unchanged': hashlib.sha256(b).hexdigest() == h})


@probe
def api_reset_type_checker(pool: pm.Monty, t: T) -> None:
    with pool.checkout(type_check=True) as s:
        s.feed_run('x: int = 1')
        try:
            s.feed_run('y: int = x\ny')
            t.add({'ev': 'checked', 'with_prior_definition': 'ok'})
        except pm.MontyError as e:
            t.add({'ev': 'checked', 'with_prior_definition': type(e).__name__})
    with pool.checkout(type_check=True) as s:
        try:
            s.feed_run('y: int = x\ny')
            t.add({'ev': 'checked', 'fresh_unresolved': False})
        except pm.MontyError as e:
            t.add({'ev': 'checked', 'fresh_unresolved': 'unresolved-reference' in str(e)})


@probe
def api_eager_coroutine(pool: pm.Monty, t: T) -> None:
    with pool.checkout() as s:
        a = s.feed_start('r = f()\nr')
        t.add({'ev': 'eager', 'sync_call': a.allow_eager_await})
        a.resume({'return_value': 1})
        b = s.feed_start('r = await f()\nr')
        t.add({'ev': 'eager', 'await_call': b.allow_eager_await})


def main() -> int:
    out = Path(sys.argv[1])
    only = set(sys.argv[2:])
    with pm.Monty() as pool:
        for name, fn in PROBES.items():
            if only and name not in only:
                continue
            t = T()
            err = None
            try:
                fn(pool, t)
            except Exception as e:  # noqa: BLE001
                err = ''.join(traceback.format_exception(e))
            d = out / name
            d.mkdir(parents=True, exist_ok=True)
            res = stable({'probe': name, 'engine': 'ref', 'backend': 'py', 'events': t.events, 'runner_error': err},
                         tempfile.gettempdir())
            (d / 'ref-py.json').write_text(json.dumps(res, indent=1, ensure_ascii=False) + '\n')
            print(f'ref {name}: {"ERROR" if err else "ok"}', flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
