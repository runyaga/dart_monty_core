// API-level parity probes through dart_monty_core's public API. Each probe
// emits the events tool/parity/oracle/run_probes.py (and, for three
// Rust-only rows, tool/parity/oracle/rust) records for upstream, and
// tool/parity/probes_compare.py compares the two.
//
// Where core has no API for a step the transcript records `unsupported` (or
// `absent` when the member does not exist at all) and, where one exists, the
// closest public substitute — the substitute's outcome is what is scored.
import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_parity/src/case_runner.dart';

/// One transcript event.
typedef Ev = Map<String, Object?>;

Ev _evOf(MontyProgress p) => switch (p) {
  MontyComplete(:final result) =>
    result.error != null
        ? _errEv(result.error!)
        : {'ev': 'complete', 'value': montyToCanon(result.value)},
  MontyPending(:final functionName, :final args, :final kwargs) => {
    'ev': 'suspend',
    'kind': 'function',
    'name': functionName,
    'args': [for (final a in args) montyToCanon(a)],
    'kwargs': {
      for (final e in (kwargs ?? const {}).entries)
        e.key: montyToCanon(e.value),
    },
    'position': null,
  },
  MontyOsCall(:final operationName, :final args, :final kwargs) => {
    'ev': 'suspend',
    'kind': 'os',
    'name': operationName,
    'args': [for (final a in args) montyToCanon(a)],
    'kwargs': {
      for (final e in (kwargs ?? const {}).entries)
        e.key: montyToCanon(e.value),
    },
    'position': null,
  },
  MontyNameLookup(:final variableName) => {
    'ev': 'suspend',
    'kind': 'name',
    'name': variableName,
    'position': null,
  },
  MontyResolveFutures(:final pendingCallIds) => {
    'ev': 'suspend',
    'kind': 'future',
    'pending': pendingCallIds,
    'position': null,
  },
};

Ev _errEv(MontyException e) => {
  'ev': 'error',
  'type': e.excType,
  'message': e.message,
  'tb_last': e.traceback.isEmpty
      ? null
      : {
          'line': e.traceback.last.startLine,
          'function': e.traceback.last.frameName,
        },
};

/// A thrown error as type + message: a script error's Python type, else the
/// Dart type.
Map<String, Object?> _excObs(Object e) => switch (e) {
  MontyScriptError(:final excType, :final exception, :final message) => {
    'type': exception?.excType ?? excType,
    'message': exception?.message ?? message,
  },
  _ => {'type': e.runtimeType.toString(), 'message': '$e'},
};

class _T {
  final events = <Ev>[];

  void add(Ev e) => events.add(e);

  Future<MontyProgress?> step(Future<MontyProgress> Function() f) async {
    try {
      final p = await f();
      add(_evOf(p));
      return p;
    } on MontyScriptError catch (e) {
      add(
        e.exception != null
            ? _errEv(e.exception!)
            : {
                'ev': 'error',
                'type': e.excType,
                'message': e.message,
                'tb_last': null,
              },
      );
      return null;
    } on Object catch (e) {
      add({'ev': 'refused', 'cls': e.runtimeType.toString(), 'msg': '$e'});
      return null;
    }
  }

  Future<void> result(Future<MontyResult> Function() f) async {
    try {
      final r = await f();
      add(
        r.error != null
            ? _errEv(r.error!)
            : {'ev': 'complete', 'value': montyToCanon(r.value)},
      );
    } on Object catch (e) {
      add({'ev': 'refused', 'cls': e.runtimeType.toString(), 'msg': '$e'});
    }
  }
}

