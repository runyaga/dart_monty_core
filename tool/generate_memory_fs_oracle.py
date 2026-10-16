#!/usr/bin/env python3
"""Record OSAccess directly from the pinned Python wheel (no Dart code shared)."""
import argparse
import datetime
import json
from pathlib import Path, PurePosixPath
import subprocess
import pydantic_monty as monty

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / 'test/unit/mount/_memory_fs_oracle.g.dart'
SEEDS = [('/d/f', 'é'), ('/d/sub/f', 'nested'), ('/empty/f', ''),
         ('/bytes', [0, 255]), ('//double/f', 'double')]


def cases():
    paths = ['/', '/d', '/d/f', '/d/sub', '/d/sub/f', '/missing',
             '/missing/f', '/d/f/sub', '//double/f', "/quote'file"]
    operations = ['exists', 'is_file', 'is_dir', 'is_symlink', 'read_text',
                  'read_bytes', 'write_text', 'write_bytes', 'append_text',
                  'append_bytes', 'stat', 'unlink', 'rmdir', 'iterdir',
                  'resolve', 'absolute']
    for op in operations:
        for path in paths:
            data = ['😀é'] if op.endswith('_text') and not op.startswith('read') else []
            if op.endswith('_bytes') and not op.startswith('read'):
                data = [[255, 0]]
            yield f'{op}:{path}', 'Path.' + op, [path, *data], {}
    for path in paths:
        for parents in [False, True]:
            for exist_ok in [False, True]:
                yield f'mkdir:{path}:{parents}:{exist_ok}', 'Path.mkdir', [path], dict(parents=parents, exist_ok=exist_ok)
        for mode in ['r', 'rb', 'w', 'wb', 'a', 'ab', 'w+', 'x', 'ww', 'b']:
            yield f'open:{path}:{mode}', 'open', [path, mode], {}
    for src in ['/d/f', '/d', '/missing', '/bytes', '/empty']:
        for dst in ['/new', '/missing/f', '/bytes', '/d', '/d/f', '/empty']:
            yield f'rename:{src}:{dst}', 'Path.rename', [src, dst], {}
    for src, dst in [('f', '/new'), ('/missing', 'new'), ('f', 'new')]:
        yield f'review:rename:{src}:{dst}', 'Path.rename', [src, dst], {}

    for op in ['Path.read_text', 'Path.append_text']:
        args = ['/bytes', 'B'] if op.endswith('append_text') else ['/bytes']
        yield f'review:bom:{op}', op, args, {'seedBytes': [239, 187, 191, 65]}
    for cap in [0, 0.001, None]:
        yield f'review:sleep:nan:{cap}', 'time.sleep', ['nan'], {'maxSleep': cap}

    for seconds in ['-1', 'inf', '-inf', '0']:
        yield f'sleep:uncapped:{seconds}', 'time.sleep', [seconds], {'maxSleep': None}
    yield 'urandom:negative', 'os.urandom', [-1], {}
    yield 'mkdir:relative:parents', 'Path.mkdir', ['a/b'], {'parents': True}
    yield 'mkdir:relative:existing-parent', 'Path.mkdir', ['a/b/c'], {'relativeParent': True}
    yield 'rename:mutated-file-path', 'Path.rename', ['/d', '/new'], {'mutatedPath': '/outside/f'}
    for offset, name in [(19800, 'India'), (-12600, 'Newfoundland')]:
        yield f'datetime:zone:{name}', 'datetime.now', [{'offset': offset, 'name': name}], {}

    for op in ['Path.exists', 'Path.iterdir', 'Path.mkdir']:
        yield f'empty-path:{op}', op, ['.'], {}
    for data in [[194], [226, 130], [240, 159, 152], [194, 65],
                 [226, 130, 65], [237, 160, 128], [240, 128, 128, 128], [65, 255]]:
        for op in ['Path.read_text', 'Path.append_text']:
            args = ['/bytes', 'tail'] if op.endswith('append_text') else ['/bytes']
            yield f'utf8:{op}:{data}', op, args, {'seedBytes': data}


