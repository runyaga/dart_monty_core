#!/usr/bin/env python3
"""Reference runner: each parity case through upstream pydantic/monty 1.1.0.

pydantic_monty is the oracle: its outcome for a case is the expected value
every dart_monty_core backend is scored against.

usage: python -I tool/parity/oracle/run_cases.py OUTDIR case.json [case.json ...]

Writes OUTDIR/<case_id>/ref-py.json per case (and refmem-py.json when the case
asks for upstream's in-memory filesystem as a second column). Exit 0 unless the
runner itself breaks; a case that cannot run records `runner_error`.

Case format (tool/parity/cases/<suite>/<id>.json): `id`; `code` (one feed)
or `feeds` (one REPL session, one feed each); optional typed `inputs`;
scripted `externals` / `os` answers per name in call order (`return`,
`raise`, `echo`, `echo_arg`); `limits`; `os_policy`; `fs` (mounts + seeded
files); `cwd`; `host` (host classes, objects, wrappers); `restore_before`;
`refmem` (also run upstream's in-memory filesystem). Values use the canonical
form `canon` produces ({"t": kind, ...}; floats compared by IEEE-754 bits;
shared containers carry id/ref). The outcome has one step per feed: value,
exception (type, message, traceback frames, structured data), prints,
os_calls, ext_calls, host_calls.
"""

from __future__ import annotations

import builtins
import collections
import dataclasses
import datetime as dt
import json
import re
import shutil
import struct
import sys
import tempfile
import time
import traceback
from pathlib import Path, PurePath, PurePosixPath
from typing import Any

import pydantic_monty as pm

CONTAINERS = (list, tuple, dict, set, frozenset)
HOST_LABELS: dict[int, tuple[str, str]] = {}  # id(obj) -> ('hostobj'|'hostclass', label)
HOST_KEEP: list[Any] = []


# ---------------------------------------------------------------- canonical
def float_c(x: float) -> dict[str, Any]:
    return {'t': 'float', 'v': repr(x), 'bits': struct.pack('>d', x).hex()}


def canon(value: Any) -> Any:
    """Python value -> canonical JSON form (identity-aware: shared containers get id/ref)."""
    counts: dict[int, int] = {}
    keep: list[Any] = []  # keep objects alive so ids stay unique

    def count(v: Any, stack: set[int]) -> None:
        if isinstance(v, CONTAINERS):
            i = id(v)
            counts[i] = counts.get(i, 0) + 1
            keep.append(v)
            if counts[i] > 1 or i in stack:
                return
            stack.add(i)
            if isinstance(v, dict):
                for k, x in v.items():
                    count(k, stack)
                    count(x, stack)
            else:
                for x in v:
                    count(x, stack)
            stack.discard(i)

    count(value, set())
    ids: dict[int, int] = {}

    def enc(v: Any) -> Any:
        if id(v) in HOST_LABELS:
            kind, label = HOST_LABELS[id(v)]
            return {'t': kind, 'obj': label}
        if v is None:
            return {'t': 'none'}
        if isinstance(v, bool):
            return {'t': 'bool', 'v': v}
        if isinstance(v, int):
            return {'t': 'int', 'v': str(v)}
        if isinstance(v, float):
            return float_c(v)
        if isinstance(v, str):
            return {'t': 'str', 'v': v}
        if isinstance(v, (bytes, bytearray)):
            return {'t': 'bytes', 'hex': bytes(v).hex()}
        if isinstance(v, complex):
            return {'t': 'complex', 're': float_c(v.real), 'im': float_c(v.imag)}
        if isinstance(v, PurePath):
            return {'t': 'path', 'v': v.as_posix()}
        if isinstance(v, pm.MontyFileHandle):
            return {'t': 'filehandle', 'path': v.path, 'mode': v.mode, 'position': str(v.position)}
        x = canon_extra(v, enc)
        if x is not None:
            return x
        if isinstance(v, CONTAINERS):
            i = id(v)
            if i in ids:
                return {'t': 'ref', 'id': ids[i]}
            out: dict[str, Any] = {}
            if counts.get(i, 0) > 1:
                ids[i] = len(ids) + 1
                out['id'] = ids[i]
            if isinstance(v, dict):
                out['t'] = 'dict'
                out['items'] = [[enc(k), enc(x)] for k, x in v.items()]
            elif isinstance(v, (set, frozenset)):
                out['t'] = 'set' if isinstance(v, set) else 'frozenset'
                out['items'] = sorted((enc(x) for x in v), key=lambda e: json.dumps(e, sort_keys=True))
            elif isinstance(v, tuple) and hasattr(v, '_fields'):
                out['t'] = 'namedtuple'
                m = type(v).__module__
                out['type'] = type(v).__name__ if m in ('', '__main__', 'builtins') else f'{m}.{type(v).__name__}'
                out['fields'] = list(v._fields)
                out['items'] = [enc(x) for x in v]
            else:
                out['t'] = 'list' if isinstance(v, list) else 'tuple'
                out['items'] = [enc(x) for x in v]
            return out
        return {'t': 'other', 'kind': type(v).__name__, 'repr': repr(v)}

    return enc(value)