const _extResultCode = '''
try:
    r = f()
except ValueError as e:
    r = "caught ValueError: " + str(e)
except NameError as e:
    r = "caught NameError: " + str(e)
r''';
const _extArgsCode = "a = [1]\nf(1, 'a', a, a, k=3, m={'x': 1.5}, n=None)";
const _wCode = """
from pathlib import Path
res = []
for n in ('a', 'b'):
    try:
        Path('/data/' + n + '.txt').write_text('xxxxxx')
        res.append('ok')
    except Exception as e:
        res.append(type(e).__name__ + ': ' + str(e))
res""";
const _mCode = """
from pathlib import Path
res = []
def w(n):
    try:
        Path('/data/' + n).write_text('y' * 300)
        res.append('ok')
    except Exception as e:
        res.append(type(e).__name__ + ': ' + str(e))
w('a')
w('b')
w('c')
w('d')
try:
    Path('/data/a').unlink()
    res.append('unlinked')
except Exception as e:
    res.append(type(e).__name__ + ': ' + str(e))
w('d')
res""";

/// The sources the continuation probe classifies (same list as the Rust
/// oracle).
const continuationSources = [
  'x = 1',
  'def f():',
  'def f():\n    return 1',
  'def f():\n    return 1\n',
  '(1,',
  '[1, 2',
  'x = (',
  'if True:\n    pass\n',
  "s = '''abc",
  '1 +',
  'x = )',
  '',
  'for i in range(3):',
  'class A:\n    x = 1\n\n',
];

final class _CbFile implements VfsFile {
  _CbFile(this.path, this.t, this.store);

  @override
  String path;
  final _T t;
  final Map<String, String> store;

  @override
  int get permissions => 0x1A4;

  @override
  VfsContent get content {
    t.add({'ev': 'host', 'op': 'read', 'path': path});
    return VfsText(store['v']!);
  }

  @override
  set content(VfsContent value) {
    t.add({
      'ev': 'host',
      'op': 'write',
      'path': path,
      'type': value.runtimeType.toString(),
      'text': value.text,
    });
    store['v'] = 'callback-saw:${value.text}';
  }
}

