// The minimal worker driver (lib/src/worker/proto_session.dart) against a scripted
// channel: configure and limits, the feed loop's three suspensions, prints,
// in-band errors, reset, crashes and protocol desync. The replies are the
// monty-proto messages a worker sends, so this pins the driver's half of the
// protocol on the VM, dart2js and dart2wasm without a worker.
import 'package:dart_monty_core/dart_monty_core.dart'
    hide MontyError, MontySyntaxError, MontyTypingError;
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_scripted_channel.dart';

const pb.PrintStream _stdout = pb.PrintStream.PRINT_STREAM_STDOUT;
const pb.PrintStream _stderr = pb.PrintStream.PRINT_STREAM_STDERR;

/// A channel whose first reply accepts `Configure`, then [rest].
ScriptedChannel _configured(List<Reply> rest) => ScriptedChannel([
  expecting(pb.ParentRequest_Kind.configure, [ok()]),
  ...rest,
]);

pb.ChildEvent _functionCall(
  String name,
  List<pb.MontyNode> nodes, {
  List<int> args = const [],
  List<pb.NodePair> kwargs = const [],
  int callId = 7,
}) => pb.ChildEvent(
  functionCall: pb.FunctionCall(
    functionName: name,
    callId: callId,
    args: args,
    kwargs: kwargs,
    values: pb.Arena(nodeCount: nodes.length, nodes: nodes),
  ),
);

pb.ChildEvent _nameLookup(String name) =>
    pb.ChildEvent(nameLookup: pb.NameLookup(name: name));

pb.StackFrame _frame(String name, int line, {String? preview}) => pb.StackFrame(
  filename: 'main.py',
  start: pb.CodeLoc(line: line, column: 1),
  end: pb.CodeLoc(line: line, column: 9),
  frameName: name,
  previewLine: preview,
);