def _dt_off(t: Any) -> tuple[int | None, str | None]:
    tz = t.tzinfo
    if tz is None:
        return None, None
    off = tz.utcoffset(None) if isinstance(t, dt.time) else tz.utcoffset(t)
    name = tz.tzname(None) if isinstance(t, dt.time) else tz.tzname(t)
    secs = int(off.total_seconds())
    # datetime.timezone without an explicit name reports 'UTC+hh:mm'; keep only explicit names
    if isinstance(tz, dt.timezone) and name == dt.timezone(off).tzname(None):
        name = None
    return secs, name


def _type_name(t: type) -> str:
    m = t.__module__
    return t.__qualname__ if m == 'builtins' else f'{m}.{t.__qualname__}'


def canon_extra(v: Any, enc: Any) -> Any:
    if v is Ellipsis:
        return {'t': 'ellipsis'}
    if v is NotImplemented:
        return {'t': 'notimpl'}
    if isinstance(v, dt.datetime):
        o, n = _dt_off(v)
        return {'t': 'datetime', 'v': v.replace(tzinfo=None).isoformat(timespec='microseconds'), 'offset': o, 'tzname': n}
    if isinstance(v, dt.date):
        return {'t': 'date', 'v': v.isoformat()}
    if isinstance(v, dt.time):
        o, n = _dt_off(v)
        return {'t': 'time', 'v': v.replace(tzinfo=None).isoformat(timespec='microseconds'), 'offset': o,
                'tzname': n, 'fold': v.fold}
    if isinstance(v, dt.timedelta):
        return {'t': 'timedelta', 'days': v.days, 'seconds': v.seconds, 'us': v.microseconds}
    if isinstance(v, dt.timezone):
        off = v.utcoffset(None)
        name = v.tzname(None)
        if name == dt.timezone(off).tzname(None):
            name = None
        return {'t': 'timezone', 'offset': int(off.total_seconds()), 'name': name}
    if isinstance(v, BaseException):
        return {'t': 'exception', 'type': type(v).__name__, 'arg': (str(v.args[0]) if v.args else None)}
    if isinstance(v, pm.MontyStdTypeProxy):
        return {'t': 'builtin' if v.kind == 'function' else 'type', 'name': v.name, '_proxy': 'std'}
    if isinstance(v, pm.MontyClassProxy):
        return {'t': 'proxy', 'class': v.name, 'dataclass': v.is_dataclass,
                'attrs': [[k, enc(x)] for k, x in v.attributes.items()], '_raw': True}
    if isinstance(v, pm.MontyClassTypeProxy):
        return {'t': 'typeproxy', 'name': v.name, 'dataclass': v.is_dataclass,
                'attrs': [[k, enc(x)] for k, x in v.attributes.items()]}
    if isinstance(v, type):
        return {'t': 'type', 'name': _type_name(v)}
    if isinstance(v, (pm.ClassInstance, pm.ClassType)):
        return {'t': 'wrapper?', 'repr': repr(v)}
    return None


