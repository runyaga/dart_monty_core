// The contract scenarios (C4 contract-suite.md): each is a Python program
// for a real session and the script that stands for it on the fake, with
// the host code both run and the trace and answers both must show. The
// expected lists were read from the worker (upstream 1.1.0) and reviewed;
// the fake is held to them.
//
// The expected entries are the worker's text verbatim, one entry a line,
// so a mismatch reads against them directly; some are longer than 80.
// ignore_for_file: lines_longer_than_80_chars
import 'dart:async';

import 'package:collection/collection.dart';

import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_exception.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/os_policy.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';

import '_contract.dart';

const MontyValue _none = MontyNone();

const _pendingFeed = 'feed called while a suspension is awaiting an answer';

const _catchB =
    'a = fa()\nb = fb()\nx = await a\n'
    'try:\n    await b\nexcept ValueError:\n    pass\nx';

const _sleeps =
    'import asyncio\n'
    'await asyncio.gather(asyncio.sleep(0, result=1), '
    'asyncio.sleep(0, result=2))';

const _branches =
    'import asyncio\n'
    'async def one():\n    v = await f(1)\n    return await g(v)\n'
    'async def two():\n    return await f(2)\n'
    'await asyncio.gather(one(), two())';

MontyInt _int(int n) => MontyInt(n);

MontyString _str(String s) => MontyString(s);

/// An OS handler that declines every call.
MontyValue _decline(
  String name,
  List<MontyValue> a,
  Map<String, MontyValue> k,
) => throw const OsCallNotHandledException();

/// A coroutine body that completes after [ms] milliseconds with [value].
Body _after(int ms, MontyValue value) =>
    (_, _) => Future.delayed(Duration(milliseconds: ms), () => value);

/// A coroutine body that fails after [ms] milliseconds.
Body _failAfter(int ms, String message) =>
    (_, _) => Future.delayed(
      Duration(milliseconds: ms),
      () => throw ExternalException('ValueError', message),
    );

/// Records each frame of the error a feed ends with: the fake's comes from
/// `willRaise(line:, column:)` (frames.md, naming.md).
Future<void> _runWithFrames(Side s, int i) async {
  await s.run(i);
  final error = s.errors.lastOrNull;
  if (error is MontyRuntimeError && error.traceback.isNotEmpty) {
    final f = error.traceback.last;
    s.trace.add(
      'frame ${f.filename} ${f.line}:${f.column} ${f.functionName}',
    );
  }
}