def encode(value):
    if isinstance(value, datetime.datetime):
        return {'timezone': [int(value.utcoffset().total_seconds()), value.tzname()]}
    if isinstance(value, bytes):
        return {'bytes': list(value)}
    if isinstance(value, PurePosixPath):
        return {'path': str(value)}
    if isinstance(value, monty.MontyFileHandle):
        return {'handle': [value.path, value.mode]}
    if hasattr(value, '_fields'):
        return {'stat': list(value[:7])}
    if isinstance(value, list):
        return [encode(v) for v in value]
    return value


def record(case):
    name, op, args, kwargs = case
    kwargs = dict(kwargs)
    files = [monty.MemoryFile(path, bytes(data) if isinstance(data, list) else data) for path, data in SEEDS]
    seed_bytes = kwargs.get('seedBytes')
    if seed_bytes is not None:
        files[3].content = bytes(seed_bytes)
        kwargs = {}
    config = {'max_sleep': kwargs.pop('maxSleep')} if 'maxSleep' in kwargs else {}
    mutated_path = kwargs.pop('mutatedPath', None)
    relative_parent = kwargs.pop('relativeParent', False)
    fs = monty.OSAccess(files, **config)
    fs.path_unlink(PurePosixPath('/empty/f'))
    if mutated_path is not None:
        files[0].path = PurePosixPath(mutated_path)
    if relative_parent:
        fs.path_mkdir(PurePosixPath('a/b'), parents=True, exist_ok=False)
    if op == 'time.sleep':
        converted = [float(args[0])]
    elif op == 'os.urandom':
        converted = args
    elif op == 'datetime.now':
        converted = [datetime.timezone(datetime.timedelta(seconds=args[0]['offset']), args[0]['name'])]
    else:
        converted = [PurePosixPath(args[0])]
    if len(args) > 1:
        data = args[1]
        converted.append(PurePosixPath(data) if op == 'Path.rename' else bytes(data) if isinstance(data, list) else data)
    try:
        result = {'value': encode(fs.dispatch(op, tuple(converted), kwargs))}
    except Exception as error:
        # Python's host bridge reports UnicodeDecodeError as ValueError.
        kind = 'ValueError' if isinstance(error, UnicodeDecodeError) else type(error).__name__
        result = {'error': [kind, str(error)]}
    state = [[str(f.path), encode(f.read_content()), f.deleted] for f in fs.files]
    row = dict(name=name, op=op, args=args, kwargs=kwargs, result=result, state=state, seedBytes=seed_bytes)
    if config:
        row['maxSleep'] = config['max_sleep']
    if mutated_path is not None:
        row['mutatedPath'] = mutated_path
    if relative_parent:
        row['relativeParent'] = True
    probe_paths = ['/d', '/new', '/new/f', '/outside/f'] if mutated_path else ['a/b', 'a/b/c', '/a/b', '/b'] if op == 'Path.mkdir' and args[0].startswith('a/') else []
    if probe_paths:
        row['exists'] = {path: fs.path_exists(PurePosixPath(path)) for path in probe_paths}
    return row


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--check', action='store_true')
    check = parser.parse_args().check
    rows = [record(case) for case in cases()]
    lines = ['// Generated by tool/generate_memory_fs_oracle.py; do not edit.',
             '// Oracle: pydantic-monty 1.1.0, pinned by tool/upstream/requirements.lock.',
             'const memoryFsOracle = <String>[']
    for row in rows:
        text = json.dumps(row, ensure_ascii=True, separators=(',', ':'))
        lines.append('  ' + json.dumps(text).replace('$', r'\$') + ',')
    lines.append('];')
    formatted = subprocess.run(['dart', 'format', '--stdin-name', str(OUT)],
                              input='\n'.join(lines) + '\n', capture_output=True, text=True, check=True).stdout
    if check:
        if not OUT.exists() or OUT.read_text() != formatted:
            print(f'STALE: {OUT}')
            return 1
    else:
        OUT.write_text(formatted)
    print(f'memory fs oracle: {len(rows)} cases')
    return 0

if __name__ == '__main__':
    raise SystemExit(main())