def decode(c: dict[str, Any], ctx: Ctx | None = None, memo: dict[int, Any] | None = None) -> Any:
    """Canonical JSON form -> Python value (the inverse of `canon`)."""
    memo = {} if memo is None else memo
    t = c['t']
    if t == 'ref':
        return memo[c['id']]

    def done(obj: Any) -> Any:
        if 'id' in c:
            memo[c['id']] = obj
        return obj

    def items() -> list[Any]:
        return [decode(x, ctx, memo) for x in c['items']]

    if t == 'none':
        return None
    if t in ('bool', 'str'):
        return c['v']
    if t == 'int':
        return int(c['v'])
    if t == 'float':
        if 'bits' in c:
            return struct.unpack('>d', bytes.fromhex(c['bits']))[0]
        return float(c['v'])
    if t == 'bytes':
        return bytes.fromhex(c['hex'])
    if t == 'list':
        out: list[Any] = done([])
        out.extend(items())
        return out
    if t == 'tuple':
        return done(tuple(items()))
    if t == 'set':
        return done(set(items()))
    if t == 'frozenset':
        return done(frozenset(items()))
    if t == 'dict':
        d: dict[Any, Any] = done({})
        for k, v in c['items']:
            d[decode(k, ctx, memo)] = decode(v, ctx, memo)
        return d
    if t == 'complex':
        return complex(decode(c['re']), decode(c['im']))
    if t == 'path':
        return PurePosixPath(c['v'])
    if t == 'filehandle':
        return pm.MontyFileHandle(c['path'], c['mode'], position=int(c.get('position', '0')))
    if t == 'ellipsis':
        return Ellipsis
    if t == 'notimpl':
        return NotImplemented
    if t == 'namedtuple':
        mod, _, nm = c['type'].rpartition('.')
        nt = collections.namedtuple(nm, c['fields'], module=mod or None)
        return done(nt._make(items()))
    if t == 'date':
        return dt.date.fromisoformat(c['v'])
    if t in ('datetime', 'time'):
        cls = dt.datetime if t == 'datetime' else dt.time
        v = cls.fromisoformat(c['v'])
        if c.get('offset') is not None:
            off = dt.timedelta(seconds=c['offset'])
            tz = dt.timezone(off, c['tzname']) if c.get('tzname') else dt.timezone(off)
            v = v.replace(tzinfo=tz)
        if t == 'time' and c.get('fold'):
            v = v.replace(fold=c['fold'])
        return v
    if t == 'timedelta':
        return dt.timedelta(days=c['days'], seconds=c['seconds'], microseconds=c['us'])
    if t == 'timezone':
        off = dt.timedelta(seconds=c['offset'])
        return dt.timezone(off, c['name']) if c.get('name') else dt.timezone(off)
    if t == 'exception':
        cls = getattr(builtins, c['type'])
        return cls(c['arg']) if c.get('arg') is not None else cls()
    if t == 'type':
        n = c['name']
        if '.' in n:
            mod, _, nm = n.rpartition('.')
            return getattr(__import__(mod), nm)
        return getattr(builtins, n)
    if t == 'opaque':  # a host value no engine can convert
        return object()
    if t == 'str_repeat':  # a large string without a large case file
        return c['v'] * c['n']
    if t == 'echo':
        assert ctx is not None
        return ctx.raw_outputs[c['step']]
    if t == 'wrap':
        assert ctx is not None
        return ctx.wrapper(c['w'])
    if t == 'hostobj':
        assert ctx is not None
        return ctx.objects[c['obj']]
    raise ValueError(f'cannot decode canonical {t}')