/// Every scenario.
final List<Scenario> scenarios = [
  Scenario(
    'a call answered with a value',
    feeds: ['f(1, k=2) + 1'],
    script: (f) => f
      ..willCall('f', args: [_int(1)], kwargs: {'k': _int(2)})
      ..willReturn(_int(42)),
    run: (s) => s.run(0, externals: {'f': s.fn('f', (_, _) => _int(41))}),
    trace: [
      'call f(MontyInt(1), k=MontyInt(2))',
      'value MontyInt(42)',
    ],
    answers: [
      '0 value MontyInt(41)',
    ],
  ),
  Scenario(
    'a call that throws ExternalException',
    feeds: ['f()'],
    script: (f) => f
      ..willCall('f')
      ..willReturn(_none),
    run: (s) => s.run(
      0,
      externals: {
        'f': s.fn(
          'f',
          (_, _) => throw const ExternalException('ValueError', 'bad'),
        ),
      },
    ),
    trace: [
      'call f()',
      'MontyRuntimeError ValueError: bad | ValueError: bad',
    ],
    answers: [
      '0 raise ValueError: bad',
    ],
  ),
  Scenario(
    'a call that throws a StateError',
    feeds: ['f()'],
    script: (f) => f
      ..willCall('f')
      ..willReturn(_none),
    run: (s) => s.run(
      0,
      externals: {'f': s.fn('f', (_, _) => throw StateError('broken'))},
    ),
    trace: [
      'call f()',
      'MontyRuntimeError Exception: Bad state: broken | Exception: Bad state: broken',
    ],
    answers: [
      '0 raise Exception: Bad state: broken',
    ],
  ),
  Scenario(
    'a call to a name missing from the externals',
    feeds: ['f()'],
    script: (f) => f
      ..willCall('f')
      ..willReturn(_none),
    run: (s) => s.run(0),
    trace: [
      "MontyRuntimeError NameError: name 'f' is not defined | NameError: name 'f' is not defined",
    ],
    answers: [
      '0 none',
    ],
  ),
  Scenario(
    'a handler throwing ExternalException(SyntaxError)',
    feeds: ['f()'],
    script: (f) => f
      ..willCall('f')
      ..willReturn(_none),
    run: (s) => s.run(
      0,
      externals: {
        'f': s.fn(
          'f',
          (_, _) => throw const ExternalException('SyntaxError', 'no'),
        ),
      },
    ),
    trace: [
      'call f()',
      'MontySyntaxError SyntaxError: no | no',
    ],
    answers: [
      '0 raise SyntaxError: no',
    ],
  ),
  Scenario(
    'an OS call answered',
    feeds: ["import os\nos.getenv('A')"],
    script: (f) => f
      ..willCallOs('os.getenv', args: [_str('A'), _none])
      ..willReturn(_str('x')),
    run: (s) => s.run(0, os: s.os((_, _, _) => _str('x'))),
    trace: [
      'os os.getenv(MontyString("A"), MontyNone())',
      'value MontyString("x")',
    ],
    answers: [
      '0 value MontyString("x")',
    ],
  ),
  Scenario(
    'a filesystem OS call declined',
    feeds: ["from pathlib import Path\nPath('/a/b.txt').read_text()"],
    script: (f) => f
      ..willCallOs('Path.read_text', args: [const MontyPath('/a/b.txt')])
      ..willReturn(_none),
    run: (s) => s.run(0, os: s.os(_decline)),
    trace: [
      'os Path.read_text(MontyPath("/a/b.txt"))',
      "MontyRuntimeError PermissionError: Permission denied: '/a/b.txt' | PermissionError: Permission denied: '/a/b.txt'",
    ],
    answers: [
      '0 none',
    ],
  ),
  Scenario(
    'a declined path is written as Python writes a str',
    feeds: ["from pathlib import Path\nPath(\"/a'b\").exists()"],
    script: (f) => f
      ..willCallOs('Path.exists', args: [const MontyPath("/a'b")])
      ..willReturn(_none),
    run: (s) => s.run(0, os: s.os(_decline)),
    trace: [
      'os Path.exists(MontyPath("/a\'b"))',
      'MontyRuntimeError PermissionError: Permission denied: "/a\'b" | PermissionError: Permission denied: "/a\'b"',
    ],
    answers: [
      '0 none',
    ],
  ),
  Scenario(
    'a non-filesystem OS call declined',
    feeds: ["import os\nos.getenv('A')"],
    script: (f) => f
      ..willCallOs('os.getenv', args: [_str('A'), _none])
      ..willReturn(_none),
    run: (s) => s.run(0, os: s.os(_decline)),
    trace: [
      'os os.getenv(MontyString("A"), MontyNone())',
      "MontyRuntimeError RuntimeError: 'os.getenv' is not supported in this environment | RuntimeError: 'os.getenv' is not supported in this environment",
    ],
    answers: [
      '0 none',
    ],
  ),
  Scenario(
    'a name lookup found',
    feeds: ['g = x\ng(3)'],
    script: (f) => f
      ..willLookUp('x')
      ..willCall('x', args: [_int(3)])
      ..willReturn(_int(9)),
    run: (s) => s.run(0, externals: {'x': s.fn('x', (_, _) => _int(9))}),
    trace: [
      'call x(MontyInt(3))',
      'value MontyInt(9)',
    ],
    answers: [
      '- value MontyString("x")',
      '0 value MontyInt(9)',
    ],
  ),
  Scenario(
    'a name lookup undefined',
    feeds: ['x + 1'],
    script: (f) => f
      ..willLookUp('x')
      ..willReturn(_none),
    run: (s) => s.run(0),
    trace: [
      "MontyRuntimeError NameError: name 'x' is not defined | NameError: name 'x' is not defined",
    ],
    answers: [
      '- none',
    ],
  ),
  Scenario(
    'prints before a call and after it',
    feeds: ["print('before')\nf()\nprint('after', end='')\nprint('!')\n7"],
    script: (f) => f
      ..willPrint('before\n')
      ..willCall('f')
      ..willPrint('after')
      ..willPrint('!\n')
      ..willReturn(_int(7)),
    run: (s) => s.run(0, externals: {'f': s.fn('f')}),
    trace: [
      'print[stdout] before\n',
      'call f()',
      'print[stdout] after!\n',
      'value MontyInt(7)',
    ],
    answers: [
      '0 value MontyNone()',
    ],
  ),
  Scenario(
    'a raised exception ends the feed',
    feeds: ["raise ValueError('boom')"],
    script: (f) => f.willRaise('ValueError', message: 'boom'),
    run: (s) => s.run(0),
    trace: [
      'MontyRuntimeError ValueError: boom | ValueError: boom',
    ],
    answers: [],
  ),
  Scenario(
    'a raised exception with attributes',
    feeds: ["import json\njson.loads('{')"],
    script: (f) => f.willRaise(
      'json.JSONDecodeError',
      message: "Expecting ',' delimiter: line 1 column 2 (char 1)",
      attributes: {
        'msg': _str("Expecting ',' delimiter"),
        'doc': _str('{'),
        'pos': _int(1),
        'lineno': _int(1),
        'colno': _int(2),
      },
    ),
    run: (s) => s.run(0),
    trace: [
      "MontyRuntimeError json.JSONDecodeError: Expecting ',' delimiter: line 1 column 2 (char 1) {msg: MontyString(Expecting ',' delimiter), doc: MontyString({), pos: MontyInt(1), lineno: MontyInt(1), colno: MontyInt(2)} | json.JSONDecodeError: Expecting ',' delimiter: line 1 column 2 (char 1)",
    ],
    answers: [],
  ),
  Scenario(
    'a caught answer: willCatch',
    feeds: ['try:\n    f()\nexcept Exception:\n    pass\n5'],
    script: (f) => f
      ..willCall('f')
      ..willCatch()
      ..willReturn(_int(5)),
    run: (s) => s.run(
      0,
      externals: {
        'f': s.fn(
          'f',
          (_, _) => throw const ExternalException('KeyError', 'k'),
        ),
      },
    ),
    trace: [
      'call f()',
      'value MontyInt(5)',
    ],
    answers: [
      '0 raise KeyError: k',
    ],
  ),
  Scenario(
    'manual driving: a call',
    feeds: ['f(1) + 1'],
    script: (f) => f
      ..willCall('f', args: [_int(1)])
      ..willReturn(_int(3)),
    run: (s) async {
      final call = await s.start(0);
      await s.next<FunctionSnapshot>(
        call,
        (c) => c.resume(ExternalReturnValue(_int(2))),
      );
    },
    trace: [
      'snap call f#0(MontyInt(1))',
      'complete MontyInt(3)',
    ],
    answers: [
      '0 value MontyInt(2)',
    ],
  ),
  Scenario(
    'manual driving: an OS call answered, then one not handled',
    feeds: ["import os\nos.getenv('A') + os.getenv('B')"],
    script: (f) => f
      ..willCallOs('os.getenv', args: [_str('A'), _none])
      ..willCallOs('os.getenv', args: [_str('B'), _none])
      ..willReturn(_none),
    run: (s) async {
      final first = await s.start(0);
      final second = await s.next<FunctionSnapshot>(
        first,
        (c) => c.resume(ExternalReturnValue(_str('a'))),
      );
      await s.next<FunctionSnapshot>(second, (c) => c.resumeNotHandled());
    },
    trace: [
      'snap os os.getenv#0(MontyString("A"), MontyNone())',
      'snap os os.getenv#1(MontyString("B"), MontyNone())',
      "MontyRuntimeError RuntimeError: 'os.getenv' is not supported in this environment | RuntimeError: 'os.getenv' is not supported in this environment",
    ],
    answers: [
      '0 value MontyString("a")',
      '1 none',
    ],
  ),
  Scenario(
    'manual driving: a lookup, then resumeAuto',
    feeds: ['x + y'],
    script: (f) => f
      ..willLookUp('x')
      ..willLookUp('y')
      ..willReturn(_none),
    run: (s) async {
      final x = await s.start(0);
      final y = await s.next<NameLookupSnapshot>(
        x,
        (l) => l.resume(value: _int(1)),
      );
      await s.next<NameLookupSnapshot>(y, (l) => l.resumeAuto());
    },
    trace: [
      'snap lookup x',
      'snap lookup y',
      "MontyRuntimeError NameError: name 'y' is not defined | NameError: name 'y' is not defined",
    ],
    answers: [
      '- value MontyInt(1)',
      '- none',
    ],
  ),
  Scenario(
    'manual driving: a future',
    feeds: ['t = f()\nawait t'],
    script: (f) => f
      ..willCall('f')
      ..willAwait([0])
      ..willReturn(_int(5)),
    run: (s) async {
      final call = await s.start(0);
      final wait = await s.next<FunctionSnapshot>(
        call,
        (c) => c.resume(const ExternalFuture()),
      );
      await s.next<FutureSnapshot>(
        wait,
        (w) => w.resume({0: ExternalReturnValue(_int(5))}),
      );
    },
    trace: [
      'snap call f#0()',
      'snap futures [0]',
      'complete MontyInt(5)',
    ],
    answers: [
      '0 future',
      '0/b0 value MontyInt(5)',
    ],
  ),
  Scenario(
    'close during a host callback',
    feeds: ['f()\n1', '2'],
    script: (f) => f
      ..willCall('f')
      ..willReturn(_int(1)),
    run: (s) async {
      await s.run(
        0,
        externals: {
          'f': s.fn('f', (_, _) async {
            await s.session.close();

            return _none;
          }),
        },
      );
      await s.run(1);
    },
    trace: [
      'call f()',
      'StateError: Bad state: the session is finished',
      'StateError: Bad state: the session is finished',
    ],
    answers: [],
  ),
  Scenario(
    'two concurrent feeds',
    feeds: ['f()', '2'],
    script: (f) => f
      ..willCall('f')
      ..willReturn(_int(1)),
    // Each feed's end is recorded in feed order: which one ends first is
    // the platform's scheduling, not the session's.
    run: (s) async => s.trace.addAll(
      await Future.wait([
        s.outcome(
          () => s.session.feedRun(
            s.code(0),
            externals: {'f': s.fn('f', (_, _) => _int(1))},
          ),
        ),
        s.outcome(() => s.session.feedRun(s.code(1))),
      ]),
    ),
    trace: [
      'call f()',
      'value MontyInt(1)',
      'StateError: Bad state: $_pendingFeed',
    ],
    answers: [
      '0 value MontyInt(1)',
    ],
  ),
  Scenario(
    'two concurrent feeds, neither suspending',
    feeds: ['1', '2'],
    script: (f) => f
      ..willReturn(_int(1))
      ..willReturn(_int(2)),
    run: (s) => Future.wait([s.run(0), s.run(1)]),
    trace: [
      'value MontyInt(1)',
      'value MontyInt(2)',
    ],
    answers: [],
  ),
  Scenario(
    'OS calls and host calls share one id count',
    feeds: ["import os\nos.getenv('A')\nf()\nos.getenv('B')"],
    script: (f) => f
      ..willCallOs('os.getenv', args: [_str('A'), _none])
      ..willCall('f')
      ..willCallOs('os.getenv', args: [_str('B'), _none])
      ..willReturn(_str('x')),
    run: (s) => s.run(
      0,
      externals: {'f': s.fn('f')},
      os: s.os((_, _, _) => _str('x')),
    ),
    trace: [
      'os os.getenv(MontyString("A"), MontyNone())',
      'call f()',
      'os os.getenv(MontyString("B"), MontyNone())',
      'value MontyString("x")',
    ],
    answers: [
      '0 value MontyString("x")',
      '1 value MontyNone()',
      '2 value MontyString("x")',
    ],
  ),
  Scenario(
    'call ids restart with each feed (feedRun)',
    feeds: ['f() + f()', 'f() + f()', 'f()'],
    script: (f) => f
      ..willCall('f')
      ..willCall('f')
      ..willReturn(_int(2))
      ..willCall('f')
      ..willCall('f')
      ..willReturn(_int(2))
      ..willCall('f')
      ..willReturn(_int(1)),
    run: (s) async {
      final ext = {'f': s.fn('f', (_, _) => _int(1))};
      await s.run(0, externals: ext);
      await s.run(1, externals: ext);
      await s.run(2, externals: ext);
    },
    trace: [
      'call f()',
      'call f()',
      'value MontyInt(2)',
      'call f()',
      'call f()',
      'value MontyInt(2)',
      'call f()',
      'value MontyInt(1)',
    ],
    answers: [
      '0 value MontyInt(1)',
      '1 value MontyInt(1)',
      '0 value MontyInt(1)',
      '1 value MontyInt(1)',
      '0 value MontyInt(1)',
    ],
  ),
  Scenario(
    'call ids restart with each feed (feedStart)',
    feeds: ['f() + f()', 'f() + f()', 'f()'],
    script: (f) => f
      ..willCall('f')
      ..willCall('f')
      ..willReturn(_int(2))
      ..willCall('f')
      ..willCall('f')
      ..willReturn(_int(2))
      ..willCall('f')
      ..willReturn(_int(1)),
    run: (s) async {
      for (var i = 0; i < 3; i++) {
        var snap = await s.start(i);
        while (snap is FunctionSnapshot) {
          final call = snap;
          snap = await s.step(() => call.resume(ExternalReturnValue(_int(1))));
        }
      }
    },
    trace: [
      'snap call f#0()',
      'snap call f#1()',
      'complete MontyInt(2)',
      'snap call f#0()',
      'snap call f#1()',
      'complete MontyInt(2)',
      'snap call f#0()',
      'complete MontyInt(1)',
    ],
    answers: [
      '0 value MontyInt(1)',
      '1 value MontyInt(1)',
      '0 value MontyInt(1)',
      '1 value MontyInt(1)',
      '0 value MontyInt(1)',
    ],
  ),
  Scenario(
    'settled futures carry their call ids, feed after feed',
    feeds: ['a = f()\nb = f()\nawait a + await b', 'await f()'],
    script: (f) => f
      ..willCall('f')
      ..willCall('f')
      ..willAwait([0])
      ..willAwait([1])
      ..willReturn(_int(2))
      ..willCall('f', eager: true)
      ..willReturn(_int(1)),
    run: (s) async {
      // The second future settles well after the first, so the batches
      // do not depend on the machine's timing.
      var calls = 0;
      final ext = {
        'f': s.async(
          'f',
          (a, k) => _after(calls++ == 0 ? 0 : 150, _int(1))(a, k),
        ),
      };
      await s.run(0, externals: ext);
      await s.run(1, externals: ext);
    },
    trace: [
      'call f()',
      'call f()',
      'value MontyInt(2)',
      'call f()',
      'value MontyInt(1)',
    ],
    answers: [
      '0 future',
      '1 future',
      '0/b0 value MontyInt(1)',
      '1/b1 value MontyInt(1)',
      '0/b0 value MontyInt(1)',
    ],
  ),
  Scenario(
    'a feed that ends early, then one that does not',
    feeds: ['g()\nf()', 'f()'],
    script: (f) => f
      ..willCall('g')
      ..willCall('f')
      ..willReturn(_none)
      ..willCall('f')
      ..willReturn(_int(1)),
    run: (s) async {
      final ext = {
        'g': s.fn(
          'g',
          (_, _) => throw const ExternalException('ValueError', 'g'),
        ),
        'f': s.fn('f', (_, _) => _int(1)),
      };
      await s.run(0, externals: ext);
      await s.run(1, externals: ext);
    },
    trace: [
      'call g()',
      'MontyRuntimeError ValueError: g | ValueError: g',
      'call f()',
      'value MontyInt(1)',
    ],
    answers: [
      '0 raise ValueError: g',
      '0 value MontyInt(1)',
    ],
  ),
  Scenario(
    'an eager awaited call answered by a coroutine',
    feeds: ['await f()'],
    script: (f) => f
      ..willCall('f', eager: true)
      ..willReturn(_int(3)),
    run: (s) =>
        s.run(0, externals: {'f': s.async('f', (_, _) async => _int(3))}),
    trace: [
      'call f()',
      'value MontyInt(3)',
    ],
    answers: [
      '0/b0 value MontyInt(3)',
    ],
  ),
  Scenario(
    'an eager awaited coroutine that fails',
    feeds: ['await f()'],
    script: (f) => f
      ..willCall('f', eager: true)
      ..willReturn(_none),
    run: (s) => s.run(0, externals: {'f': s.async('f', _failAfter(0, 'e'))}),
    trace: [
      'call f()',
      'MontyRuntimeError ValueError: e | ValueError: e',
    ],
    answers: [
      '0/b0 raise ValueError: e',
    ],
  ),
  Scenario(
    'two gathered calls settling in the opposite order',
    feeds: ['import asyncio\nawait asyncio.gather(f(0), f(1))'],
    script: (f) => f
      ..willCall('f', args: [_int(0)])
      ..willCall('f', args: [_int(1)])
      ..willAwait([0, 1], gathered: true)
      ..willAwait([0], gathered: true)
      ..willReturn(MontyList([_int(10), _int(11)])),
    run: (s) {
      final second = Completer<void>();

      return s.run(
        0,
        externals: {
          'f': s.async('f', (args, _) async {
            if (args.firstOrNull == _int(0)) {
              await second.future;
              await Future<void>.delayed(const Duration(milliseconds: 150));

              return _int(10);
            }
            second.complete();

            return _int(11);
          }),
        },
      );
    },
    trace: [
      'call f(MontyInt(0))',
      'call f(MontyInt(1))',
      'value MontyList[MontyInt(10), MontyInt(11)]',
    ],
    answers: [
      '0 future',
      '1 future',
      '1/b0 value MontyInt(11)',
      '0/b1 value MontyInt(10)',
    ],
  ),
  Scenario(
    'an async OS handler answering Path.read_text',
    feeds: ["from pathlib import Path\nPath('/f.txt').read_text()"],
    script: (f) => f
      ..willCallOs('Path.read_text', args: [const MontyPath('/f.txt')])
      ..willReturn(_str('hi')),
    run: (s) => s.run(0, os: s.os((_, _, _) async => _str('hi'))),
    trace: [
      'os Path.read_text(MontyPath("/f.txt"))',
      'value MontyString("hi")',
    ],
    answers: [
      '0 value MontyString("hi")',
    ],
  ),
  Scenario(
    'a plain value awaited: eager',
    feeds: ['await f()'],
    script: (f) => f
      ..willCall('f', eager: true)
      ..willReturn(_none),
    run: (s) => s.run(0, externals: {'f': s.fn('f', (_, _) => _int(1))}),
    trace: [
      'call f()',
      "MontyRuntimeError TypeError: 'int' object can't be awaited | TypeError: 'int' object can't be awaited",
    ],
    answers: [
      '0 value MontyInt(1)',
    ],
  ),
  Scenario(
    'a plain value awaited: manual resume on the eager snapshot',
    feeds: ['await f()'],
    script: (f) => f
      ..willCall('f', eager: true)
      ..willReturn(_none),
    run: (s) async {
      final call = await s.start(0);
      await s.next<FunctionSnapshot>(
        call,
        (c) => c.resume(ExternalReturnValue(_int(1))),
      );
    },
    trace: [
      'snap call f#0 eager()',
      "MontyRuntimeError TypeError: 'int' object can't be awaited | TypeError: 'int' object can't be awaited",
    ],
    answers: [
      '0 value MontyInt(1)',
    ],
  ),
  Scenario(
    'an eager call answered with a future by hand',
    feeds: ['await f()'],
    script: (f) => f
      ..willCall('f', eager: true)
      ..willReturn(_int(4)),
    run: (s) async {
      final call = await s.start(0);
      final wait = await s.next<FunctionSnapshot>(
        call,
        (c) => c.resume(const ExternalFuture()),
      );
      await s.next<FutureSnapshot>(
        wait,
        (w) => w.resume({0: ExternalReturnValue(_int(4))}),
      );
    },
    trace: [
      'snap call f#0 eager()',
      'snap futures [0]',
      'complete MontyInt(4)',
    ],
    answers: [
      '0 future',
      '0/b0 value MontyInt(4)',
    ],
  ),
  Scenario(
    'a gather settled in part, by hand, waits for the rest',
    feeds: ['import asyncio\nawait asyncio.gather(f(0), f(1))'],
    script: (f) => f
      ..willCall('f', args: [_int(0)])
      ..willCall('f', args: [_int(1)])
      ..willAwait([0, 1], gathered: true)
      ..willReturn(MontyList([_int(10), _int(11)])),
    run: (s) async {
      final first = await s.start(0);
      final second = await s.next<FunctionSnapshot>(
        first,
        (c) => c.resume(const ExternalFuture()),
      );
      final wait = await s.next<FunctionSnapshot>(
        second,
        (c) => c.resume(const ExternalFuture()),
      );
      final rest = await s.next<FutureSnapshot>(
        wait,
        (w) => w.resume({0: ExternalReturnValue(_int(10))}),
      );
      await s.next<FutureSnapshot>(
        rest,
        (w) => w.resume({1: ExternalReturnValue(_int(11))}),
      );
    },
    trace: [
      'snap call f#0(MontyInt(0))',
      'snap call f#1(MontyInt(1))',
      'snap futures [0, 1]',
      'snap futures [1]',
      'complete MontyList[MontyInt(10), MontyInt(11)]',
    ],
    answers: [
      '0 future',
      '1 future',
      '0/b0 value MontyInt(10)',
      '1/b1 value MontyInt(11)',
    ],
  ),
  Scenario(
    'a gather settled in part, then a print, waits for the rest first',
    feeds: [
      "import asyncio\nr = await asyncio.gather(f(0), f(1))\nprint('done')\nr",
    ],
    script: (f) => f
      ..willCall('f', args: [_int(0)])
      ..willCall('f', args: [_int(1)])
      ..willAwait([0, 1], gathered: true)
      ..willPrint('done\n')
      ..willReturn(MontyList([_int(10), _int(11)])),
    run: (s) async {
      final first = await s.start(0);
      final second = await s.next<FunctionSnapshot>(
        first,
        (c) => c.resume(const ExternalFuture()),
      );
      final wait = await s.next<FunctionSnapshot>(
        second,
        (c) => c.resume(const ExternalFuture()),
      );
      final rest = await s.next<FutureSnapshot>(
        wait,
        (w) => w.resume({0: ExternalReturnValue(_int(10))}),
      );
      await s.next<FutureSnapshot>(
        rest,
        (w) => w.resume({1: const ExternalException('ValueError', 'late')}),
      );
    },
    trace: [
      'snap call f#0(MontyInt(0))',
      'snap call f#1(MontyInt(1))',
      'snap futures [0, 1]',
      'snap futures [1]',
      'MontyRuntimeError ValueError: late | ValueError: late',
    ],
    answers: [
      '0 future',
      '1 future',
      '0/b0 value MontyInt(10)',
      '1/b1 raise ValueError: late',
    ],
  ),
  Scenario(
    'two failures in one batch raise in the batch order',
    feeds: ['import asyncio\nawait asyncio.gather(f(0), f(1))'],
    script: (f) => f
      ..willCall('f', args: [_int(0)])
      ..willCall('f', args: [_int(1)])
      ..willAwait([0, 1], gathered: true)
      ..willReturn(_none),
    run: (s) async {
      final first = await s.start(0);
      final second = await s.next<FunctionSnapshot>(
        first,
        (c) => c.resume(const ExternalFuture()),
      );
      final wait = await s.next<FunctionSnapshot>(
        second,
        (c) => c.resume(const ExternalFuture()),
      );
      await s.next<FutureSnapshot>(
        wait,
        (w) => w.resume({
          1: const ExternalException('ValueError', 'second'),
          0: const ExternalException('KeyError', 'first'),
        }),
      );
    },
    trace: [
      'snap call f#0(MontyInt(0))',
      'snap call f#1(MontyInt(1))',
      'snap futures [0, 1]',
      'MontyRuntimeError ValueError: second | ValueError: second',
    ],
    answers: [
      '0 future',
      '1 future',
      '1/b0 raise ValueError: second',
      '0/b0 raise KeyError: first',
    ],
  ),
  Scenario(
    'an OS call that is not a sleep is not awaitable',
    feeds: ["import os\nx = os.getenv('A')\nawait x"],
    script: (f) => f
      ..willCallOs('os.getenv', args: [_str('A'), _none])
      ..willAwait([0])
      ..willReturn(_none),
    run: (s) => s.run(0, os: s.os((_, _, _) => _str('hello'))),
    trace: [
      'os os.getenv(MontyString("A"), MontyNone())',
      "MontyRuntimeError TypeError: 'str' object can't be awaited | TypeError: 'str' object can't be awaited",
    ],
    answers: [
      '0 value MontyString("hello")',
    ],
  ),
  Scenario(
    'a futures batch naming an id the wait did not list',
    feeds: ['t = f()\nawait t'],
    script: (f) => f
      ..willCall('f')
      ..willAwait([0])
      ..willReturn(_none),
    run: (s) async {
      final call = await s.start(0);
      final wait = await s.next<FunctionSnapshot>(
        call,
        (c) => c.resume(const ExternalFuture()),
      );
      await s.next<FutureSnapshot>(
        wait,
        (w) => w.resume({99: ExternalReturnValue(_int(1))}),
      );
    },
    trace: [
      'snap call f#0()',
      'snap futures [0]',
      'MontyRuntimeError RuntimeError: unknown call_id 99, expected one of: [0] | RuntimeError: unknown call_id 99, expected one of: [0]',
    ],
    answers: [
      '0 future',
      '99/b0 value MontyInt(1)',
    ],
  ),
  Scenario(
    'gathered asyncio.sleep calls take plain values',
    feeds: [_sleeps],
    config: const SessionConfig(osPolicy: OsPolicy(sleep: 'call_host')),
    script: (f) => f
      ..willCallOs('asyncio.sleep', args: [const MontyFloat(0)])
      ..willCallOs('asyncio.sleep', args: [const MontyFloat(0)])
      ..willAwait([0, 1], gathered: true)
      ..willReturn(MontyList([_int(1), _int(2)])),
    run: (s) => s.run(0, os: s.os((_, _, _) => _none)),
    trace: [
      'os asyncio.sleep(MontyFloat(0.0))',
      'os asyncio.sleep(MontyFloat(0.0))',
      'value MontyList[MontyInt(1), MontyInt(2)]',
    ],
    answers: [
      '0 value MontyNone()',
      '2 value MontyNone()',
    ],
  ),
  Scenario(
    'an asyncio.sleep answered with a plain value takes a second id',
    feeds: [
      'import asyncio\nt = asyncio.sleep(0, result=1)\nf()\nawait t + 1',
    ],
    config: const SessionConfig(osPolicy: OsPolicy(sleep: 'call_host')),
    script: (f) => f
      ..willCallOs('asyncio.sleep', args: [const MontyFloat(0)])
      ..willCall('f')
      ..willAwait([0])
      ..willReturn(_int(2)),
    run: (s) =>
        s.run(0, externals: {'f': s.fn('f')}, os: s.os((_, _, _) => _none)),
    trace: [
      'os asyncio.sleep(MontyFloat(0.0))',
      'call f()',
      'value MontyInt(2)',
    ],
    answers: [
      '0 value MontyNone()',
      '2 value MontyNone()',
    ],
  ),
  Scenario(
    'a feed made while close is on its way is refused',
    feeds: ['1', '2'],
    script: (f) => f
      ..willReturn(_int(1))
      ..willReturn(_int(2)),
    run: (s) async {
      await s.run(0);
      final closing = s.session.close();
      await s.run(1);
      await closing;
    },
    trace: [
      'value MontyInt(1)',
      'StateError: Bad state: the session is finished',
    ],
    answers: [],
  ),
  Scenario(
    'a plain value awaited: deferred',
    feeds: ['x = f()\nawait x'],
    script: (f) => f
      ..willCall('f')
      ..willAwait([0])
      ..willReturn(_none),
    run: (s) => s.run(0, externals: {'f': s.fn('f', (_, _) => _int(1))}),
    trace: [
      'call f()',
      "MontyRuntimeError TypeError: 'int' object can't be awaited | TypeError: 'int' object can't be awaited",
    ],
    answers: [
      '0 value MontyInt(1)',
    ],
  ),
  Scenario(
    'plain values gathered: two',
    feeds: ['import asyncio\nawait asyncio.gather(f(), f())'],
    script: (f) => f
      ..willCall('f')
      ..willCall('f')
      ..willAwait([0, 1], gathered: true)
      ..willReturn(_none),
    run: (s) => s.run(0, externals: {'f': s.fn('f', (_, _) => _int(1))}),
    trace: [
      'call f()',
      'call f()',
      'MontyRuntimeError TypeError: An asyncio.Future, a coroutine or an awaitable is required | TypeError: An asyncio.Future, a coroutine or an awaitable is required',
    ],
    answers: [
      '0 value MontyInt(1)',
      '1 value MontyInt(1)',
    ],
  ),
  Scenario(
    'plain values gathered: one',
    feeds: ['import asyncio\nawait asyncio.gather(f())'],
    script: (f) => f
      ..willCall('f')
      ..willAwait([0], gathered: true)
      ..willReturn(_none),
    run: (s) => s.run(0, externals: {'f': s.fn('f', (_, _) => _int(1))}),
    trace: [
      'call f()',
      'MontyRuntimeError TypeError: An asyncio.Future, a coroutine or an awaitable is required | TypeError: An asyncio.Future, a coroutine or an awaitable is required',
    ],
    answers: [
      '0 value MontyInt(1)',
    ],
  ),
  Scenario(
    'B fails while A is awaited; A settles and the feed runs on',
    feeds: ['a = fa()\nb = fb()\nx = await a\nx'],
    script: (f) => f
      ..willCall('fa')
      ..willCall('fb')
      ..willAwait([0])
      ..willReturn(_int(1)),
    run: (s) => s.run(
      0,
      externals: {
        'fa': s.async('fa', _after(150, _int(1))),
        'fb': s.async('fb', _failAfter(0, 'b')),
      },
    ),
    trace: [
      'call fa()',
      'call fb()',
      'value MontyInt(1)',
    ],
    answers: [
      '0 future',
      '1 future',
      '1/b0 raise ValueError: b',
      '0/b1 value MontyInt(1)',
    ],
  ),
  Scenario(
    'B fails while A is awaited, then Python awaits B (uncaught)',
    feeds: ['a = fa()\nb = fb()\nx = await a\nawait b'],
    script: (f) => f
      ..willCall('fa')
      ..willCall('fb')
      ..willAwait([0])
      ..willAwait([1])
      ..willReturn(_none),
    run: (s) => s.run(
      0,
      externals: {
        'fa': s.async('fa', _after(150, _int(1))),
        'fb': s.async('fb', _failAfter(0, 'b')),
      },
    ),
    trace: [
      'call fa()',
      'call fb()',
      'MontyRuntimeError ValueError: b | ValueError: b',
    ],
    answers: [
      '0 future',
      '1 future',
      '1/b0 raise ValueError: b',
      '0/b1 value MontyInt(1)',
    ],
  ),
  Scenario(
    'B fails while A is awaited, then Python awaits B (caught)',
    feeds: [_catchB],
    script: (f) => f
      ..willCall('fa')
      ..willCall('fb')
      ..willAwait([0])
      ..willAwait([1])
      ..willCatch()
      ..willReturn(_int(1)),
    run: (s) => s.run(
      0,
      externals: {
        'fa': s.async('fa', _after(150, _int(1))),
        'fb': s.async('fb', _failAfter(0, 'b')),
      },
    ),
    trace: [
      'call fa()',
      'call fb()',
      'value MontyInt(1)',
    ],
    answers: [
      '0 future',
      '1 future',
      '1/b0 raise ValueError: b',
      '0/b1 value MontyInt(1)',
    ],
  ),
  Scenario(
    'B fails while A is awaited, by hand',
    feeds: ['a = fa()\nb = fb()\nx = await a\nawait b'],
    script: (f) => f
      ..willCall('fa')
      ..willCall('fb')
      ..willAwait([0])
      ..willAwait([1])
      ..willReturn(_none),
    run: (s) async {
      final a = await s.start(0);
      final b = await s.next<FunctionSnapshot>(
        a,
        (c) => c.resume(const ExternalFuture()),
      );
      final wait = await s.next<FunctionSnapshot>(
        b,
        (c) => c.resume(const ExternalFuture()),
      );
      final again = await s.next<FutureSnapshot>(
        wait,
        (w) => w.resume({1: const ExternalException('ValueError', 'b')}),
      );
      await s.next<FutureSnapshot>(
        again,
        (w) => w.resume({0: ExternalReturnValue(_int(1))}),
      );
    },
    trace: [
      'snap call fa#0()',
      'snap call fb#1()',
      'snap futures [0, 1]',
      'snap futures [0]',
      'MontyRuntimeError ValueError: b | ValueError: b',
    ],
    answers: [
      '0 future',
      '1 future',
      '1/b0 raise ValueError: b',
      '0/b1 value MontyInt(1)',
    ],
  ),
  Scenario(
    'an unadvertised task settles first: the wait repeats',
    feeds: ['a = fa()\nb = fb()\nx = await a\ny = await b\nx + y'],
    script: (f) => f
      ..willCall('fa')
      ..willCall('fb')
      ..willAwait([0])
      ..willAwait([1])
      ..willReturn(_int(3)),
    run: (s) => s.run(
      0,
      externals: {
        'fa': s.async('fa', _after(150, _int(1))),
        'fb': s.async('fb', _after(0, _int(2))),
      },
    ),
    trace: [
      'call fa()',
      'call fb()',
      'value MontyInt(3)',
    ],
    answers: [
      '0 future',
      '1 future',
      '1/b0 value MontyInt(2)',
      '0/b1 value MontyInt(1)',
    ],
  ),
  Scenario(
    'two gathered branches: the first calls again before the second settles',
    feeds: [_branches],
    script: (f) => f
      ..willCall('f', args: [_int(1)])
      ..willCall('f', args: [_int(2)])
      ..willAwait([0, 1])
      ..willCall('g', args: [_int(1)])
      ..willAwait([1, 2])
      ..willAwait([1])
      ..willReturn(MontyList([_int(5), _int(2)])),
    run: (s) => s.run(
      0,
      externals: {
        'f': s.async(
          'f',
          (args, _) => Future.delayed(
            Duration(milliseconds: args.firstOrNull == _int(1) ? 0 : 150),
            () => args.firstOrNull ?? _none,
          ),
        ),
        'g': s.async('g', _after(0, _int(5))),
      },
    ),
    trace: [
      'call f(MontyInt(1))',
      'call f(MontyInt(2))',
      'call g(MontyInt(1))',
      'value MontyList[MontyInt(5), MontyInt(2)]',
    ],
    answers: [
      '0 future',
      '1 future',
      '0/b0 value MontyInt(1)',
      '2 future',
      '2/b1 value MontyInt(5)',
      '1/b2 value MontyInt(2)',
    ],
  ),
  Scenario(
    'a gather still owed a future waits for it before the end',
    feeds: [_branches],
    script: (f) => f
      ..willCall('f', args: [_int(1)])
      ..willCall('f', args: [_int(2)])
      ..willAwait([0, 1])
      ..willCall('g', args: [_int(1)])
      ..willAwait([2])
      ..willReturn(MontyList([_int(5), _int(2)])),
    run: (s) => s.run(
      0,
      externals: {
        'f': s.async(
          'f',
          (args, _) => Future.delayed(
            Duration(milliseconds: args.firstOrNull == _int(1) ? 0 : 150),
            () => args.firstOrNull ?? _none,
          ),
        ),
        'g': s.async('g', _after(0, _int(5))),
      },
    ),
    trace: [
      'call f(MontyInt(1))',
      'call f(MontyInt(2))',
      'call g(MontyInt(1))',
      'value MontyList[MontyInt(5), MontyInt(2)]',
    ],
    answers: [
      '0 future',
      '1 future',
      '0/b0 value MontyInt(1)',
      '2 future',
      '2/b1 value MontyInt(5)',
      '1/b2 value MontyInt(2)',
    ],
  ),
  Scenario(
    'an awaited asyncio.sleep takes a plain value (feedRun)',
    feeds: ['import asyncio\nawait asyncio.sleep(0, result=7)'],
    config: const SessionConfig(osPolicy: OsPolicy(sleep: 'call_host')),
    script: (f) => f
      ..willCallOs('asyncio.sleep', args: [const MontyFloat(0)], eager: true)
      ..willReturn(_int(7)),
    run: (s) => s.run(0, os: s.os((_, _, _) => _none)),
    trace: [
      'os asyncio.sleep(MontyFloat(0.0))',
      'value MontyInt(7)',
    ],
    answers: [
      '0 value MontyNone()',
    ],
  ),
  Scenario(
    'an awaited asyncio.sleep takes a plain value (resumeAuto)',
    feeds: ['import asyncio\nawait asyncio.sleep(0, result=7)'],
    config: const SessionConfig(osPolicy: OsPolicy(sleep: 'call_host')),
    script: (f) => f
      ..willCallOs('asyncio.sleep', args: [const MontyFloat(0)], eager: true)
      ..willReturn(_int(7)),
    run: (s) async {
      final call = await s.start(0, os: s.os((_, _, _) => _none));
      await s.next<FunctionSnapshot>(call, (c) => c.resumeAuto());
    },
    trace: [
      'snap os asyncio.sleep#0 eager(MontyFloat(0.0))',
      'os asyncio.sleep(MontyFloat(0.0))',
      'complete MontyInt(7)',
    ],
    answers: [
      '0 value MontyNone()',
    ],
  ),
  Scenario(
    'frames are named per feed',
    feeds: ["raise ValueError('a')", "x = 1\nraise ValueError('b')"],
    script: (f) => f
      ..willRaise('ValueError', message: 'a', line: 1, column: 7)
      ..willRaise('ValueError', message: 'b', line: 2, column: 7),
    run: (s) async {
      await _runWithFrames(s, 0);
      await _runWithFrames(s, 1);
    },
    trace: [
      'MontyRuntimeError ValueError: a | ValueError: a',
      'frame <python-input-0> 1:7 <module>',
      'MontyRuntimeError ValueError: b | ValueError: b',
      'frame <python-input-1> 2:7 <module>',
    ],
    answers: [],
  ),
  Scenario(
    'an invalid callback result',
    feeds: ['f()'],
    script: (f) => f
      ..willCall('f')
      ..willReturn(_none),
    run: (s) => s.run(0, externals: {'f': s.fn('f', (_, _) => _str('\uD800'))}),
    trace: [
      'call f()',
      r"MontyRuntimeError ValueError: 'utf-8' codec can't encode character '\ud800' in position 0: surrogates not allowed | UnicodeEncodeError: 'utf-8' codec can't encode character '\ud800' in position 0: surrogates not allowed",
    ],
    answers: [
      r"0 raise UnicodeEncodeError: 'utf-8' codec can't encode character '\ud800' in position 0: surrogates not allowed",
    ],
  ),
  Scenario(
    'an invalid manual resume, retried',
    feeds: ['f()'],
    script: (f) => f
      ..willCall('f')
      ..willReturn(_int(1)),
    run: (s) async {
      final call = await s.start(0);
      // The refused answer leaves the snapshot unspent, to resume again.
      await s.next<FunctionSnapshot>(
        call,
        (c) => c.resume(ExternalReturnValue(_str('\uD800'))),
      );
      await s.next<FunctionSnapshot>(
        call,
        (c) => c.resume(ExternalReturnValue(_int(1))),
      );
    },
    trace: [
      'snap call f#0()',
      r"MontyRuntimeError ValueError: 'utf-8' codec can't encode character '\ud800' in position 0: surrogates not allowed | UnicodeEncodeError: 'utf-8' codec can't encode character '\ud800' in position 0: surrogates not allowed",
      'complete MontyInt(1)',
    ],
    answers: [
      '0 value MontyInt(1)',
    ],
  ),
  Scenario(
    'a path argument arrives normalised',
    feeds: ["from pathlib import Path\nf(Path('/a/./b//c'))"],
    script: (f) => f
      ..willCall('f', args: [const MontyPath('/a/./b//c')])
      ..willReturn(_none),
    run: (s) => s.run(0, externals: {'f': s.fn('f')}),
    trace: [
      'call f(MontyPath("/a/b/c"))',
      'value MontyNone()',
    ],
    answers: [
      '0 value MontyNone()',
    ],
  ),
];