void main() {
  group('open', () {
    test('Configure carries the protocol version, name and limits', () async {
      final ch = _configured([]);
      await ProtoSession.open(
        ch,
        const SessionConfig(
          scriptName: 'case.py',
          limits: ResourceLimits(
            maxMemory: 268435456,
            maxRecursionDepth: 200,
            maxFeedDuration: Duration(milliseconds: 1500),
          ),
        ),
      );
      final configure = onlyItem(ch.requests).configure;
      expect(configure.protocolVersion, protocolVersion);
      expect(configure.scriptName, 'case.py');
      expect(configure.limits.maxMemoryBytes, Int64(268435456));
      expect(configure.limits.maxRecursionDepth, Int64(200));
      expect(configure.limits.maxFeedDurationMicros, Int64(1500000));
      // Upstream sends the two limits that cannot be off, at 1000 unset.
      expect(configure.limits.maxSuspensions, Int64(1000));
      expect(configure.limits.hasGcInterval(), isFalse);
      expect(configure.limits.hasMaxTotalSleepMicros(), isFalse);
    });

    test('no limits set sends no limits message', () async {
      final ch = _configured([]);
      await ProtoSession.open(ch);
      final configure = onlyItem(ch.requests).configure;
      expect(configure.hasLimits(), isFalse);
      expect(configure.scriptName, 'main.py');
    });

    test('a FatalError answer (version skew) is a crash', () async {
      final ch = ScriptedChannel([
        answer([fatal('protocol_version 5 outside 6..=6')]),
      ]);
      await expectLater(
        ProtoSession.open(ch),
        throwsA(
          isA<MontyCrashedError>()
              .having((e) => e.cause, 'cause', CrashCause.fatal)
              .having((e) => e.message, 'message', contains('outside')),
        ),
      );
    });

    test('any other answer kills the worker: a protocol violation', () async {
      final ch = ScriptedChannel([
        answer([completeNone()]),
      ]);
      await expectLater(
        ProtoSession.open(ch),
        throwsA(
          isA<MontyCrashedError>()
              .having((e) => e.cause, 'cause', CrashCause.protocol)
              .having(
                (e) => e.message,
                'message',
                'monty worker protocol error: unexpected reply to Configure: '
                    'complete',
              ),
        ),
      );
      expect(ch.kills, 1);
    });
  });

  group('type check', () {
    test(
      'a TypingError ends the feed in-band on a type-checking session',
      () async {
        final ch = _configured([
          answer([
            pb.ChildEvent(typingError: pb.TypingError(diagnostics: 'oops')),
          ]),
        ]);
        final s = await ProtoSession.open(
          ch,
          const SessionConfig(typeCheck: true, typeCheckFormat: 'github'),
        );
        expect(
          onlyItem(ch.requests).configure.typeCheckFormat,
          pb.TypeCheckFormat.TYPE_CHECK_FORMAT_GITHUB,
        );
        await expectLater(
          s.feed('x: int = ""'),
          throwsA(
            isA<MontyTypingError>().having(
              (e) => '$e',
              'toString',
              'oops',
            ),
          ),
        );
        expect(ch.kills, 0);
      },
    );

    test('an unknown format is refused before Configure is sent', () async {
      final ch = _configured([]);
      await expectLater(
        ProtoSession.open(ch, const SessionConfig(typeCheckFormat: 'nope')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            contains('jsonlines'),
          ),
        ),
      );
      expect(ch.requests, isEmpty);
    });
  });

  group('feed', () {
    test('returns the decoded value', () async {
      final ch = _configured([
        expecting(pb.ParentRequest_Kind.feed, [
          complete([
            pb.MontyNode(str: 'h'),
            pb.MontyNode(bytes: [0, 255]),
          ]),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      final r = await s.feed(r'b"\x00\xff"');
      expect(r.value, const MontyBytes([0, 255]));
      expect(r.prints, isEmpty);
      expect(itemAt(ch.requests, 1).feed.code, r'b"\x00\xff"');
    });

    test('typed inputs travel as one arena (E0 s01)', () async {
      final ch = _configured([
        answer([
          complete([intNode(42)]),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      const shared = MontyList([MontyInt(1)]);
      await s.feed(
        '(n + 1, 2**70)',
        inputs: {
          'n': const MontyInt(41),
          'a': shared,
          'b': shared,
          'big': MontyBigInt(BigInt.two.pow(70)),
        },
      );
      final feed = itemAt(ch.requests, 1).feed;
      final refs = {for (final r in feed.inputs) r.name: r.value};
      expect(refs.keys, ['n', 'a', 'b', 'big']);
      expect(refs['a'], refs['b'], reason: 'one object, one node');
      final nodes = feed.values.nodes;
      expect(intOfNode(itemAt(nodes, refs['n'] ?? -1)), BigInt.from(41));
      expect(
        itemAt(nodes, refs['big'] ?? -1).whichKind(),
        pb.MontyNode_Kind.bigint,
      );
    });

    test('no inputs sends no arena', () async {
      final ch = _configured([
        answer([completeNone()]),
      ]);
      final s = await ProtoSession.open(ch);
      await s.feed('pass');
      expect(itemAt(ch.requests, 1).feed.hasValues(), isFalse);
    });

    test('prints stream in order to onPrint and the result (E0 s09)', () async {
      final ch = _configured([
        answer([
          printed([(_stdout, 'a\n'), (_stderr, 'b\n')]),
          printed([(_stdout, 'c'), (_stderr, 'd\n')]),
          complete([pb.MontyNode(str: 'done')]),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      final seen = <(String, String)>[];
      final r = await s.feed(
        'print',
        onPrint: (stream, text) => seen.add((stream, text)),
      );
      const expected = [
        ('stdout', 'a\n'),
        ('stderr', 'b\n'),
        ('stdout', 'c'),
        ('stderr', 'd\n'),
      ];
      expect(seen, expected);
      expect(r.prints, expected);
      expect(r.value, const MontyString('done'));
    });

    test(
      'a throwing onPrint kills the worker, not leaves it suspended',
      () async {
        final ch = _configured([
          answer([
            printed([(_stdout, 'x\n')]),
            _nameLookup('fetch'),
          ]),
        ]);
        final s = await ProtoSession.open(ch);
        await expectLater(
          s.feed(
            'print(1); fetch',
            onPrint: (_, _) => throw StateError('boom'),
          ),
          throwsStateError,
        );
        // The worker is suspended on a NameLookup nobody will answer, so the
        // session must not let another request reach it.
        expect(ch.kills, 1);
        expect(ch.isAlive, isFalse);
      },
    );

    test('a throwing onPrint before a completed turn keeps the worker; the '
        'failure wins', () async {
      final ch = _configured([
        answer([
          printed([(_stdout, 'a')]),
          printed([(_stdout, 'b')]),
          complete([intNode(1)]),
        ]),
        answer([
          complete([intNode(2)]),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      var calls = 0;
      await expectLater(
        s.feed(
          'print("a"); print("b"); 1',
          onPrint: (_, _) {
            calls++;
            throw StateError('boom');
          },
        ),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'boom'),
        ),
      );
      expect(calls, 1, reason: 'no more prints are delivered after it');
      expect(ch.kills, 0);
      expect((await s.feed('2')).value, const MontyInt(2));
    });

    test('a throwing onPrint drains an endless turn; its kill ends the feed '
        'with the failure', () async {
      // `while True: print('x')`: the turn only ends when it is killed (by a
      // deadline, above this driver), and the print failure still wins.
      final ch = _configured([
        hangAfter([
          for (var i = 0; i < 100; i++) printed([(_stdout, 'x\n')]),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      var calls = 0;
      var done = false;
      final feed = s.feed(
        'while True: print("x")',
        onPrint: (_, _) {
          calls++;
          throw StateError('boom');
        },
      );
      final failed = expectLater(
        feed.whenComplete(() => done = true),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'boom'),
        ),
      );
      await pumpEventQueue(times: 300);
      expect(done, isFalse);
      expect(ch.kills, 0);
      ch.kill();
      await failed;
      expect(calls, 1);
    });

    test('a name in externals resolves to a function node', () async {
      final ch = _configured([
        answer([_nameLookup('fetch')]),
        answer([completeNone()]),
      ]);
      final s = await ProtoSession.open(ch);
      await s.feed(
        'fetch',
        externals: {'fetch': (args, kwargs) => const MontyNone()},
      );
      final resume = itemAt(ch.requests, 2).resumeNameLookup;
      expect(resume.whichKind(), pb.ResumeNameLookup_Kind.value);
      final node = itemAt(resume.values.nodes, resume.value);
      expect(node.function.name, 'fetch');
    });

    test('an unknown name is undefined', () async {
      final ch = _configured([
        answer([_nameLookup('nope')]),
        answer([raised('NameError', "name 'nope' is not defined")]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(s.feed('nope'), throwsA(isA<MontyRuntimeError>()));
      expect(
        itemAt(ch.requests, 2).resumeNameLookup.whichKind(),
        pb.ResumeNameLookup_Kind.undefined,
      );
    });

    test('a function call gets args, kwargs and its return (E0 s10)', () async {
      final ch = _configured([
        answer([_nameLookup('fetch')]),
        answer([
          _functionCall(
            'fetch',
            [
              intNode(1),
              pb.MontyNode(str: 'mode'),
              pb.MontyNode(str: 'x'),
            ],
            args: [0],
            kwargs: [pb.NodePair(key: 1, value: 2)],
          ),
        ]),
        answer([
          complete([pb.MontyNode(str: 'ok!')]),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      final calls = <(List<MontyValue>, Map<String, MontyValue>)>[];
      final r = await s.feed(
        "r = fetch(1, mode='x')\nr + '!'",
        externals: {
          'fetch': (args, kwargs) {
            calls.add((args, kwargs));

            return const MontyString('ok');
          },
        },
      );
      final (args, kwargs) = onlyItem(calls);
      expect(args, [const MontyInt(1)]);
      expect(kwargs, {'mode': const MontyString('x')});
      final resume = itemAt(ch.requests, 3).resumeCall;
      expect(resume.callId, 7);
      expect(resume.result.whichKind(), pb.ExtFunctionResult_Kind.returnValue);
      expect(
        itemAt(resume.values.nodes, resume.result.returnValue).str,
        'ok',
      );
      expect(r.value, const MontyString('ok!'));
    });

    test('a call to an unregistered function is not_found', () async {
      final ch = _configured([
        answer([_functionCall('gone', [])]),
        answer([raised('NameError')]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(s.feed('gone()'), throwsA(isA<MontyRuntimeError>()));
      expect(itemAt(ch.requests, 2).resumeCall.result.notFound, 'gone');
    });

    test(
      'a host throw raises in Python; OsCallException picks the class',
      () async {
        final ch = _configured([
          answer([_functionCall('f', [], callId: 1)]),
          answer([_functionCall('g', [], callId: 2)]),
          answer([completeNone()]),
        ]);
        final s = await ProtoSession.open(ch);
        await s.feed(
          'f(); g()',
          externals: {
            'f': (args, kwargs) => throw const OsCallException(
              'no',
              pythonExceptionType: 'KeyError',
            ),
            'g': (args, kwargs) => throw StateError('broken'),
          },
        );
        final f = itemAt(ch.requests, 2).resumeCall.result.error;
        expect(f.excType, 'KeyError');
        expect(f.message, 'no');
        final g = itemAt(ch.requests, 3).resumeCall.result.error;
        expect(g.excType, 'RuntimeError');
        expect(g.message, contains('broken'));
      },
    );

    // One value per outbound rule of the writer: each is refused before it
    // reaches the worker, through an input and through a callback return.
    final refused = <String, MontyValue>{
      'an unpaired surrogate': const MontyString('\uD800'),
      'a byte above 255': const MontyBytes([256]),
      'hour 24': const MontyTime(
        hour: 24,
        minute: 0,
        second: 0,
        microsecond: 0,
      ),
      'an unnormalized timedelta': const MontyTimeDelta(days: 0, seconds: -1),
      'an offset of a day': const MontyTimeZone(offsetSeconds: 86400),
      'a zone name without an offset': const MontyDateTime(
        year: 2026,
        month: 1,
        day: 1,
        hour: 0,
        minute: 0,
        second: 0,
        timezoneName: 'X',
      ),
      'a negative file position': const MontyFileHandle(
        path: '/x',
        mode: 'r',
        position: -1,
      ),
      'an unknown exception type': const MontyExceptionValue(excType: 'Nope'),
      'a short named tuple': const MontyNamedTuple(
        typeName: 'P',
        fieldNames: ['x'],
        values: [],
      ),
      'an unhashable set member': const MontySet([MontyList([])]),
    };
    for (final MapEntry(key: what, :value) in refused.entries) {
      test('an input with $what is refused before sending', () async {
        final ch = _configured([]);
        final s = await ProtoSession.open(ch);
        await expectLater(
          s.feed('x', inputs: {'x': value}),
          throwsArgumentError,
        );
        expect(ch.requests, hasLength(1));
      });

      test('a callback returning $what fails the call', () async {
        final ch = _configured([
          answer([_functionCall('f', [])]),
          answer([completeNone()]),
        ]);
        final s = await ProtoSession.open(ch);
        await s.feed('f()', externals: {'f': (args, kwargs) => value});
        final result = itemAt(ch.requests, 2).resumeCall.result;
        expect(result.whichKind(), pb.ExtFunctionResult_Kind.error);
        expect(result.error.message, contains('Invalid argument'));
        expect(result.hasReturnValue(), isFalse);
      });
    }

    test('a keyword argument named by a non-str fails the call', () async {
      final ch = _configured([
        answer([
          _functionCall(
            'f',
            [intNode(1), intNode(2)],
            kwargs: [pb.NodePair(key: 0, value: 1)],
          ),
        ]),
        answer([completeNone()]),
      ]);
      final s = await ProtoSession.open(ch);
      await s.feed(
        'f()',
        externals: {'f': (args, kwargs) => const MontyNone()},
      );
      final error = itemAt(ch.requests, 2).resumeCall.result.error;
      expect(error.message, contains('a keyword argument name must be a str'));
    });

    test(
      'an argument with no value class yet fails the call, not the session',
      () async {
        final ch = _configured([
          answer([
            _functionCall('f', [_complex], args: [0]),
          ]),
          answer([completeNone()]),
        ]);
        final s = await ProtoSession.open(ch);
        var called = false;
        await s.feed(
          'f(1j)',
          externals: {
            'f': (args, kwargs) {
              called = true;

              return const MontyNone();
            },
          },
        );
        expect(called, isFalse);
        final error = itemAt(ch.requests, 2).resumeCall.result.error;
        expect(error.excType, 'RuntimeError');
        expect(error.message, contains('complex'));
      },
    );

    test('every path OS call reaches the handler by upstream name', () async {
      final calls = {
        'Path.exists': pb.OsCall(exists: '/p'),
        'Path.is_file': pb.OsCall(isFile: '/p'),
        'Path.is_dir': pb.OsCall(isDir: '/p'),
        'Path.is_symlink': pb.OsCall(isSymlink: '/p'),
        'Path.read_text': pb.OsCall(readText: '/p'),
        'Path.read_bytes': pb.OsCall(readBytes: '/p'),
        'Path.stat': pb.OsCall(stat: '/p'),
        'Path.iterdir': pb.OsCall(iterdir: '/p'),
        'Path.resolve': pb.OsCall(resolve: '/p'),
        'Path.absolute': pb.OsCall(absolute: '/p'),
        'Path.unlink': pb.OsCall(unlink: '/p'),
        'Path.rmdir': pb.OsCall(rmdir: '/p'),
      };
      final ch = _configured([
        for (final call in calls.values) answer([pb.ChildEvent(osCall: call)]),
        answer([completeNone()]),
      ]);
      final s = await ProtoSession.open(ch);
      final seen = <(String, List<MontyValue>)>[];
      await s.feed(
        '...',
        onOsCall: (name, args, kwargs) {
          seen.add((name, args));

          return const MontyNone();
        },
      );
      expect([for (final (name, _) in seen) name], calls.keys);
      for (final (_, args) in seen) {
        expect(args, [const MontyPath('/p')]);
      }
    });

    test(
      'an OS call reaches the handler with upstream name and a path (E0 s11)',
      () async {
        final ch = _configured([
          answer([
            pb.ChildEvent(osCall: pb.OsCall(callId: 3, readText: '/x')),
          ]),
          answer([
            complete([pb.MontyNode(str: 'hello from host')]),
          ]),
        ]);
        final s = await ProtoSession.open(ch);
        final names = <String>[];
        final argLists = <List<MontyValue>>[];
        final r = await s.feed(
          "Path('/x').read_text()",
          onOsCall: (name, args, kwargs) {
            names.add(name);
            argLists.add(args);

            return const MontyString('hello from host');
          },
        );
        expect(names, ['Path.read_text']);
        expect(onlyItem(argLists), [const MontyPath('/x')]);
        final resume = itemAt(ch.requests, 2).resumeCall;
        expect(resume.callId, 3);
        expect(
          itemAt(resume.values.nodes, resume.result.returnValue).str,
          'hello from host',
        );
        expect(r.value, const MontyString('hello from host'));
      },
    );

    test(
      'OS calls are declined: no handler, null, not-handled, other ops',
      () async {
        pb.ChildEvent os(int id, pb.OsCall call) =>
            pb.ChildEvent(osCall: call..callId = id);
        final ch = _configured([
          answer([os(1, pb.OsCall(exists: '/a'))]),
          answer([os(2, pb.OsCall(isFile: '/b'))]),
          answer([os(3, pb.OsCall(getenv: pb.OsCall_Getenv(key: 'HOME')))]),
          answer([os(4, pb.OsCall(readBytes: '/c'))]),
          answer([completeNone()]),
        ]);
        final s = await ProtoSession.open(ch);
        final names = <String>[];
        await s.feed(
          'os',
          onOsCall: (name, args, kwargs) {
            names.add(name);
            if (name == 'Path.read_bytes') {
              throw const OsCallNotHandledException();
            }

            return null;
          },
        );
        expect(names, ['Path.exists', 'Path.is_file', 'Path.read_bytes']);
        for (var i = 2; i <= 5; i++) {
          expect(
            itemAt(ch.requests, i).resumeCall.result.whichKind(),
            pb.ExtFunctionResult_Kind.notHandled,
            reason: 'request $i',
          );
        }
      },
    );

    test('with no handler every OS call is not_handled', () async {
      final ch = _configured([
        answer([
          pb.ChildEvent(osCall: pb.OsCall(callId: 9, readText: '/x')),
        ]),
        answer([raised('PermissionError')]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(s.feed('read'), throwsA(isA<MontyRuntimeError>()));
      final resume = itemAt(ch.requests, 2).resumeCall;
      expect(resume.callId, 9);
      expect(resume.result.whichKind(), pb.ExtFunctionResult_Kind.notHandled);
    });

    test('an OS handler throw raises in Python', () async {
      final ch = _configured([
        answer([
          pb.ChildEvent(osCall: pb.OsCall(callId: 1, readText: '/x')),
        ]),
        answer([completeNone()]),
      ]);
      final s = await ProtoSession.open(ch);
      await s.feed(
        'read',
        onOsCall: (name, args, kwargs) => throw const OsCallException(
          'missing',
          pythonExceptionType: 'FileNotFoundError',
        ),
      );
      final error = itemAt(ch.requests, 2).resumeCall.result.error;
      expect(error.excType, 'FileNotFoundError');
      expect(error.message, 'missing');
    });
  });

  group('errors', () {
    test(
      'a Python exception is in band, with its traceback (E0 s08)',
      () async {
        final ch = _configured([
          answer([
            printed([(_stdout, 'before\n')]),
            raised('ValueError', 'bad 7', [
              _frame('<module>', 7),
              _frame('outer', 5),
              _frame('inner', 2, preview: "    raise ValueError(f'bad {x}')"),
            ]),
          ]),
          answer([
            complete([intNode(2)]),
          ]),
        ]);
        final s = await ProtoSession.open(ch);
        final seen = <String>[];
        MontyRuntimeError? error;
        try {
          await s.feed('outer()', onPrint: (_, text) => seen.add(text));
        } on MontyRuntimeError catch (e) {
          error = e;
        }
        expect(seen, ['before\n']);
        expect(error?.message, 'ValueError: bad 7');
        expect(error?.exception.excType, 'ValueError');
        expect(error?.exception.message, 'bad 7');
        final traceback = error?.traceback ?? const <Frame>[];
        expect(
          [for (final f in traceback) f.functionName],
          ['<module>', 'outer', 'inner'],
        );
        final inner = itemAt(traceback, 2);
        expect(inner.filename, 'main.py');
        expect(inner.line, 2);
        expect(inner.column, 1);
        expect(inner.endLine, 2);
        expect(inner.endColumn, 9);
        expect(inner.sourceLine, "    raise ValueError(f'bad {x}')");

        // The session survives.
        expect((await s.feed('1 + 1')).value, const MontyInt(2));
      },
    );

    test('SyntaxError is a MontySyntaxError', () async {
      final ch = _configured([
        answer([
          raised('SyntaxError', 'invalid syntax', [_frame('<module>', 1)]),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(
        s.feed('def ('),
        throwsA(
          isA<MontySyntaxError>()
              .having((e) => e.message, 'message', 'invalid syntax')
              .having((e) => onlyItem(e.traceback).line, 'line', 1),
        ),
      );
    });

    test('MemoryError from max_memory stays in band', () async {
      final ch = _configured([
        answer([raised('MemoryError', 'memory limit exceeded')]),
        answer([completeNone()]),
      ]);
      final s = await ProtoSession.open(
        ch,
        const SessionConfig(limits: ResourceLimits(maxMemory: 16 << 20)),
      );
      await expectLater(
        s.feed('x = [0] * 10**9'),
        throwsA(
          isA<MontyRuntimeError>().having(
            (e) => e.exception.excType,
            'excType',
            'MemoryError',
          ),
        ),
      );
      await s.feed('pass');
    });

    test('an exception with no message: Type, and an empty one', () async {
      final ch = _configured([
        answer([raised('KeyboardInterrupt')]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(
        s.feed('raise KeyboardInterrupt'),
        throwsA(
          isA<MontyRuntimeError>()
              .having((e) => e.message, 'message', 'KeyboardInterrupt')
              .having((e) => e.exception.message, 'exception', '')
              .having((e) => e.traceback, 'traceback', isEmpty)
              .having(
                (e) => e.display('type-msg'),
                'type-msg',
                'KeyboardInterrupt',
              ),
        ),
      );
    });

    test(
      'a crash mid-feed is a MontyCrashedError and the session is over',
      () async {
        final ch = _configured([
          crash(CrashCause.outOfMemory, 'exit 65'),
        ]);
        final s = await ProtoSession.open(ch);
        await expectLater(
          s.feed('x'),
          throwsA(
            isA<MontyCrashedError>().having(
              (e) => e.cause,
              'cause',
              CrashCause.outOfMemory,
            ),
          ),
        );
        expect(ch.isAlive, isFalse);
        await expectLater(s.feed('1'), throwsA(isA<MontyCrashedError>()));
      },
    );

    test('a FatalError mid-feed is a crash', () async {
      final ch = _configured([
        answer([fatal('panic')]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(
        s.feed('x'),
        throwsA(
          isA<MontyCrashedError>().having(
            (e) => e.cause,
            'cause',
            CrashCause.fatal,
          ),
        ),
      );
    });

    test('a result that does not decode: a protocol violation', () async {
      // An arena whose root points past its nodes.
      final ch = _configured([
        answer([
          pb.ChildEvent(
            complete: pb.Complete(
              value: 5,
              values: pb.Arena(
                nodeCount: 1,
                nodes: [pb.MontyNode(none: pb.Unit())],
              ),
            ),
          ),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(
        s.feed('x'),
        throwsA(
          isA<MontyCrashedError>()
              .having((e) => e.cause, 'cause', CrashCause.protocol)
              .having(
                (e) => e.message,
                'message',
                startsWith(
                  'monty worker protocol error: invalid payload from worker: ',
                ),
              ),
        ),
      );
      expect(ch.kills, 1);
    });

    test('an event that cannot end a feed kills the worker', () async {
      for (final event in [
        ok(),
        pb.ChildEvent(resolveFutures: pb.ResolveFutures()),
        pb.ChildEvent(typingError: pb.TypingError(diagnostics: 'x')),
        pb.ChildEvent(),
      ]) {
        final ch = _configured([
          answer([event]),
        ]);
        final s = await ProtoSession.open(ch);
        await expectLater(
          s.feed('x'),
          throwsA(
            isA<MontyCrashedError>()
                .having((e) => e.cause, 'cause', CrashCause.protocol)
                .having(
                  (e) => e.message,
                  'message',
                  startsWith('monty worker protocol error: unexpected event'),
                ),
          ),
          reason: event.whichKind().name,
        );
        expect(ch.kills, 1);
      }
    });

    test(
      'a value with no value class yet in Complete throws, worker still in '
      'step',
      () async {
        final ch = _configured([
          answer([
            complete([_complex]),
          ]),
          answer([
            complete([pb.MontyNode(boolean: true)]),
          ]),
        ]);
        final s = await ProtoSession.open(ch);
        await expectLater(s.feed('1j'), throwsUnsupportedError);
        expect((await s.feed('True')).value, const MontyBool(true));
      },
    );
  });

  group('session', () {
    test('two feeds share one session (E0 s12)', () async {
      final ch = _configured([
        answer([
          printed([(_stdout, 'fed\n')]),
          completeNone(),
        ]),
        answer([
          complete([
            intNode(1),
            intNode(2),
            intNode(3),
            pb.MontyNode(list: pb.Indexes(items: [0, 1, 2])),
          ]),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      final first = await s.feed("x = [1, 2]\nprint('fed')");
      expect(first.value, const MontyNone());
      expect(first.prints, [('stdout', 'fed\n')]);
      final second = await s.feed('x.append(3)\nx');
      expect(
        second.value,
        const MontyList([MontyInt(1), MontyInt(2), MontyInt(3)]),
      );
      expect(second.prints, isEmpty);
      expect(ch.remaining, 0);
    });

    test('reset sends Reset, then Configure again', () async {
      final accepted = [ok()];
      final ch = _configured([
        expecting(pb.ParentRequest_Kind.reset, accepted),
        expecting(pb.ParentRequest_Kind.configure, accepted),
      ]);
      final s = await ProtoSession.open(
        ch,
        const SessionConfig(limits: ResourceLimits(maxRecursionDepth: 50)),
      );
      await s.reset();
      expect(ch.remaining, 0);
      expect(
        itemAt(ch.requests, 2).configure.limits.maxRecursionDepth,
        Int64(50),
      );
    });

    test('a Reset answered with anything but Ok is a desync', () async {
      final ch = _configured([
        answer([completeNone()]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(
        s.reset(),
        throwsA(
          isA<MontyCrashedError>().having(
            (e) => e.message,
            'message',
            'monty worker protocol error: unexpected reply to Reset: complete',
          ),
        ),
      );
      expect(ch.kills, 1);
    });

    test('one request at a time', () async {
      final ch = _configured([
        answer([completeNone()]),
      ]);
      final s = await ProtoSession.open(ch);
      final first = s.feed('a');
      expect(() => s.feed('b'), throwsStateError);
      expect(s.reset, throwsStateError);
      await first;
      expect(ch.remaining, 0);
    });

    test('close closes the channel', () async {
      final ch = _configured([]);
      final s = await ProtoSession.open(ch);
      await s.close();
      expect(ch.closes, 1);
      expect(ch.isAlive, isFalse);
    });
  });
}

/// A `complex` node: a kind the reader checks but has no value class for yet.
final pb.MontyNode _complex = pb.MontyNode(
  complex: pb.Complex(real: doubleToBits(0), imag: doubleToBits(1)),
);