# ---------------------------------------------------------------- host objects
class Ctx:
    """Per-case host world built from case['host']: classes, objects, wrappers, call log."""

    def __init__(self, case: dict[str, Any]) -> None:
        self.case = case
        self.raw_outputs: list[Any] = []
        self.log: list[dict[str, Any]] = []
        self.logging = False
        self.classes: dict[str, type] = {}
        self.objects: dict[str, Any] = {}
        self.wrappers: dict[str, Any] = {}
        self.new_count: dict[str, int] = {}
        host = case.get('host') or {}
        for cname, spec in (host.get('classes') or {}).items():
            self.classes[cname] = self._make_class(cname, spec)
        for label, spec in (host.get('objects') or {}).items():
            cls = self.classes[spec['class']]
            obj = cls(**{k: decode(v, self) for k, v in spec['values'].items()})
            self._label(obj, label)
        self.wspecs = host.get('wrappers') or {}
        self.logging = True

    def _label(self, obj: Any, label: str) -> None:
        self.objects[label] = obj
        HOST_LABELS[id(obj)] = ('hostobj', label)
        HOST_KEEP.append(obj)

    def _make_class(self, cname: str, spec: dict[str, Any]) -> type:
        ctx = self
        fields = spec.get('fields', [])
        ns: dict[str, Any] = {'__module__': 'host'}
        for k, v in (spec.get('class_attrs') or {}).items():
            ns[k] = decode(v, self)

        def make_method(mname: str, beh: dict[str, Any]) -> Any:
            def body(self_or_cls: Any, *args: Any, **kwargs: Any) -> Any:
                ctx.log.append({'op': 'method', 'obj': canon(self_or_cls), 'name': mname,
                                'args': [canon(a) for a in args], 'kwargs': {k: canon(v) for k, v in kwargs.items()}})
                if 'returns' in beh:
                    return decode(beh['returns'], ctx)
                if 'format' in beh:
                    return beh['format'].format(*args, **{f: getattr(self_or_cls, f) for f in fields})
                if 'raise' in beh:
                    raise getattr(builtins, beh['raise']['type'])(beh['raise'].get('message', ''))
                if 'new_minus' in beh:
                    f = beh['new_minus']
                    vals = {k: getattr(self_or_cls, k) for k in fields}
                    vals[f] = vals[f] - args[0]
                    return type(self_or_cls)(**vals)
                if 'returns_obj' in beh:
                    return ctx.objects[beh['returns_obj']]
                raise RuntimeError(f'bad behaviour {beh}')

            if beh.get('kind') == 'static':
                return staticmethod(lambda *a, **k: body(None, *a, **k))
            if beh.get('kind') == 'classmethod':
                return classmethod(body)
            return body

        for mname, beh in (spec.get('methods') or {}).items():
            ns[mname] = make_method(mname, beh)
        if spec.get('dataclass'):
            def post_init(self: Any) -> None:
                ctx._on_new(self, cname)

            ns['__post_init__'] = post_init
            cls = dataclasses.make_dataclass(cname, [(f, Any) for f in fields], namespace=ns, module='host')
        else:
            def init(self: Any, *args: Any, **kwargs: Any) -> None:
                for f, a in zip(fields, args):
                    setattr(self, f, a)
                for k, a in kwargs.items():
                    setattr(self, k, a)
                ctx._on_new(self, cname)

            ns['__init__'] = init
            cls = type(cname, (), ns)
        HOST_LABELS[id(cls)] = ('hostclass', cname)
        HOST_KEEP.append(cls)
        return cls

    def _on_new(self, obj: Any, cname: str) -> None:
        if not self.logging:
            return
        n = self.new_count[cname] = self.new_count.get(cname, 0) + 1
        label = f'new:{cname}#{n}'
        self.log.append({'op': 'init', 'class': cname, 'obj': label,
                         'attrs': [[k, canon(v)] for k, v in vars(obj).items()]})
        self._label(obj, label)

    def _hook(self, hook: str | None, name: str, value: Any, wspec: dict[str, Any]) -> Any:
        self.log.append({'op': 'convert', 'name': name})
        if hook is None:
            return value
        if hook == 'upper':
            return value.upper() if isinstance(value, str) else value
        if hook.startswith('redact:'):
            return '***' if name == hook.split(':', 1)[1] else value
        if hook == 'wrap':
            if type(value) in self.classes.values():
                return self._instance_wrapper(value, wspec)
            return value
        raise ValueError(hook)

    def _instance_wrapper(self, obj: Any, wspec: dict[str, Any]) -> Any:
        ctx = self
        hook = wspec.get('convert')

        class W(pm.ClassInstance):
            def convert_value(self, /, name: str, value: Any) -> Any:
                return ctx._hook(hook, name, value, wspec)

            def call_method(self, name: str, args: Any, kwargs: Any) -> Any:
                ctx.log.append({'op': 'call', 'obj': canon(self.value), 'name': name})
                return super().call_method(name, args, kwargs)

            def lookup_lazy_attrs(self, name: str) -> Any:
                ctx.log.append({'op': 'lookup', 'obj': canon(self.value), 'name': name})
                return super().lookup_lazy_attrs(name)

        kw: dict[str, Any] = {}
        for src, dst in (('eager', 'eager_attrs'), ('lazy', 'lazy_attrs'), ('methods', 'allowed_methods')):
            p = wspec.get(src)
            kw[dst] = p if p in (None, 'all') else list(p)
        if wspec.get('class_wrapper'):
            kw['class_type'] = self.wrapper(wspec['class_wrapper'])
        return W(obj, **kw)

    def wrapper(self, name: str) -> Any:
        if name in self.wrappers:
            return self.wrappers[name]
        ws = self.wspecs[name]
        ctx = self
        if ws['kind'] == 'instance':
            w = self._instance_wrapper(self.objects[ws['obj']], ws)
        else:
            hook = ws.get('convert')

            class CW(pm.ClassType):
                def convert_value(self, /, name: str, value: Any) -> Any:
                    return ctx._hook(hook, name, value, ws)

                def call_method(self, name: str, args: Any, kwargs: Any) -> Any:
                    ctx.log.append({'op': 'call', 'obj': canon(self.value), 'name': name})
                    return super().call_method(name, args, kwargs)

                def lookup_lazy_attrs(self, name: str) -> Any:
                    ctx.log.append({'op': 'lookup', 'obj': canon(self.value), 'name': name})
                    return super().lookup_lazy_attrs(name)

                def instance_wrapper(self, instance: Any) -> Any:
                    iw = {'eager': ws.get('instance_eager'), 'lazy': ws.get('instance_lazy'),
                          'methods': ws.get('instance_methods'), 'convert': hook}
                    w = ctx._instance_wrapper(instance, iw)
                    w.class_type = self
                    return w

            kw: dict[str, Any] = {'init': bool(ws.get('init'))}
            for src, dst in (('eager', 'eager_attrs'), ('lazy', 'lazy_attrs'), ('methods', 'allowed_methods'),
                             ('instance_eager', 'instance_eager_attrs'), ('instance_lazy', 'instance_lazy_attrs'),
                             ('instance_methods', 'instance_allowed_methods')):
                p = ws.get(src)
                kw[dst] = p if p in (None, 'all') else list(p)
            w = CW(self.classes[ws['class']], **kw)
        self.wrappers[name] = w
        return w