/// Runs every probe on [backend]; returns probe name -> outcome.
Future<Map<String, Map<String, Object?>>> runProbes(String backend) async {
  final res = <String, Map<String, Object?>>{};
  final repls = <MontyRepl>[];
  MontyRepl mk() {
    final r = MontyRepl();
    repls.add(r);
    return r;
  }

  Future<void> p(String name, Future<void> Function(_T t) body) async {
    final t = _T();
    String? err;
    try {
      await body(t);
    } on Object catch (e, st) {
      err = '$e\n$st';
    }
    for (final r in repls) {
      try {
        await r.dispose();
      } on Object {
        // A failed dispose is not part of the outcome.
      }
    }
    repls.clear();
    res[name] = {
      'probe': name,
      'engine': 'core',
      'backend': backend,
      'events': t.events,
      'runner_error': err,
    };
  }

  // ------------------------------------------------- suspension kinds
  await p('k_function', (t) async {
    final r = mk();
    await t.step(
      () => r.feedStart("g = 1\ny = f(2, k='é')\ny", externalFunctions: ['f']),
    );
    await t.step(() => r.resume(5));
  });
  await p('k_os', (t) async {
    final r = mk();
    await t.step(
      () => r.feedStart("from pathlib import Path\nPath('/x').read_text()"),
    );
    await t.step(() => r.resume('hi'));
  });
  await p('k_os_not_handled', (t) async {
    final r = mk();
    final x = await t.step(
      () => r.feedStart("from pathlib import Path\nPath('/x').read_text()"),
    );
    // No not-handled verb: the closest public substitute is
    // osCallNoHandlerDefault + resumeWithException, recorded as such.
    t.add({
      'ev': 'unsupported',
      'what': 'no not-handled resume; substitute osCallNoHandlerDefault',
    });
    final oc = x! as MontyOsCall;
    final d = osCallNoHandlerDefault(oc.operationName, [
      for (final a in oc.args) a.dartValue,
    ]);
    await t.step(() => r.resumeWithException(d.excType, d.message));
  });
  await p('k_name', (t) async {
    final r = mk();
    await t.step(() => r.feedStart('total = 1 + missing\ntotal'));
  });
  await p('k_future', (t) async {
    final r = mk();
    await t.step(
      () => r.feedStart(
        'async def m():\n    a = await f(1)\n    return a + 1\nawait m()',
        externalFunctions: ['f'],
      ),
    );
    final y = await t.step(r.resumeAsFuture);
    if (y is MontyResolveFutures) {
      await t.step(() => r.resolveFutures({y.pendingCallIds.first: 9}));
    }
  });
  await p('pos_utf8', (t) async {
    final r = mk();
    await t.step(
      () => r.feedStart("x = 'é'\ny = add(x, 2)", externalFunctions: ['add']),
    );
  });
  await p('pos_earlier_feed', (t) async {
    final r = mk();
    await r.feedRun('def helper(n):\n    return fetch(n)');
    await t.step(() => r.feedStart('helper(3)', externalFunctions: ['fetch']));
  });
  await p('pos_eval', (t) async {
    final r = mk();
    await t.step(
      () => r.feedStart("eval('  1 + fetch()')", externalFunctions: ['fetch']),
    );
  });
  await p('inputs_typed', (t) async {
    final r = mk();
    t.add({'ev': 'unsupported', 'what': 'feedStart has no inputs parameter'});
    // Closest public path: the literal encoder feedRun uses, prepended.
    try {
      final code = inputsToCode({
        'b': Uint8List.fromList([0, 255]),
        'n': BigInt.two.pow(70),
        's': [
          [1],
          [1],
        ],
      });
      await t.step(
        () => r.feedStart('$code\nf(b, n, s)\n', externalFunctions: ['f']),
      );
    } on Object catch (e) {
      t.add({'ev': 'refused', 'cls': e.runtimeType.toString(), 'msg': '$e'});
    }
  });
  await p('auto_interleave', (t) async {
    t.add({
      'ev': 'unsupported',
      'what': 'no resume_auto / captured-handler suspension',
    });
    // Closest workflow: feedRun runs to completion in one call.
    final a = mk();
    await t.result(
      () => a.feedRun(
        'r = [h(1), h(2)]\nr',
        externalFunctions: {
          'h': (args, _) {
            t.add({
              'ev': 'handler',
              'who': 'A',
              'args': [dartToCanon(args.first)],
            });
            return (args.first! as int) * 10;
          },
        },
      ),
    );
  });
  await p('async_gather', (t) async {
    final r = mk();
    await t.result(
      () => r.feedRun(
        'import asyncio\nawait asyncio.gather(af(1), af(2))',
        externalAsyncFunctions: {
          'af': (args, _) async {
            final n = args.first! as int;
            t.add({
              'ev': 'handler',
              'who': 'af',
              'args': [dartToCanon(n)],
            });
            await Future<void>.delayed(Duration(milliseconds: 10 * (3 - n)));
            return n * 10;
          },
        },
      ),
    );
  });
  await p('abortctl_future', (t) async {
    final r = mk();
    await r.feedRun('g = 1');
    var x = await t.step(
      () => r.feedStart(
        'async def m():\n    try:\n        return await f(1)\n'
        '    except BaseException as e:\n        return "caught"\nawait m()',
        externalFunctions: ['f'],
      ),
    );
    if (x is MontyPending) x = await t.step(r.resumeAsFuture);
    if (x is MontyResolveFutures) {
      final id = x.pendingCallIds.first;
      await t.step(() => r.resolveFutures({}, errors: {id: 'aborted'}));
    }
    await t.step(() => r.feedStart('g'));
  });
  await p('abandon', (t) async {
    final r = mk();
    await t.step(() => r.feedStart('g = 2\nf(1)', externalFunctions: ['f']));
    await t.step(() => r.feedStart('g'));
    await t.step(() => r.resume(5));
    await t.step(() => r.feedStart('g'));
  });

  // ------------------------------------------------------ API surface
  await p('api_run_blocking', (t) async {
    final pm = createPlatformMonty();
    try {
      final r = await pm.run('x = 21\nx * 2');
      t.add({'ev': 'complete', 'value': montyToCanon(r.value)});
      try {
        final r2 = await pm.run('1 / 0');
        t.add(
          r2.error != null
              ? {
                  'ev': 'error',
                  'type': r2.error!.excType,
                  'message': r2.error!.message,
                }
              : {'ev': 'complete', 'value': montyToCanon(r2.value)},
        );
      } on Object catch (e) {
        t.add({'ev': 'error', ..._excObs(e)});
      }
    } finally {
      await pm.dispose();
    }
    final m = await Monty('x * 2').run(inputs: {'x': 21});
    t.add({'ev': 'complete', 'value': montyToCanon(m.value)});
  });
  await p('api_start_program', (t) async {
    final pm = createPlatformMonty();
    try {
      final s = await pm.start(
        'y = fetch(1, k=2)\ny + 1',
        externalFunctions: ['fetch'],
      );
      if (s is MontyPending) {
        t.add({
          'ev': 'suspend',
          'name': s.functionName,
          'args': [for (final a in s.args) montyToCanon(a)],
          'kwargs': {
            for (final e in (s.kwargs ?? const {}).entries)
              e.key: montyToCanon(e.value),
          },
        });
        final d = await pm.resume(10);
        if (d is MontyComplete) {
          t.add({'ev': 'complete', 'value': montyToCanon(d.result.value)});
        } else {
          t.add({'ev': 'other', 'repr': '$d'});
        }
      } else {
        t.add({'ev': 'other', 'repr': '$s'});
      }
    } finally {
      await pm.dispose();
    }
  });
  await p('api_interactive_continuation', (t) async {
    final r = mk();
    for (final s in continuationSources) {
      t.add({
        'ev': 'mode',
        'src': s,
        'mode': (await r.detectContinuation(s)).name,
      });
    }
  });
  await p('api_create_repl', (t) async {
    final r = mk();
    await r.feedRun('x = 41\ndef inc(v):\n    return v + 1');
    t.add({
      'ev': 'complete',
      'value': montyToCanon((await r.feedRun('inc(x)')).value),
    });
  });
  await p('api_recover_repl_after_error', (t) async {
    final r = mk();
    await r.feedRun('x = 1');
    for (final code in [
      '1 / 0',
      'def r():\n    return r()\nr()',
      'x = (',
      'undefined_name',
    ]) {
      Map<String, Object?>? error;
      try {
        final res = await r.feedRun(code);
        if (res.error != null) {
          error = {'type': res.error!.excType, 'message': res.error!.message};
        }
      } on Object catch (e) {
        error = _excObs(e);
      }
      if (error == null) {
        t.add({'ev': 'no_error', 'code': code});
      } else {
        t.add({
          'ev': 'error',
          'code': code,
          ...error,
          'after': montyToCanon((await r.feedRun('x + 1')).value),
        });
      }
    }
  });
  await p('api_ext_result_resume', (t) async {
    final r = mk();
    Future<MontyProgress> start() =>
        r.feedStart(_extResultCode, externalFunctions: ['f']);
    void done(MontyProgress d) => t.add(
      d is MontyComplete
          ? {'ev': 'complete', 'value': montyToCanon(d.result.value)}
          : {'ev': 'other', 'repr': '$d'},
    );
    await start();
    done(await r.resume(5));
    await start();
    done(await r.resumeWithException('ValueError', 'bad'));
    final s = await r.feedStart('r = await f()\nr', externalFunctions: ['f']);
    final cid = (s as MontyPending).callId;
    await r.resumeAsFuture();
    done(await r.resolveFutures({cid: 7}));
    await start();
    done(await r.resumeNotFound('f'));
  });
  await p('api_ext_result_callback', (t) async {
    final r = mk();
    final res = await r.feedRun(
      _extResultCode,
      externalFunctions: {
        'f': (a, k) => throw const OsCallException(
          'bad',
          pythonExceptionType: 'ValueError',
        ),
      },
    );
    t.add(
      res.error != null
          ? {
              'ev': 'error',
              'type': res.error!.excType,
              'message': res.error!.message,
            }
          : {'ev': 'complete', 'value': montyToCanon(res.value)},
    );
  });
  await p('api_ext_args_values', (t) async {
    final r = mk();
    final s =
        await r.feedStart(_extArgsCode, externalFunctions: ['f'])
            as MontyPending;
    t.add({
      'ev': 'suspend',
      'name': s.functionName,
      'args': [for (final a in s.args) montyToCanon(a)],
      'kwargs': {
        for (final e in (s.kwargs ?? const {}).entries)
          e.key: montyToCanon(e.value),
      },
    });
    await r.resume(null);
  });
  await p('api_ext_args_identity', (t) async {
    final r = mk();
    final s =
        await r.feedStart(_extArgsCode, externalFunctions: ['f'])
            as MontyPending;
    t.add({'ev': 'identity', 'shared': identical(s.args[2], s.args[3])});
    await r.resume(null);
  });
  await p('api_futures_gather', (t) async {
    final r = mk();
    var s = await r.feedStart(
      'import asyncio\nr = await asyncio.gather(f(1), f(2))\nr',
      externalFunctions: ['f'],
    );
    final ids = <int>[];
    while (s is MontyPending) {
      ids.add(s.callId);
      s = await r.resumeAsFuture();
    }
    t.add({
      'ev': 'pending',
      'count': s is MontyResolveFutures ? s.pendingCallIds.length : -1,
    });
    final d = await r.resolveFutures({ids[0]: 10, ids[1]: 20});
    t.add(
      d is MontyComplete
          ? {'ev': 'complete', 'value': montyToCanon(d.result.value)}
          : {'ev': 'other', 'repr': '$d'},
    );
  });
  await p('api_futures_error', (t) async {
    final r = mk();
    const code = '''
try:
    r = await f(1)
except ValueError as e:
    r = "caught ValueError: " + str(e)
except RuntimeError as e:
    r = "caught RuntimeError: " + str(e)
r''';
    final s = await r.feedStart(code, externalFunctions: ['f']);
    final cid = (s as MontyPending).callId;
    await r.resumeAsFuture();
    final d = await r.resolveFutures({}, errors: {cid: 'boom'});
    t.add(
      d is MontyComplete
          ? {'ev': 'complete', 'value': montyToCanon(d.result.value)}
          : {'ev': 'other', 'repr': '$d'},
    );
  });
  Future<void> writeBudget(_T t, int feed) async {
    final h = memoryMountedOsHandler(
      mounts: const [MountDir(virtualPath: '/data', writeBytesLimit: 10)],
      files: [],
    );
    final r = mk();
    for (final n in [1, 2]) {
      final v = (await r.feedRun(_wCode, osHandler: h)).value;
      if (n == feed) t.add({'ev': 'complete', 'value': montyToCanon(v)});
    }
  }

  await p('api_write_budget_feed1', (t) => writeBudget(t, 1));
  await p('api_write_budget_feed2', (t) => writeBudget(t, 2));
  await p('api_memory_budget', (t) async {
    final h = memoryMountedOsHandler(
      mounts: const [MountDir(virtualPath: '/data', memoryUsageLimit: 1000)],
      files: [],
    );
    final r = await Monty(_mCode).run(osHandler: h);
    t.add({'ev': 'complete', 'value': montyToCanon(r.value)});
  });
  await p('api_callback_files', (t) async {
    final store = {'v': 'initial'};
    final h = memoryMountedOsHandler(
      mounts: const [MountDir(virtualPath: '/cb')],
      files: [_CbFile('/cb/f.txt', t, store)],
    );
    const code =
        "from pathlib import Path\np = Path('/cb/f.txt')\na = p.read_text()\n"
        "p.write_text('new')\nb = p.read_text()\n(a, b, p.exists())";
    final r = await Monty(code).run(osHandler: h);
    t.add(
      r.error != null
          ? _errEv(r.error!)
          : {'ev': 'complete', 'value': montyToCanon(r.value)},
    );
  });
  await p('api_boundary_uuid', (t) async {
    final r = mk();
    await r.feedRun('class A:\n    pass\na1 = A()\na2 = A()');
    final i1 = (await r.feedRun('a1')).value;
    final i1b = (await r.feedRun('a1')).value;
    final i2 = (await r.feedRun('a2')).value;
    final uuidRe = RegExp(
      r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
    );
    String? id(MontyValue v) => v is MontyClassInstance ? v.instanceId : null;
    t.add({
      'ev': 'ids',
      'is_uuid': id(i1) != null && uuidRe.hasMatch(id(i1)!),
      'stable': id(i1) != null && id(i1) == id(i1b),
      'distinct': id(i1) != null && id(i1) != id(i2),
    });
  });
  await p('api_fork_session', (t) async {
    final r1 = mk();
    final r2 = mk();
    final r3 = mk();
    await r1.feedRun('x = [1]');
    final b = await r1.snapshot();
    final copy = Uint8List.fromList(b);
    await r2.restore(b);
    await r2.feedRun('x.append(2)');
    final v2 = montyToCanon((await r2.feedRun('x')).value);
    await r3.restore(b);
    final v3 = montyToCanon((await r3.feedRun('x')).value);
    var same = copy.length == b.length;
    for (var i = 0; same && i < b.length; i++) {
      same = copy[i] == b[i];
    }
    t.add({'ev': 'fork', 'fork_a': v2, 'fork_b': v3, 'bytes_unchanged': same});
  });
  await p('api_reset_type_checker', (t) async {
    final same = await Monty.typeCheck(
      'y: int = x\ny',
      prefixCode: 'x: int = 1',
    );
    t.add({
      'ev': 'checked',
      'with_prior_definition': same.isEmpty ? 'ok' : 'MontyTypingError',
    });
    final fresh = await Monty.typeCheck('y: int = x\ny');
    t.add({
      'ev': 'checked',
      'fresh_unresolved': fresh.any((e) => e.code == 'unresolved-reference'),
    });
  });
  await p('api_compile_program', (t) async {
    final pm = createPlatformMonty();
    try {
      await (pm as dynamic).compileCode('x = 1\nx + 1');
      t.add({'ev': 'compiled'});
      // The member is gone, not refused: that difference is the measurement.
      // ignore: avoid_catching_errors
    } on NoSuchMethodError {
      t.add({'ev': 'absent', 'what': 'no compile API'});
    } on Object catch (e) {
      t.add({'ev': 'refused', 'cls': e.runtimeType.toString(), 'msg': '$e'});
    } finally {
      await pm.dispose();
    }
  });
  await p('api_compiled_source', (t) async {
    final Object m = Monty('x * 2');
    try {
      t.add({'ev': 'code', 'code': (m as dynamic).code});
      // The member is gone, not refused: that difference is the measurement.
      // ignore: avoid_catching_errors
    } on NoSuchMethodError {
      t.add({'ev': 'absent', 'what': 'Monty has no code accessor'});
    }
  });
  await p('api_eager_coroutine', (t) async {
    final r = mk();
    for (final (key, code) in [
      ('sync_call', 'r = f()\nr'),
      ('await_call', 'r = await f()\nr'),
    ]) {
      final s = await r.feedStart(code, externalFunctions: ['f']);
      try {
        t.add({'ev': 'eager', key: (s as dynamic).allowEagerAwait});
        // The member is gone, not refused: that difference is the measurement.
        // ignore: avoid_catching_errors
      } on NoSuchMethodError {
        t.add({'ev': 'absent', 'what': 'no allowEagerAwait on a suspension'});
      }
      try {
        await r.resume(1);
      } on Object {
        // Resuming the awaited call with a plain value may fail; the probe is
        // about the flag, not the resume.
      }
    }
  });
  return res;
}