# ---------------------------------------------------------------- filesystem
def policy_of(p: dict[str, Any]) -> dict[str, Any]:
    out = dict(p)
    if isinstance(out.get('datetime'), dict):
        out['datetime'] = dt.datetime.fromisoformat(out['datetime']['fixed'])
    if isinstance(out.get('random_start'), dict):
        out['random_start'] = {'seed': decode(out['random_start']['seed'])}
    return out


def seed_files(root: Path, virtual: str, files: dict[str, Any]) -> None:
    for vpath, content in files.items():
        if not (vpath == virtual or vpath.startswith(virtual.rstrip('/') + '/')):
            continue
        rel = vpath[len(virtual.rstrip('/')):].lstrip('/')
        if vpath.endswith('/'):
            (root / rel).mkdir(parents=True, exist_ok=True)
            continue
        f = root / rel
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(bytes.fromhex(content['hex']) if 'hex' in content else content['text'].encode())


def build_mounts(case: dict[str, Any], fsroot: Path) -> tuple[list[Any] | None, Exception | None]:
    """Upstream MountDir per case mount, each over a fresh temp dir seeded with the case files."""
    fs = case.get('fs')
    if not fs or fs.get('backend') == 'memory':
        return None, None
    base = fsroot / case['id']
    shutil.rmtree(base, ignore_errors=True)
    mounts = []
    try:
        for i, m in enumerate(fs['mounts']):
            host = base / str(m.get('host_index', i))
            host.mkdir(parents=True, exist_ok=True)
            seed_files(host, m['virtual'], fs.get('files', {}))
            kw: dict[str, Any] = {'host_path': host, 'virtual_path': m['virtual'], 'mode': m.get('mode', 'read-write')}
            if m.get('write_bytes_limit') is not None:
                kw['write_bytes_limit'] = m['write_bytes_limit']
            if m.get('memory_usage_limit') is not None:
                kw['memory_usage_limit'] = m['memory_usage_limit']
            mounts.append(pm.MountDir(**kw))
    except Exception as e:  # noqa: BLE001 - a registration error is the outcome
        return [], e
    return mounts, None


# ---------------------------------------------------------------- output helpers
def frame_c(f: Any) -> dict[str, Any]:
    d = f.dict()
    return {
        'filename': d.get('filename'),
        'line': d.get('line'),
        'column': d.get('column'),
        'end_line': d.get('end_line'),
        'end_column': d.get('end_column'),
        'function': d.get('function_name'),
        'source_line': d.get('source_line'),
    }


def merge_prints(raw: list[tuple[str, str]]) -> list[dict[str, str]]:
    out: list[dict[str, str]] = []
    for stream, text in raw:
        if out and out[-1]['stream'] == stream:
            out[-1]['text'] += text
        else:
            out.append({'stream': stream, 'text': text})
    return out


def answer(script: list[dict[str, Any]] | None, idx: int) -> dict[str, Any] | None:
    if script is None or idx >= len(script):
        return None
    return script[idx]


def exc_fields(e: Any) -> dict[str, Any]:
    msg = e.display('msg')
    tm = e.display('type-msg')
    typ = tm[: -(len(msg) + 2)] if msg and tm.endswith(': ' + msg) else tm.split(':', 1)[0]
    return {'type': typ, 'message': msg, 'traceback': [frame_c(f) for f in e.traceback()]}


def exc_data(inner: BaseException) -> dict[str, Any] | None:
    """The structured payload pydantic_monty's exception() object carries."""
    if isinstance(inner, UnicodeError) and hasattr(inner, 'start'):
        obj = inner.object
        return {'kind': 'unicode', 'encoding': inner.encoding,
                'object': ({'t': 'bytes', 'hex': bytes(obj).hex()} if isinstance(obj, (bytes, bytearray))
                           else {'t': 'str', 'v': obj}),
                'start': inner.start, 'end': inner.end, 'reason': inner.reason}
    if isinstance(inner, json.JSONDecodeError):
        return {'kind': 'json', 'msg': inner.msg, 'doc': inner.doc, 'pos': inner.pos,
                'lineno': inner.lineno, 'colno': inner.colno}
    return None


# ---------------------------------------------------------------- running
def run_case(pool: pm.Monty, case: dict[str, Any], fsroot: Path) -> dict[str, Any]:
    out: dict[str, Any] = {
        'case': case['id'],
        'engine': 'ref',
        'backend': 'py',
        'engine_version': f'pydantic_monty {pm.__version__}',
        'steps': [],
        'unsupported': {},
        'notes': {'inputs': 'typed: feed_start(inputs=...) on the first feed'},
        'runner_error': None,
    }
    ctx = Ctx(case)
    limits: dict[str, Any] = {}
    for k, v in (case.get('limits') or {}).items():
        limits['max_feed_duration_secs' if k == 'max_duration_secs' else k] = v
    checkout_kw: dict[str, Any] = {}
    if limits:
        checkout_kw['limits'] = limits
    if case.get('os_policy'):
        checkout_kw['os_policy'] = policy_of(case['os_policy'])
    if 'assert_message_annotations' in case:
        checkout_kw['assert_message_annotations'] = case['assert_message_annotations']
    mounts, mount_err = build_mounts(case, fsroot)
    feed_kw: dict[str, Any] = {}
    if mounts is not None:
        feed_kw['mount'] = mounts
    if case.get('cwd') is not None:
        feed_kw['cwd'] = case['cwd']
    feeds = case.get('feeds') or [case['code']]
    restore_before = set(case.get('restore_before') or [])
    used: dict[str, int] = {}
    cm = pool.checkout(**checkout_kw)
    session = cm.__enter__()
    try:
        for n, code in enumerate(feeds):
            if n in restore_before:
                blob = session.dump()
                cm.__exit__(None, None, None)
                cm = pool.checkout(**checkout_kw)
                session = cm.__enter__()
                session.load_session(blob)
            raw_prints: list[tuple[str, str]] = []
            step: dict[str, Any] = {
                'value': None,
                'exception': None,
                'prints': [],
                'os_calls': [],
                'ext_calls': [],
                'name_lookups': [],
                'host_calls': [],
                'usage': None,
            }
            ctx.log = step['host_calls']
            raw_out: Any = None
            kw: dict[str, Any] = {'print_callback': lambda s, t: raw_prints.append((s, t))}
            if n == 0 and case.get('inputs'):
                kw['inputs'] = {k: decode(v, ctx) for k, v in case['inputs'].items()}
            kw.update(feed_kw)
            if mounts is not None:
                def recorder(*, name: Any, args: Any, kwargs: Any, is_async: Any, **_: Any) -> Any:
                    step['os_calls'].append({'name': str(name), 'args': [canon(a) for a in args],
                                             'kwargs': {k: canon(v) for k, v in kwargs.items()}})
                    a = answer((case.get('os') or {}).get(str(name)), used.get('os:' + str(name), 0))
                    used['os:' + str(name)] = used.get('os:' + str(name), 0) + 1
                    if a is None:
                        return pm.NOT_HANDLED
                    if 'return' in a:
                        return decode(a['return'])
                    raise getattr(builtins, a['raise']['type'])(a['raise'].get('message', ''))
                kw['os'] = recorder
            if case.get('close_mount_before_feed') == n and mounts:
                for m in mounts:
                    m.close()
            t0 = time.monotonic()
            try:
                if mount_err is not None:
                    raise mount_err
                snap = session.feed_start(code, **kw)
                guard = 0
                while not isinstance(snap, pm.MontyComplete):
                    guard += 1
                    if guard > 1000:
                        raise RuntimeError('more than 1000 suspensions')
                    if isinstance(snap, pm.FunctionSnapshot) and snap.object_id is not None:
                        snap = snap.resume_auto()
                        continue
                    if mounts is not None and isinstance(snap, pm.FunctionSnapshot) and snap.is_os_function:
                        snap = snap.resume_auto()  # mounts first, then os= (recorder), then default
                        continue
                    if (isinstance(snap, pm.FunctionSnapshot) and snap.is_os_function
                            and str(snap.function_name) in ('system.sleep', 'system.async_sleep')):
                        # SleepMode::System under manual feed_start dispatch: the host waits and answers
                        # None, as feed_run and AbstractOS.dispatch do; never shown to the os= callback.
                        out['notes'].setdefault('parent_serviced', []).append(str(snap.function_name))
                        time.sleep(float(snap.args[0]))
                        snap = snap.resume({'return_value': None})
                        continue
                    if isinstance(snap, pm.FunctionSnapshot):
                        name = str(snap.function_name)
                        rec = {
                            'name': name,
                            'args': [canon(a) for a in snap.args],
                            'kwargs': {k: canon(v) for k, v in snap.kwargs.items()},
                        }
                        table = case.get('os') if snap.is_os_function else case.get('externals')
                        (step['os_calls'] if snap.is_os_function else step['ext_calls']).append(rec)
                        key = ('os:' if snap.is_os_function else 'ext:') + name
                        a = answer((table or {}).get(name), used.get(key, 0))
                        used[key] = used.get(key, 0) + 1
                        if a is None:
                            if snap.is_os_function:
                                snap = snap.resume_not_handled()
                            else:
                                snap = snap.resume({'exc_type': 'NameError',
                                                    'message': f"name '{name}' is not defined"})
                        elif 'echo' in a:
                            snap = snap.resume({'return_value': ctx.raw_outputs[a['echo']]})
                        elif 'echo_arg' in a:
                            snap = snap.resume({'return_value': snap.args[a['echo_arg']]})
                        elif 'return' in a:
                            snap = snap.resume({'return_value': decode(a['return'], ctx)})
                        else:
                            snap = snap.resume({'exc_type': a['raise']['type'],
                                                'message': a['raise'].get('message', '')})
                    elif isinstance(snap, pm.NameLookupSnapshot) and snap.object_id is not None:
                        snap = snap.resume_auto()
                    elif isinstance(snap, pm.NameLookupSnapshot):
                        step['name_lookups'].append(snap.variable_name)
                        snap = snap.resume()
                    else:
                        raise RuntimeError(f'unexpected snapshot {type(snap).__name__}')
                raw_out = snap.output
                step['value'] = canon(snap.output)
            except (pm.MontyRuntimeError, pm.MontySyntaxError) as e:
                step['exception'] = exc_fields(e)
                d = exc_data(e.exception())
                if d is not None:
                    step['exception']['data'] = d
                step['error_class'] = type(e).__name__
                step['host_exception_mro'] = [k.__name__ for k in type(e.exception()).__mro__]
            except pm.MontyConversionError as e:  # input/return conversion rejected
                inner = e.exception()
                step['exception'] = {'type': type(inner).__name__, 'message': str(e), 'traceback': []}
                step['error_class'] = 'MontyConversionError'
            except pm.MontyCrashedError as e:  # worker killed (watchdog / crash)
                step['crashed'] = {'repr': repr(e)[:300], 'timed_out': getattr(e, 'timed_out', None)}
                step['error_class'] = 'MontyCrashedError'
            except (TypeError, ValueError, OSError, OverflowError) as e:
                if case.get('fs') or case.get('host_errors') == 'plain':
                    # host-side mount setup/registration error, or a host-side refusal of an OS-call answer
                    step['exception'] = {'type': type(e).__name__, 'message': str(e), 'traceback': []}
                    step['thrown'] = 'host'
                elif isinstance(e, (OSError, OverflowError)):
                    raise
                else:
                    # host-side conversion refusal of an input (e.g. a cycle); upstream raises in the host
                    step['exception'] = {'type': 'HOST:' + type(e).__name__, 'message': str(e), 'traceback': []}
            step['wall_ms'] = round((time.monotonic() - t0) * 1000, 1)
            ctx.raw_outputs.append(raw_out)
            step['prints'] = merge_prints(raw_prints)
            out['steps'].append(step)
    finally:
        cm.__exit__(None, None, None)
    out['unsupported']['usage'] = 'pydantic_monty exposes no per-feed resource usage'
    return out


def run_refmem(case: dict[str, Any]) -> dict[str, Any]:
    """Second upstream column: OSAccess + MemoryFile (upstream's in-memory filesystem) via feed_run(os=)."""
    from pydantic_monty.os_access import MemoryFile, OSAccess

    out: dict[str, Any] = {
        'case': case['id'], 'engine': 'refmem', 'backend': 'py',
        'engine_version': f'pydantic_monty {pm.__version__} OSAccess+MemoryFile', 'steps': [],
        'unsupported': {}, 'notes': {'fs': 'OSAccess(files=[MemoryFile]) as os= handler'}, 'runner_error': None,
    }
    fs = case['fs']
    files = []
    for vpath, content in fs.get('files', {}).items():
        if vpath.endswith('/'):
            continue
        files.append(MemoryFile(vpath, bytes.fromhex(content['hex']) if 'hex' in content else content['text']))
    osa = OSAccess(files)
    with pm.Monty() as pool, pool.checkout() as session:
        for code in case.get('feeds') or [case['code']]:
            step: dict[str, Any] = {'value': None, 'exception': None, 'prints': [], 'os_calls': [],
                                    'ext_calls': [], 'name_lookups': [], 'usage': None}
            raw: list[tuple[str, str]] = []

            def rec(*, name: Any, args: Any, kwargs: Any, is_async: Any, **_: Any) -> Any:
                return osa(name=name, args=args, kwargs=kwargs, is_async=is_async)

            try:
                step['value'] = canon(session.feed_run(code, os=rec, print_callback=lambda s, t: raw.append((s, t))))
            except (pm.MontyRuntimeError, pm.MontySyntaxError) as e:
                step['exception'] = exc_fields(e)
            step['prints'] = merge_prints(raw)
            out['steps'].append(step)
    return out


UUID = re.compile(r'[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}')
LIMIT_AMOUNT = re.compile(r'\d+(\.\d+)?')


def stable(v: Any, fsroot: str) -> Any:
    """Drops what varies between runs: timings, uuids, the temp mount root, measured limit amounts."""
    if isinstance(v, str):
        v = v.replace(fsroot, '<fsroot>')
        v = UUID.sub('<uuid>', v)
        if 'limit exceeded: ' in v:
            v = LIMIT_AMOUNT.sub('N', v)
        return v
    if isinstance(v, list):
        return [stable(x, fsroot) for x in v]
    if isinstance(v, dict):
        return {k: stable(x, fsroot) for k, x in v.items() if k != 'wall_ms'}
    return v


def error_outcome(case: dict[str, Any], engine: str, e: BaseException) -> dict[str, Any]:
    return {'case': case['id'], 'engine': engine, 'backend': 'py', 'steps': [], 'unsupported': {},
            'notes': {}, 'runner_error': ''.join(traceback.format_exception(e))}


def main() -> int:
    outdir = Path(sys.argv[1])
    cases = [json.loads(Path(p).read_text()) for p in sys.argv[2:]]
    with tempfile.TemporaryDirectory(prefix='parity-fs-') as tmp, pm.Monty() as pool:
        fsroot = Path(tmp).resolve()
        for case in cases:
            try:
                if case.get('pool'):  # pool options (watchdog graces)
                    with pm.Monty(**case['pool']) as p2:
                        res = run_case(p2, case, fsroot)
                else:
                    res = run_case(pool, case, fsroot)
            except Exception as e:  # noqa: BLE001 - recorded, not swallowed
                res = error_outcome(case, 'ref', e)
            d = outdir / case['id']
            d.mkdir(parents=True, exist_ok=True)
            res = stable(res, str(fsroot))
            (d / 'ref-py.json').write_text(json.dumps(res, indent=1, ensure_ascii=False) + '\n')
            if case.get('refmem'):
                try:
                    rm = run_refmem(case)
                except Exception as e:  # noqa: BLE001
                    rm = error_outcome(case, 'refmem', e)
                rm = stable(rm, str(fsroot))
                (d / 'refmem-py.json').write_text(json.dumps(rm, indent=1, ensure_ascii=False) + '\n')
            print(f"ref-py {case['id']}: {'ERROR' if res['runner_error'] else 'ok'}", flush=True)
    return 0


if __name__ == '__main__':
    sys.exit(main())
