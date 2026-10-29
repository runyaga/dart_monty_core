// The minimal worker driver (lib/src/worker/proto_session.dart) against a scripted
// channel: configure and limits, the feed loop's three suspensions, prints,
// in-band errors, reset, crashes and protocol desync. The replies are the
// monty-proto messages a worker sends, so this pins the driver's half of the
// protocol on the VM, dart2js and dart2wasm without a worker. The last test
// covers the session's host modules: the map is read live, and an import is
// answered before the mounts and the OS handler see it.
import 'dart:async';
import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart'
    hide MontyError, MontySyntaxError, MontyTypingError;
import 'package:dart_monty_core/src/worker/host_answers.dart' show HostAnswers;
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_pool_protocol_support.dart';
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

/// A host object a session can register.
final ClassInstance<Object> _hostBox = ClassInstance(
  Object(),
  classType: ClassType(const HostClass('Box')),
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
              .having((e) => e.toString(), 'message', contains('outside')),
        ),
      );
    });

    // Upstream's Configure turn converts an Error reply as any raised
    // exception (PoolError::Runtime, checkout.rs:773-776, 1838-1852), and
    // the failed checkout discards the worker (Drop, checkout.rs:2110-2121).
    test('an Error answer raises as converted, and kills the worker', () async {
      for (final (event, matcher) in [
        (
          raised('ValueError', "unknown timezone 'Nope'"),
          isA<MontyRuntimeError>().having(
            (e) => e.display('type-msg'),
            'display',
            "ValueError: unknown timezone 'Nope'",
          ),
        ),
        (raised('SyntaxError', 'bad'), isA<MontySyntaxError>()),
      ]) {
        final ch = ScriptedChannel([
          answer([event]),
        ]);
        await expectLater(ProtoSession.open(ch), throwsA(matcher));
        expect(ch.kills, 1);
      }
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
                (e) => e.toString(),
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
    test('an explicit cwd is sent as upstream validate_cwd gives it: '
        'trailing slashes trimmed, / for the root', () {
      expect(feedRequest('1', const {}, cwd: '/tmp/a/').feed.cwd, '/tmp/a');
      expect(feedRequest('1', const {}, cwd: '///').feed.cwd, '/');
      expect(feedRequest('1', const {}, cwd: '/a/./b').feed.cwd, '/a/./b');
      expect(feedRequest('1', const {}).feed.hasCwd(), isFalse);
    });

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

    test('no inputs sends an empty arena, as upstream does', () async {
      final ch = _configured([
        answer([completeNone()]),
      ]);
      final s = await ProtoSession.open(ch);
      await s.feed('pass');
      final feed = itemAt(ch.requests, 1).feed;
      expect(feed.hasValues(), isTrue);
      expect(feed.values, pb.Arena());
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
          throwsA(isA<MontyRuntimeError>()),
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
          isA<MontyRuntimeError>().having(
            (e) => e.display('type-msg'),
            "display('type-msg')",
            'Exception: Bad state: boom',
          ),
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
          isA<MontyRuntimeError>().having(
            (e) => e.display('type-msg'),
            "display('type-msg')",
            'Exception: Bad state: boom',
          ),
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
        externalLookup: {
          'fetch': MontyHostFunction(
            'fetch',
            (args, kwargs) => const MontyNone(),
          ),
        },
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
        externalLookup: {
          'fetch': MontyHostFunction('fetch', (
            args,
            kwargs,
          ) {
            calls.add((args, kwargs));

            return const MontyString('ok');
          }),
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
      'a host throw raises in Python; ExternalException picks the class, '
      'any other throw is Exception',
      () async {
        final ch = _configured([
          answer([_functionCall('f', [], callId: 1)]),
          answer([_functionCall('g', [], callId: 2)]),
          answer([completeNone()]),
        ]);
        final s = await ProtoSession.open(ch);
        await s.feed(
          'f(); g()',
          externalLookup: {
            'f': MontyHostFunction(
              'f',
              (args, kwargs) => throw const ExternalException('KeyError', 'no'),
            ),
            'g': MontyHostFunction(
              'g',
              (args, kwargs) => throw StateError('broken'),
            ),
          },
        );
        final f = itemAt(ch.requests, 2).resumeCall.result.error;
        expect(f.excType, 'KeyError');
        expect(f.message, 'no');
        final g = itemAt(ch.requests, 3).resumeCall.result.error;
        expect(g.excType, 'Exception');
        expect(g.message, 'Bad state: broken');
      },
    );

    // One value per outbound rule of the writer: each is refused before it
    // reaches the worker, through an input and through a callback return.
    final refused = <String, MontyValue>{
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
      'an unknown exception type': MontyExceptionValue('Nope'),
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
        await s.feed(
          'f()',
          externalLookup: {
            'f': MontyHostFunction('f', (args, kwargs) => value),
          },
        );
        final result = itemAt(ch.requests, 2).resumeCall.result;
        expect(result.whichKind(), pb.ExtFunctionResult_Kind.error);
        expect(result.error.message, contains('Invalid argument'));
        expect(result.hasReturnValue(), isFalse);
      });
    }

    // A refusal Python makes too surfaces as Python's error (C3-4).
    test("an input with an unpaired surrogate throws upstream's error "
        'before sending', () async {
      final ch = _configured([]);
      final s = await ProtoSession.open(ch);
      await expectLater(
        s.feed('x', inputs: {'x': const MontyString('\uD800')}),
        throwsA(
          isA<MontyRuntimeError>().having(
            (e) => e.toString(),
            'message',
            "UnicodeEncodeError: 'utf-8' codec can't encode character "
                r"'\ud800' in position 0: surrogates not allowed",
          ),
        ),
      );
      expect(ch.requests, hasLength(1));
    });

    test('a callback returning an unpaired surrogate raises '
        'UnicodeEncodeError in the sandbox', () async {
      final ch = _configured([
        answer([_functionCall('f', [])]),
        answer([completeNone()]),
      ]);
      final s = await ProtoSession.open(ch);
      await s.feed(
        'f()',
        externalLookup: {
          'f': MontyHostFunction(
            'f',
            (args, kwargs) => const MontyString('\uD800'),
          ),
        },
      );
      final result = itemAt(ch.requests, 2).resumeCall.result;
      expect(result.error.excType, 'UnicodeEncodeError');
      expect(result.error.message, contains('surrogates not allowed'));
      expect(result.hasReturnValue(), isFalse);
    });

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
        externalLookup: {
          'f': MontyHostFunction('f', (args, kwargs) => const MontyNone()),
        },
      );
      final error = itemAt(ch.requests, 2).resumeCall.result.error;
      expect(error.message, contains('a keyword argument name must be a str'));
    });

    test(
      'a complex argument reaches the host function',
      () async {
        final ch = _configured([
          answer([
            _functionCall('f', [_complex], args: [0]),
          ]),
          answer([completeNone()]),
        ]);
        final s = await ProtoSession.open(ch);
        List<MontyValue>? got;
        await s.feed(
          'f(1j)',
          externalLookup: {
            'f': MontyHostFunction('f', (
              args,
              kwargs,
            ) {
              got = args;

              return const MontyNone();
            }),
          },
        );
        expect(got, [_complexValue]);
        expect(itemAt(ch.requests, 2).resumeCall.result.hasError(), isFalse);
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
        expect(args, [MontyPath('/p')]);
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
        expect(onlyItem(argLists), [MontyPath('/x')]);
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
      'OS calls are declined by OsCallNotHandledException',
      () async {
        pb.ChildEvent os(int id, pb.OsCall call) =>
            pb.ChildEvent(osCall: call..callId = id);
        final ch = _configured([
          answer([os(1, pb.OsCall(exists: '/a'))]),
          answer([os(2, pb.OsCall(isFile: '/b'))]),
          answer([
            os(
              3,
              pb.OsCall(
                getenv: pb.OsCall_Getenv(key: 'HOME'),
                values: pb.Arena(
                  nodeCount: 1,
                  nodes: [pb.MontyNode(none: pb.Unit())],
                ),
              ),
            ),
          ]),
          answer([os(4, pb.OsCall(readBytes: '/c'))]),
          answer([completeNone()]),
        ]);
        final s = await ProtoSession.open(ch);
        final names = <String>[];
        await s.feed(
          'os',
          onOsCall: (name, args, kwargs) {
            names.add(name);
            throw const OsCallNotHandledException();
          },
        );
        expect(names, [
          'Path.exists',
          'Path.is_file',
          'os.getenv',
          'Path.read_bytes',
        ]);
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
        onOsCall: (name, args, kwargs) =>
            throw const ExternalException('FileNotFoundError', 'missing'),
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
        expect(error?.toString(), 'ValueError: bad 7');
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
              .having((e) => e.toString(), 'message', 'invalid syntax')
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
              .having((e) => e.toString(), 'message', 'KeyboardInterrupt')
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
                (e) => e.toString(),
                'message',
                startsWith(
                  'monty worker protocol error: invalid payload from worker: ',
                ),
              ),
        ),
      );
      expect(ch.kills, 1);
    });

    // Upstream classifies every TypingError event as PoolError::Typing,
    // whatever the session's type check (checkout.rs:1854-1858).
    test(
      'a TypingError on a session without a type check is still one',
      () async {
        final ch = _configured([
          answer([
            pb.ChildEvent(typingError: pb.TypingError(diagnostics: 'x')),
          ]),
        ]);
        final s = await ProtoSession.open(ch);
        await expectLater(
          s.feed('x'),
          throwsA(isA<MontyTypingError>().having((e) => '$e', 'toString', 'x')),
        );
        expect(ch.kills, 0);
      },
    );

    test('an event that cannot end a feed kills the worker', () async {
      for (final event in [
        ok(),
        pb.ChildEvent(resolveFutures: pb.ResolveFutures()),
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
                  (e) => e.toString(),
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
      'a complex in Complete decodes, worker still in step',
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
        expect((await s.feed('1j')).value, _complexValue);
        expect((await s.feed('True')).value, const MontyBool(true));
      },
    );
  });

  // Upstream converts a suspension's payload when the frame arrives, before
  // any host code runs (monty-pool 1.1.0 checkout.rs:1743-1752 and
  // :1761-1765); a payload that fails is a protocol violation, and the
  // worker is discarded. Only the Python objects built from a valid arena
  // (stage 3) fail the call in Python instead.
  group('a host call payload upstream rejects', () {
    Matcher violation(String detail) => throwsA(
      isA<MontyCrashedError>()
          .having((e) => e.cause, 'cause', CrashCause.protocol)
          .having((e) => e.timedOut, 'timedOut', isFalse)
          .having((e) => e.exitCode, 'exitCode', isNull)
          .having(
            (e) => e.toString(),
            'message',
            'monty worker protocol error: $detail',
          ),
    );
    const notBelow =
        'invalid payload from worker: invalid value for Arena: value node 1 '
        'references node 7, which is not below it';
    final badArena = [
      intNode(1),
      pb.MontyNode(list: pb.Indexes(items: [7])),
    ];

    test('an argument arena whose node references one above it', () async {
      final ch = _configured([
        answer([
          _functionCall('f', badArena, args: [0]),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      var called = false;
      await expectLater(
        s.feed(
          'f(1)',
          externalLookup: {
            'f': MontyHostFunction('f', (args, kwargs) {
              called = true;

              return const MontyNone();
            }),
          },
        ),
        violation(notBelow),
      );
      expect(called, isFalse);
      expect(ch.kills, 1);
      expect(ch.requests, hasLength(2));
    });

    test('an argument root outside the arena, the function unknown', () async {
      final ch = _configured([
        answer([
          _functionCall('g', [intNode(1)], args: [3]),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(
        s.feed('g(1)'),
        violation(
          'invalid payload from worker: invalid value for Arena: value root 3 '
          'is out of range for an arena of 1 nodes',
        ),
      );
      expect(ch.kills, 1);
    });

    test('a keyword value root outside the arena', () async {
      final ch = _configured([
        answer([
          _functionCall(
            'f',
            [pb.MontyNode(str: 'k'), intNode(1)],
            kwargs: [pb.NodePair(key: 0, value: 9)],
          ),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(
        s.feed(
          'f(k=1)',
          externalLookup: {
            'f': MontyHostFunction('f', (args, kwargs) => const MontyNone()),
          },
        ),
        violation(
          'invalid payload from worker: invalid value for Arena: value root 9 '
          'is out of range for an arena of 2 nodes',
        ),
      );
      expect(ch.kills, 1);
    });

    test('a method call, before its name is checked', () async {
      final ch = _configured([
        answer([
          pb.ChildEvent(
            functionCall: pb.FunctionCall(
              functionName: '_hidden',
              callId: 7,
              objectId: pb.Uuid(data: List.filled(16, 1)),
              args: [0],
              values: pb.Arena(nodeCount: 2, nodes: badArena),
            ),
          ),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(s.feed('o._hidden(1)'), violation(notBelow));
      expect(ch.kills, 1);
    });

    test('an OS call no arm describes', () async {
      final ch = _configured([
        answer([pb.ChildEvent(osCall: pb.OsCall(callId: 1))]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(
        s.feed('x', onOsCall: (name, args, kwargs) => const MontyNone()),
        violation(
          'invalid OS call payload: missing required field OsCall.call',
        ),
      );
      expect(ch.kills, 1);
    });

    test("a getenv whose default's root is outside its arena", () async {
      final ch = _configured([
        answer([
          pb.ChildEvent(
            osCall: pb.OsCall(
              callId: 1,
              getenv: pb.OsCall_Getenv(key: 'K', default_2: 3),
              values: pb.Arena(nodeCount: 1, nodes: [intNode(1)]),
            ),
          ),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(
        s.feed('x', onOsCall: (name, args, kwargs) => const MontyNone()),
        violation(
          'invalid OS call payload: invalid value for Arena: value root 3 is '
          'out of range for an arena of 1 nodes',
        ),
      );
      expect(ch.kills, 1);
    });

    test('a getenv default that passes the checks but cannot be built '
        'fails the call in Python, not the session', () async {
      final ch = _configured([
        answer([
          pb.ChildEvent(
            osCall: pb.OsCall(
              callId: 1,
              getenv: pb.OsCall_Getenv(key: 'K'),
              values: pb.Arena(
                nodeCount: 1,
                nodes: [
                  pb.MontyNode(timedelta: pb.TimeDelta(days: 1000000000)),
                ],
              ),
            ),
          ),
        ]),
        answer([completeNone()]),
      ]);
      final s = await ProtoSession.open(ch);
      await s.feed('x', onOsCall: (name, args, kwargs) => const MontyNone());
      final result = itemAt(ch.requests, 2).resumeCall.result;
      expect(result.hasError(), isTrue);
      expect(result.error.message, contains('OverflowError'));
      expect(ch.kills, 0);
    });

    test('a getenv with no arena', () async {
      final ch = _configured([
        answer([
          pb.ChildEvent(
            osCall: pb.OsCall(
              callId: 1,
              getenv: pb.OsCall_Getenv(key: 'K'),
            ),
          ),
        ]),
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(
        s.feed('x'),
        violation(
          'invalid OS call payload: missing required field OsCall.values',
        ),
      );
      expect(ch.kills, 1);
    });
  });

  group('Feed on the wire, as upstream 1.1.0 sends it', () {
    // The bytes of each `ParentRequest`, as monty-pool 1.1.0's
    // `Checkout::feed_with_cwd` builds it (no mounts, no explicit cwd) and
    // prost encodes it: the arena always present, zero and empty fields left
    // out, `cwd` "/" on the session's first feed only. Upstream 1.2.0 counts
    // the directory as established once a feed is sent, one the type check
    // refuses included, so the feed after a refused one carries no cwd
    // (1.1.0 named the default again there).
    const firstNoInputs = '1a0c0a0531202b20311a002a012f';
    const laterNoInputs = '1a090a0531202b20311a00';
    const firstTwoInputs =
        '1a240a0561202b206212030a016112050a016210011a0c08021202280a12044202'
        '68692a012f';
    const laterOneInput = '1a100a016112030a01611a0608011202280a';

    String hexOf(pb.ParentRequest request) => [
      for (final b in request.writeToBuffer())
        b.toRadixString(16).padLeft(2, '0'),
    ].join();

    List<String> feedsSent(ScriptedChannel ch) => [
      for (final r in ch.requests)
        if (r.whichKind() == pb.ParentRequest_Kind.feed) hexOf(r),
    ];

    const code = '1 + 1';
    final done = answer([completeNone()]);

    test('raw step defaults cwd only until the first accepted feed', () async {
      final ch = _configured([done, done, done]);
      final session = await ProtoSession.open(ch);
      addTearDown(session.close);
      for (final cwd in [null, '/saved', null]) {
        final event = await session.step(
          pb.ParentRequest(
            feed: pb.Feed(code: code, cwd: cwd),
          ),
        );
        expect(event.whichKind(), pb.ChildEvent_Kind.complete);
      }
      expect(
        ch.requests
            .where((request) => request.hasFeed())
            .map((request) => request.feed.cwd),
        ['/', '/saved', ''],
      );
    });

    /// Feeds [code] [times] times, each completing.
    Future<void> feedTimes(ProtoSession s, int times) async {
      for (var i = 0; i < times; i++) {
        await s.feed(code);
      }
    }

    test(
      'the first feed switches to "/", later ones keep the directory',
      () async {
        final ch = _configured([done, done]);
        await feedTimes(await ProtoSession.open(ch), 2);
        expect(feedsSent(ch), [firstNoInputs, laterNoInputs]);
      },
    );

    test("inputs: the first ref's zero index is left out", () async {
      final ch = _configured([done, done]);
      final s = await ProtoSession.open(ch);
      await s.feed(
        'a + b',
        inputs: {'a': const MontyInt(5), 'b': const MontyString('hi')},
      );
      await s.feed('a', inputs: {'a': const MontyInt(5)});
      expect(feedsSent(ch), [firstTwoInputs, laterOneInput]);
    });

    // Measured on upstream pydantic-monty 1.2.0 (one checkout with
    // type_check=True): the worker adopts a feed's directory before it
    // type-checks the snippet, so a feed the type check refuses establishes
    // the directory all the same. A refused first feed (no mounts, no
    // explicit cwd) leaves the session at "/" (measured), and the feed
    // after it carries no cwd (measured: the session still reports "/"),
    // as does the one after that.
    test(
      'a feed the type check refuses still establishes the directory',
      () async {
        final ch = _configured([
          answer([
            pb.ChildEvent(typingError: pb.TypingError(diagnostics: 'x')),
          ]),
          done,
          done,
        ]);
        final s = await ProtoSession.open(
          ch,
          const SessionConfig(typeCheck: true),
        );
        await expectLater(s.feed(code), throwsA(isA<MontyTypingError>()));
        await feedTimes(s, 2);
        expect(feedsSent(ch), [firstNoInputs, laterNoInputs, laterNoInputs]);
      },
    );

    test('a Python error still sets the directory', () async {
      final ch = _configured([
        answer([
          pb.ChildEvent(
            error: pb.Error(
              exception: pb.RaisedException(
                excType: 'ValueError',
                message: 'x',
              ),
            ),
          ),
        ]),
        done,
      ]);
      final s = await ProtoSession.open(ch);
      await expectLater(s.feed(code), throwsA(isA<MontyRuntimeError>()));
      await feedTimes(s, 1);
      expect(feedsSent(ch), [firstNoInputs, laterNoInputs]);
    });

    test(
      'an oversized feed is never sent, so the next is still first',
      () async {
        final ch = ScriptedChannel([
          expecting(pb.ParentRequest_Kind.configure, [ok()]),
          done,
        ], frameLimit: 64);
        final s = await ProtoSession.open(ch);
        await expectLater(
          s.feed('x' * 100),
          throwsA(isA<FrameTooLargeException>()),
        );
        await feedTimes(s, 1);
        expect(feedsSent(ch), [firstNoInputs]);
      },
    );

    test("after reset the next feed is a new session's first", () async {
      final accepted = [ok()];
      final ch = _configured([
        done,
        expecting(pb.ParentRequest_Kind.reset, accepted),
        expecting(pb.ParentRequest_Kind.configure, accepted),
        done,
      ]);
      final s = await ProtoSession.open(ch);
      for (final resetFirst in [false, true]) {
        if (resetFirst) await s.reset();
        await s.feed(code);
      }
      expect(feedsSent(ch), [firstNoInputs, firstNoInputs]);
    });
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
      s.objects.register(_hostBox);
      await s.reset();
      expect(ch.remaining, 0);
      expect(
        itemAt(ch.requests, 2).configure.limits.maxRecursionDepth,
        Int64(50),
      );
      // A reset session holds no host objects, as a new checkout holds none.
      expect(s.objects[_hostBox.id], isNull);
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
            (e) => e.toString(),
            'message',
            'monty worker protocol error: unexpected reply to Reset: complete',
          ),
        ),
      );
      expect(ch.kills, 1);
    });

    test('an InstallDependencies answered with Ok succeeds, with anything '
        'else is a desync (TGT1 B)', () async {
      final ch = _configured([
        expecting(pb.ParentRequest_Kind.installDependencies, [ok()]),
        answer([completeNone()]),
      ]);
      final s = await ProtoSession.open(ch);
      await s.installDependencies(['numpy']);
      expect(
        itemAt(ch.requests, 1).installDependencies.requirements,
        ['numpy'],
      );
      await expectLater(
        s.installDependencies(['numpy']),
        throwsA(
          isA<MontyCrashedError>().having(
            (e) => e.toString(),
            'message',
            'monty worker protocol error: unexpected reply to '
                'InstallDependencies: complete',
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

  test(
    'session modules stay live and Import precedes mounts and OS handlers',
    () async {
      await _liveFeeds();
      await _lookupAndErrors();
      await _automaticResume();
      await _mountPrecedenceAndScan();
    },
  );

  test(
    'module factories cache successes and retry failed resolutions',
    () async {
      await _factoryCachesSuccesses();
      await _factoryAnswersDottedCalls();
      await _factoryFutureIsAwaited();
      await _factoryFailuresAreRetried();
      await _directEntriesAreNotCached();
      await _factorySurvivesReset();
      await _factorySurvivesLoad();
      await _factoryInstalledBeforeConversion();
      await _factorySurvivesAutomaticResume();
    },
  );
}

/// A `complex` node, `1j`.
final pb.MontyNode _complex = pb.MontyNode(
  complex: pb.Complex(real: doubleToBits(0), imag: doubleToBits(1)),
);

/// What [_complex] decodes to.
const MontyValue _complexValue = MontyComplex(0, 1);

// ---------------------------------------------------------------------------
// The session's modules: the map is read live, and an import is answered
// before the mounts and the OS handler see it.
//
// The `import` arm of an OS call is not in the bindings yet, so the worker
// protocol rejects the call: the test fails on the first import, through
// the matcher that wants the feed to succeed.
// ---------------------------------------------------------------------------

/// The module the scenarios import.
const String _tools = 'tools';

/// The module a second factory builds, for the calls that fail.
const String _otherTools = 'other_tools';

/// The module a third factory builds, with a nested module.
const String _nestedTools = 'nested_tools';

/// The module the mapping holds with no value.
const String _nullTools = 'null_tools';

/// The module the mapping does not hold.
const String _absent = 'absent';

/// A module name that is not an identifier.
const String _badName = 'bad name';

/// The module whose attribute cannot be converted.
const String _badValue = 'bad_value';

/// The version a module carries, as the scenarios replace it.
const int _versionOne = 1;

/// The version the replacement module carries.
const int _versionTwo = 2;

/// The version the module that comes back carries.
const int _versionThree = 3;

/// The version the module replaced while a feed is suspended carries.
const int _versionFive = 5;

/// A version above 2^32, so a module that is not the one asked for can
/// never pass as it: it is still below 2^53, so it is exact on every
/// platform, dart2js included.
const int _versionLarge = 4294967297;

/// The modules a session offers, and the imports it answers.
///
/// The map is the session's own: it is kept as it is and read live, so an
/// entry added, replaced or removed after the session opened is seen by the
/// next import.
Future<void> _liveFeeds() async {
  final modules = {
    // A name that is not an identifier, and is never asked for: opening the
    // session and importing another name must not look at it.
    _badName: ExternalModule({'VERSION': _versionOne}),
  };
  final osCalls = <String>[];
  final answered = <int>[];
  final done = completeNone();
  final ended = expecting(pb.ParentRequest_Kind.resumeCall, [done]);
  final channel = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    // The first feed: the module is absent.
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(1, _tools)]),
    ended,
    // The second feed: the import, the module that replaced it, and the
    // module that was removed, all answered within the one feed.
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(2, _tools)]),
    (request) {
      answered.add(request.resumeCall.callId);
      modules[_tools] = ExternalModule({'VERSION': _versionTwo});

      return [_importEvent(3, _tools)];
    },
    (request) {
      answered.add(request.resumeCall.callId);
      modules.remove(_tools);

      return [_importEvent(4, _tools)];
    },
    ended,
    // The third feed: the module is back, with another version.
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(5, _tools)]),
    ended,
  ]);
  final session = await ProtoSession.open(
    channel,
    SessionConfig(externalModules: modules),
  );
  addTearDown(session.close);

  // The map is the session's own: it is not copied.
  expect(session.externalModules, same(modules));

  // The module is absent: the import finds nothing, and the name that is
  // not an identifier is not looked at.
  await _feedOk(session, 'import tools', osCalls);
  _expectNotFound(channel, 1, 'import');
  expect(osCalls, isEmpty, reason: 'the OS handler never sees an import');

  // The module is added after the session opened: the import answers with
  // it, then with the one that replaced it, then with nothing.
  modules[_tools] = ExternalModule({'VERSION': _versionOne});
  await _feedOk(session, 'import tools', osCalls);
  expect(answered, [2, 3], reason: 'the feed answered both imports');
  _expectImportedModule(channel, 2, _tools, _versionOne);
  _expectImportedModule(channel, 3, _tools, _versionTwo);
  _expectNotFound(channel, 4, 'import');
  expect(osCalls, isEmpty, reason: 'the OS handler never sees an import');

  // The module was removed while the feed ran: the host's map no longer
  // holds it.
  expect(modules.containsKey(_tools), isFalse);

  // The module is added again: the next feed answers with it.
  modules[_tools] = ExternalModule({'VERSION': _versionThree});
  await _feedOk(session, 'import tools', osCalls);
  _expectImportedModule(channel, 5, _tools, _versionThree);
  expect(osCalls, isEmpty, reason: 'the OS handler never sees an import');

  await _omittedMapsAreOwn();
}

/// Two sessions without a module map own one each: mutable, and their own.
Future<void> _omittedMapsAreOwn() async {
  const open = ProtoSession.open;
  final sessions = <ProtoSession>[];
  for (var count = 0; count < 2; count++) {
    sessions.add(await open(_configured([])));
  }
  addTearDown(itemAt(sessions, 0).close);
  addTearDown(itemAt(sessions, 1).close);
  final first = itemAt(sessions, 0);
  final second = itemAt(sessions, 1);
  expect(first.externalModules, isEmpty);
  expect(first.externalModules, isNot(same(second.externalModules)));
  first.externalModules[_tools] = ExternalModule({'VERSION': _versionOne});
  expect(first.externalModules, hasLength(1));
  expect(second.externalModules, isEmpty);
}

/// The lookup of a module name, and the errors an import reports.
Future<void> _lookupAndErrors() async {
  final modules = {
    _tools: ExternalModule({'VERSION': _versionOne}),
  };
  final osCalls = <String>[];
  final done = completeNone();
  final ended = expecting(pb.ParentRequest_Kind.resumeCall, [done]);
  final channel = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    // The name is absent: the import finds no module.
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(1, _badName)]),
    ended,
    // The name is there now, and it is not an identifier.
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(2, _badName)]),
    ended,
    // A valid module still imports after that failure.
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(3, _tools)]),
    ended,
    // A module whose attribute cannot be converted.
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(4, _badValue)]),
    ended,
    // And a valid module still imports after that failure too.
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(5, _tools)]),
    ended,
  ]);
  final session = await ProtoSession.open(
    channel,
    SessionConfig(externalModules: modules),
  );
  addTearDown(session.close);

  // The name is absent: the import is not found, and the name is not
  // checked.
  await _feedOk(session, 'import bad name', osCalls);
  _expectNotFound(channel, 1, 'import');
  expect(osCalls, isEmpty, reason: 'the OS handler never sees an import');

  // The name is there, and it is not an identifier: the import fails, with
  // the name in the message.
  modules[_badName] = ExternalModule({'VERSION': _versionOne});
  await _feedOk(session, 'import bad name', osCalls);
  _expectError(channel, 2, 'ValueError', _badName);
  expect(osCalls, isEmpty, reason: 'the OS handler never sees an import');

  // The session is still usable.
  await _feedOk(session, 'import tools', osCalls);
  _expectImportedModule(channel, 3, _tools, _versionOne);
  expect(osCalls, isEmpty, reason: 'the OS handler never sees an import');

  // A module whose attribute cannot be converted fails the import, with
  // the conversion in the message: the name is valid, so the name is not
  // what fails.
  modules[_badValue] = ExternalModule({'bad': Object()});
  await _feedOk(session, 'import bad value', osCalls);
  _expectError(channel, 4, 'TypeError', 'Cannot convert');
  expect(osCalls, isEmpty, reason: 'the OS handler never sees an import');

  // And the session is still usable.
  await _feedOk(session, 'import tools', osCalls);
  _expectImportedModule(channel, 5, _tools, _versionOne);
  expect(osCalls, isEmpty, reason: 'the OS handler never sees an import');
}

/// The modules a suspended feed sees: the map is read live across a
/// suspension.
Future<void> _automaticResume() async {
  final modules = {
    _tools: ExternalModule({'VERSION': _versionThree}),
  };
  final osCalls = <String>[];
  final done = completeNone();
  final ended = expecting(pb.ParentRequest_Kind.resumeCall, [done]);
  final (session, channel) = await poolB2Session(
    [
      expecting(pb.ParentRequest_Kind.feed, [_importEvent(1, _tools)]),
      ended,
      expecting(pb.ParentRequest_Kind.feed, [_importEvent(2, _tools)]),
      ended,
      expecting(pb.ParentRequest_Kind.feed, [_importEvent(3, _tools)]),
      ended,
    ],
    config: SessionConfig(externalModules: modules),
  );
  await _resumeWithReplacedModule(session, channel, modules, osCalls);
  await _resumeWithRemovedModule(session, channel, modules, osCalls);
  await _feedAfterResume(session, channel, modules, osCalls);
}

/// The module is replaced while the feed is suspended: the resume answers
/// with the module the session holds now.
Future<void> _resumeWithReplacedModule(
  MontySession session,
  ScriptedChannel channel,
  Map<String, ExternalModule> modules,
  List<String> osCalls,
) async {
  final snapshot = await _suspendedOnImport(session, _recording(osCalls));
  expect(snapshot.functionName, 'import');
  expect(snapshot.isOsFunction, isTrue);
  modules[_tools] = ExternalModule({'VERSION': _versionFive});
  final resumed = await _outcome(snapshot.resumeAuto);
  _expectNoError(resumed, 'the feed');
  expect(resumed.value, isA<MontyComplete>(), reason: 'the feed completes');
  _expectImportedModule(channel, snapshot.callId, _tools, _versionFive);
  expect(osCalls, isEmpty, reason: 'the OS handler never sees an import');
}

/// The module is gone while the feed is suspended: the import finds
/// nothing.
Future<void> _resumeWithRemovedModule(
  MontySession session,
  ScriptedChannel channel,
  Map<String, ExternalModule> modules,
  List<String> osCalls,
) async {
  final snapshot = await _suspendedOnImport(session, _recording(osCalls));
  modules.remove(_tools);
  final resumed = await _outcome(snapshot.resumeAuto);
  _expectNoError(resumed, 'the feed');
  expect(resumed.value, isA<MontyComplete>(), reason: 'the feed completes');
  _expectNotFound(channel, snapshot.callId, 'import');
  expect(osCalls, isEmpty, reason: 'the OS handler never sees an import');
}

/// The session is still usable after the resumes.
Future<void> _feedAfterResume(
  MontySession session,
  ScriptedChannel channel,
  Map<String, ExternalModule> modules,
  List<String> osCalls,
) async {
  modules[_tools] = ExternalModule({'VERSION': _versionThree});
  final outcome = await _outcome(
    () => session.feedRun('import tools', os: _recording(osCalls)),
  );
  _expectNoError(outcome, 'the feed');
  _expectImportedModule(channel, 3, _tools, _versionThree);
  expect(osCalls, isEmpty, reason: 'the OS handler never sees an import');
}

/// An import is answered before the mounts and the OS handler see it.
Future<void> _mountPrecedenceAndScan() async {
  final modules = {
    _tools: ExternalModule({'VERSION': _versionLarge}),
    _badName: ExternalModule({'VERSION': _versionOne}),
    _badValue: ExternalModule({'bad': Object()}),
  };
  final mountCalls = <List<int>>[];
  final osCalls = <(String, List<MontyValue>)>[];
  final order = <String>[];
  final mountsAfterImport = <int>[];
  final handlersAfterImport = <int>[];
  final one = hasLength(1);
  final channel = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(1, _tools)]),
    (request) {
      mountsAfterImport.add(mountCalls.length);
      handlersAfterImport.add(osCalls.length);

      return [_importEvent(2, 'absent')];
    },
    (request) {
      mountsAfterImport.add(mountCalls.length);
      handlersAfterImport.add(osCalls.length);

      return [_importEvent(3, _badName)];
    },
    (request) {
      mountsAfterImport.add(mountCalls.length);
      handlersAfterImport.add(osCalls.length);

      return [_importEvent(4, _badValue)];
    },
    (request) {
      mountsAfterImport.add(mountCalls.length);
      handlersAfterImport.add(osCalls.length);

      return [_scanEvent(5, '/data')];
    },
    expecting(pb.ParentRequest_Kind.resumeCall, [completeNone()]),
  ]);
  final session = await ProtoSession.open(
    channel,
    SessionConfig(externalModules: modules),
  );
  addTearDown(session.close);
  final host = HostAnswers(
    externalModules: session.externalModules,
    os: (name, args, _) {
      order.add('os');
      osCalls.add((name, args));

      return const MontyList([]);
    },
    mountRoute: (bytes) {
      order.add('mount');
      mountCalls.add(bytes);

      return null;
    },
  );

  final driven = await _outcome(
    () => session.drive(session.prepareFeed('import tools', const {}), host),
  );
  _expectNoError(driven, 'the feed');

  // Every import was answered before the mounts and the OS handler saw it.
  expect(
    mountsAfterImport,
    [0, 0, 0, 0],
    reason: 'an import never reaches the mounts',
  );
  expect(
    handlersAfterImport,
    [0, 0, 0, 0],
    reason: 'an import never reaches the OS handler',
  );

  // The imports answered as they must.
  _expectImportedModule(channel, 1, _tools, _versionLarge);
  _expectNotFound(channel, 2, 'import');
  _expectError(channel, 3, 'ValueError', _badName);
  _expectError(channel, 4, 'TypeError', 'Cannot convert');

  // The scan goes to the mounts, which decline it, and then to the OS
  // handler.
  expect(mountCalls, one, reason: 'the scan reaches the mounts');
  expect(osCalls, one, reason: 'the scan reaches the handler');
  final handled = onlyItem(osCalls);
  expect(handled.$1, 'Path.scan');
  expect(handled.$2, [MontyPath('/data')]);
  expect(order, ['mount', 'os'], reason: 'the mounts come first');

  // The scan's answer is an empty list, under the call's own id.
  final answer = _answerFor(channel, 5);
  expect(
    answer.result.whichKind(),
    pb.ExtFunctionResult_Kind.returnValue,
    reason: 'the scan returns a value',
  );
  final nodes = answer.values.nodes;
  final root = answer.result.returnValue;
  expect(root, inInclusiveRange(0, nodes.length - 1));
  final listed = itemAt(nodes, root);
  expect(listed.hasList(), isTrue, reason: 'the scan returns a list');
  expect(listed.list.items, isEmpty);
  expect(answer.callId, 5);
}

// ---------------------------------------------------------------------------
// The session's module factories: a factory runs once per session, its
// result is cached, and a failure is not.
//
// Upstream (monty-python 1.2.0, `src/external.rs`): the mapping holds a
// module or a factory returning one. The factory runs at the first import,
// call or stubs ask that needs it, and its validated result is cached for
// the session; a factory that fails is raised there, and the next use runs
// it again.
// ---------------------------------------------------------------------------

/// The module a factory failure is raised as, when the host raises one of
/// its own.
final class _FactoryFailure implements Exception {
  const _FactoryFailure(this.message);

  /// The failure's own text.
  final String message;

  @override
  String toString() => message;
}

/// The configuration of a session offering the modules [modules].
///
/// The mapping is passed dynamically: the tree this test was written
/// against declares the parameter with the narrow type of a module map, so
/// a plain call would not compile there. The construction is checked by the
/// caller, outside the catch, so a failure is an assertion and not a
/// thrown error.
SessionConfig _configWith(Map<String, Object?> modules) =>
    Function.apply(
          SessionConfig.new,
          const [],
          {#externalModules: modules},
        )
        as SessionConfig;

/// The session on [channel] offering the modules [modules].
Future<ProtoSession> _sessionWith(
  ScriptedChannel channel,
  Map<String, Object?> modules,
) async {
  final built = await _outcome(() async => _configWith(modules));
  expect(built.error, isNull, reason: 'the session configuration is built');
  final config = switch (built.value) {
    final SessionConfig made => made,
    _ => fail('the session configuration is built'),
  };

  return ProtoSession.open(channel, config);
}

/// A factory runs once per session: its result is cached, and the mapping
/// may change under it.
Future<void> _factoryCachesSuccesses() async {
  final modules = <String, Object?>{};
  var calls = 0;
  modules[_tools] = () {
    calls++;

    return ExternalModule({'VERSION': _versionOne});
  };
  final osCalls = <String>[];
  final done = completeNone();
  final ended = expecting(pb.ParentRequest_Kind.resumeCall, [done]);
  final channel = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    // A feed that asks for nothing: no factory runs for it.
    expecting(pb.ParentRequest_Kind.feed, [done]),
    // The first import runs the factory.
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(1, _tools)]),
    ended,
    // The second import is answered from the cache.
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(2, _tools)]),
    ended,
    // The third and the fourth import are answered from the cache too,
    // although the mapping changed under them.
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(3, _tools)]),
    ended,
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(4, _tools)]),
    ended,
  ]);
  final session = await _sessionWith(channel, modules);
  addTearDown(session.close);

  // A feed that needs no module runs no factory.
  await _feedOk(session, 'x = 1', osCalls);
  expect(calls, 0, reason: 'no factory runs before a module is needed');

  // The first import runs the factory and answers with its module.
  await _feedOk(session, 'import tools', osCalls);
  _expectImportedModule(channel, 1, _tools, _versionOne);
  expect(calls, 1, reason: 'the factory runs once');

  // The second import is answered from the cache.
  await _feedOk(session, 'import tools', osCalls);
  _expectImportedModule(channel, 2, _tools, _versionOne);
  expect(calls, 1, reason: 'the cached module answers the second import');

  // The mapping is replaced: the cached module still answers.
  modules[_tools] = ExternalModule({'VERSION': _versionTwo});
  await _feedOk(session, 'import tools', osCalls);
  _expectImportedModule(channel, 3, _tools, _versionOne);
  expect(calls, 1, reason: 'the cached module answers the third import');

  // The mapping is emptied: the cached module still answers, and the
  // factory does not run again.
  modules.remove(_tools);
  await _feedOk(session, 'import tools', osCalls);
  _expectImportedModule(channel, 4, _tools, _versionOne);
  expect(calls, 1, reason: 'the cached module answers the fourth import');
}

/// A dotted call resolves its module as an import does: the factory runs
/// for it, its result is cached, and a factory that fails answers the call
/// as it answers an import.
Future<void> _factoryAnswersDottedCalls() async {
  final modules = <String, Object?>{};
  var calls = 0;
  final add = MontyHostFunction('add', (args, kwargs) => const MontyInt(3));
  modules[_tools] = () {
    calls++;

    return ExternalModule({'add': add});
  };
  modules[_otherTools] = () => throw ArgumentError(
    'Cannot convert factory input',
  );
  modules[_nestedTools] = () {
    calls++;

    return ExternalModule({
      'sub': ExternalModule({'add': add}),
    });
  };
  final osCalls = <String>[];
  final done = completeNone();
  final ended = expecting(pb.ParentRequest_Kind.resumeCall, [done]);
  final channel = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    expecting(
      pb.ParentRequest_Kind.feed,
      [_functionCall('tools.add', const [], callId: 11)],
    ),
    ended,
    expecting(
      pb.ParentRequest_Kind.feed,
      [_functionCall('tools.add', const [], callId: 12)],
    ),
    ended,
    // A factory that fails: the failure is raised as it is, not as the
    // `TypeError` an unconvertible attribute raises.
    expecting(
      pb.ParentRequest_Kind.feed,
      [_functionCall('other_tools.add', const [], callId: 13)],
    ),
    ended,
    // A call into a nested module awaits the top-level factory only.
    expecting(
      pb.ParentRequest_Kind.feed,
      [_functionCall('nested_tools.sub.add', const [], callId: 14)],
    ),
    ended,
  ]);
  final session = await _sessionWith(channel, modules);
  addTearDown(session.close);

  // The first call runs the factory and calls the module's own function.
  await _feedOk(session, 'tools.add()', osCalls);
  _expectValue(channel, 11, BigInt.from(3));
  expect(calls, 1, reason: 'the factory runs once');

  // The second call is answered from the cache.
  await _feedOk(session, 'tools.add()', osCalls);
  _expectValue(channel, 12, BigInt.from(3));
  expect(calls, 1, reason: 'the cached module answers the second call');

  // A factory that throws answers the call as an exception of its own.
  await _feedOk(session, 'other_tools.add()', osCalls);
  _expectError(channel, 13, 'Exception', 'Cannot convert factory input');

  // A call into a nested module runs the top-level factory and walks
  // through the module it built.
  await _feedOk(session, 'nested_tools.sub.add()', osCalls);
  _expectValue(channel, 14, BigInt.from(3));
  expect(calls, 2, reason: 'the nested module runs its own factory');
}

/// A factory's future is awaited before the answer is made.
Future<void> _factoryFutureIsAwaited() async {
  final modules = <String, Object?>{};
  final gate = Completer<ExternalModule>();
  var ran = false;
  modules[_tools] = () {
    ran = true;

    return gate.future;
  };
  final osCalls = <String>[];
  final done = completeNone();
  final ended = expecting(pb.ParentRequest_Kind.resumeCall, [done]);
  final channel = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(1, _tools)]),
    ended,
  ]);
  final session = await _sessionWith(channel, modules);
  addTearDown(session.close);

  final feed = session.feed('import tools', onOsCall: _recording(osCalls));
  await _waitUntil(() => ran);

  // The answer waits for the factory's future.
  expect(_answers(channel), 0, reason: 'the import is not answered yet');
  gate.complete(ExternalModule({'VERSION': _versionOne}));
  final outcome = await _outcome(() => feed);
  _expectNoError(outcome, 'the feed');
  _expectImportedModule(channel, 1, _tools, _versionOne);
}

/// A factory that fails leaves nothing behind: the next request runs it
/// again, and it may succeed then.
Future<void> _factoryFailuresAreRetried() async {
  await _factoryFailureIsRetried(
    () => throw const _FactoryFailure('boom'),
    'Exception',
    'boom',
  );
  await _factoryFailureIsRetried(
    () => 3,
    'TypeError',
    'not an ExternalModule',
  );
  await _factoryFutureFailureIsRetried(
    (gate) => gate.completeError(
      const _FactoryFailure('boom'),
      StackTrace.current,
    ),
    'Exception',
    'boom',
  );
  await _factoryFutureFailureIsRetried(
    (gate) => gate.complete(3),
    'TypeError',
    'not an ExternalModule',
  );
}

/// The import that reaches the failing factory [factory] fails with
/// [excType], and the import after it runs the factory again and answers
/// with the module.
Future<void> _factoryFailureIsRetried(
  Object? Function() factory,
  String excType,
  String detail,
) async {
  final modules = <String, Object?>{};
  var calls = 0;
  modules[_tools] = () {
    calls++;

    return calls == 1 ? factory() : ExternalModule({'VERSION': _versionOne});
  };
  final osCalls = <String>[];
  final done = completeNone();
  final ended = expecting(pb.ParentRequest_Kind.resumeCall, [done]);
  final channel = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(1, _tools)]),
    ended,
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(2, _tools)]),
    ended,
  ]);
  final session = await _sessionWith(channel, modules);
  addTearDown(session.close);

  await _feedOk(session, 'import tools', osCalls);
  _expectError(channel, 1, excType, detail);
  expect(calls, 1, reason: 'the factory ran once');

  // The failure was not cached: the factory runs again, and it succeeds.
  await _feedOk(session, 'import tools', osCalls);
  _expectImportedModule(channel, 2, _tools, _versionOne);
  expect(calls, 2, reason: 'the failed factory runs again');
}

/// The import that reaches the factory whose future [fail] fails answers
/// the failure, and the import after it runs the factory again.
Future<void> _factoryFutureFailureIsRetried(
  void Function(Completer<Object?> gate) fail,
  String excType,
  String detail,
) async {
  final modules = <String, Object?>{};
  final gate = Completer<Object?>();
  var calls = 0;
  modules[_tools] = () {
    calls++;

    return calls == 1 ? gate.future : ExternalModule({'VERSION': _versionOne});
  };
  final osCalls = <String>[];
  final done = completeNone();
  final ended = expecting(pb.ParentRequest_Kind.resumeCall, [done]);
  final channel = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(1, _tools)]),
    ended,
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(2, _tools)]),
    ended,
  ]);
  final session = await _sessionWith(channel, modules);
  addTearDown(session.close);

  final feed = session.feed('import tools', onOsCall: _recording(osCalls));
  await _waitUntil(() => calls == 1);
  fail(gate);
  final outcome = await _outcome(() => feed);
  _expectNoError(outcome, 'the feed');
  _expectError(channel, 1, excType, detail);
  expect(calls, 1, reason: 'the factory ran once');

  // The failure was not cached: the factory runs again, and it succeeds.
  await _feedOk(session, 'import tools', osCalls);
  _expectImportedModule(channel, 2, _tools, _versionOne);
  expect(calls, 2, reason: 'the failed factory runs again');
}

/// A direct entry is not cached: the mapping is read live, so a replaced
/// entry is seen by the next request, and a removed one is not found.
Future<void> _directEntriesAreNotCached() async {
  final modules = <String, Object?>{};
  modules[_tools] = ExternalModule({'VERSION': _versionOne});
  modules[_nullTools] = null;
  final osCalls = <String>[];
  final done = completeNone();
  final ended = expecting(pb.ParentRequest_Kind.resumeCall, [done]);
  final channel = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(1, _tools)]),
    ended,
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(2, _tools)]),
    ended,
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(3, _tools)]),
    ended,
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(4, _absent)]),
    ended,
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(5, _nullTools)]),
    ended,
  ]);
  final session = await _sessionWith(channel, modules);
  addTearDown(session.close);

  // The direct entry answers the import.
  await _feedOk(session, 'import tools', osCalls);
  _expectImportedModule(channel, 1, _tools, _versionOne);

  // A replaced entry is seen by the next import: a direct entry is not
  // cached.
  modules[_tools] = ExternalModule({'VERSION': _versionTwo});
  await _feedOk(session, 'import tools', osCalls);
  _expectImportedModule(channel, 2, _tools, _versionTwo);

  // A removed entry is not found.
  modules.remove(_tools);
  await _feedOk(session, 'import tools', osCalls);
  _expectNotFound(channel, 3, 'import');

  // A name the mapping does not hold is not found, and a name it holds
  // with no value is refused: the two are not the same.
  await _feedOk(session, 'import absent', osCalls);
  _expectNotFound(channel, 4, 'import');
  await _feedOk(session, 'import null_tools', osCalls);
  _expectError(channel, 5, 'TypeError', 'must be an ExternalModule');
}

/// A reset clears the factory results: the mapping stays, and the factory
/// runs again.
Future<void> _factorySurvivesReset() async {
  final modules = <String, Object?>{};
  var calls = 0;
  modules[_tools] = () {
    calls++;

    return ExternalModule({'VERSION': _versionOne});
  };
  final osCalls = <String>[];
  final done = completeNone();
  final ended = expecting(pb.ParentRequest_Kind.resumeCall, [done]);
  final accepted = [ok()];
  final configured = expecting(pb.ParentRequest_Kind.configure, accepted);
  final reset = expecting(pb.ParentRequest_Kind.reset, accepted);
  final channel = ScriptedChannel([
    configured,
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(1, _tools)]),
    ended,
    reset,
    configured,
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(2, _tools)]),
    ended,
  ]);
  final session = await _sessionWith(channel, modules);
  addTearDown(session.close);

  await _feedOk(session, 'import tools', osCalls);
  _expectImportedModule(channel, 1, _tools, _versionOne);
  expect(calls, 1, reason: 'the factory ran once');

  await session.reset();
  expect(
    modules.containsKey(_tools),
    isTrue,
    reason: 'the reset keeps the mapping',
  );

  await _feedOk(session, 'import tools', osCalls);
  _expectImportedModule(channel, 2, _tools, _versionOne);
  expect(calls, 2, reason: 'the factory runs again after the reset');
}

/// A dump carries no module: the session that loads it keeps its own
/// mapping, and resolves its modules lazily.
Future<void> _factorySurvivesLoad() async {
  final sourceModules = <String, Object?>{};
  var sourceCalls = 0;
  sourceModules[_tools] = () {
    sourceCalls++;

    return ExternalModule({'VERSION': _versionOne});
  };
  final accepted = [ok()];
  final configured = expecting(pb.ParentRequest_Kind.configure, accepted);
  final loaded = expecting(pb.ParentRequest_Kind.load, accepted);
  final sourceChannel = ScriptedChannel([
    configured,
    expecting(
      pb.ParentRequest_Kind.dump,
      [
        pb.ChildEvent(dumpResult: pb.DumpResult(state: [1, 2, 3])),
      ],
    ),
  ]);
  final source = await _sessionWith(sourceChannel, sourceModules);
  addTearDown(source.close);
  final dump = await source.dump();
  expect(sourceCalls, 0, reason: 'a dump runs no factory');

  final destinationModules = <String, Object?>{};
  var destinationCalls = 0;
  destinationModules[_tools] = () {
    destinationCalls++;

    return ExternalModule({'VERSION': _versionTwo});
  };
  final osCalls = <String>[];
  final done = completeNone();
  final ended = expecting(pb.ParentRequest_Kind.resumeCall, [done]);
  final destinationChannel = ScriptedChannel([
    configured,
    loaded,
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(1, _tools)]),
    ended,
  ]);
  final destination = await _sessionWith(
    destinationChannel,
    destinationModules,
  );
  addTearDown(destination.close);

  await destination.load(dump);
  expect(destinationCalls, 0, reason: 'a load runs no factory');

  // The destination resolves its own module, lazily.
  await _feedOk(destination, 'import tools', osCalls);
  _expectImportedModule(destinationChannel, 1, _tools, _versionTwo);
  expect(
    destinationCalls,
    1,
    reason: 'the destination runs its own factory',
  );
  expect(sourceCalls, 0, reason: "the source's factory did not run");
}

/// A factory's result is installed before the module's attributes are
/// converted: a module the sandbox cannot hold is installed all the same.
Future<void> _factoryInstalledBeforeConversion() async {
  final modules = <String, Object?>{};
  var calls = 0;
  final add = MontyHostFunction('add', (args, kwargs) => const MontyInt(3));
  modules[_tools] = () {
    calls++;

    return ExternalModule({'bad': Object(), 'add': add});
  };
  final osCalls = <String>[];
  final done = completeNone();
  final ended = expecting(pb.ParentRequest_Kind.resumeCall, [done]);
  final channel = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(1, _tools)]),
    ended,
    expecting(pb.ParentRequest_Kind.feed, [_importEvent(2, _tools)]),
    ended,
    expecting(
      pb.ParentRequest_Kind.feed,
      [_functionCall('tools.add', const [], callId: 3)],
    ),
    ended,
  ]);
  final session = await _sessionWith(channel, modules);
  addTearDown(session.close);

  // The import fails: the attribute cannot be converted.
  await _feedOk(session, 'import tools', osCalls);
  _expectError(channel, 1, 'TypeError', 'Cannot convert');
  expect(calls, 1, reason: 'the factory ran once');

  // The module was installed before the conversion failed: the factory
  // does not run again, although the mapping changed under it.
  modules[_tools] = ExternalModule({'VERSION': _versionTwo});
  await _feedOk(session, 'import tools', osCalls);
  _expectError(channel, 2, 'TypeError', 'Cannot convert');
  expect(calls, 1, reason: 'the installed module answers the import');

  // The callable attribute of the installed module still works.
  await _feedOk(session, 'tools.add()', osCalls);
  _expectValue(channel, 3, BigInt.from(3));
  expect(calls, 1, reason: 'the installed module answers the call');
}

/// An automatic resume sees the same factory result as an ordinary feed.
Future<void> _factorySurvivesAutomaticResume() async {
  final modules = <String, Object?>{};
  var calls = 0;
  modules[_tools] = () {
    calls++;

    return ExternalModule({'VERSION': _versionOne});
  };
  final osCalls = <String>[];
  final done = completeNone();
  final ended = expecting(pb.ParentRequest_Kind.resumeCall, [done]);
  final built = await _outcome(() async => _configWith(modules));
  expect(built.error, isNull, reason: 'the session configuration is built');
  final config = switch (built.value) {
    final SessionConfig made => made,
    _ => fail('the session configuration is built'),
  };
  final (session, channel) = await poolB2Session(
    [
      expecting(pb.ParentRequest_Kind.feed, [_importEvent(1, _tools)]),
      ended,
      expecting(pb.ParentRequest_Kind.feed, [_importEvent(2, _tools)]),
      ended,
    ],
    config: config,
  );

  // The first feed suspends on the import; the resume answers it. The
  // second resume sees the same cached module, although the mapping
  // changed under it.
  final recording = _recording(osCalls);
  final snapshots = <FunctionSnapshot>[];
  for (var step = 0; step < 2; step++) {
    if (step == 1) {
      modules[_tools] = ExternalModule({'VERSION': _versionTwo});
    }
    final snapshot = await _suspendedOnImport(session, recording);
    final resumed = await _outcome(snapshot.resumeAuto);
    _expectNoError(resumed, 'the feed');
    snapshots.add(snapshot);
  }
  final first = itemAt(snapshots, 0);
  final second = itemAt(snapshots, 1);
  _expectImportedModule(channel, first.callId, _tools, _versionOne);
  expect(calls, 1, reason: 'the factory runs for the resumed import');
  _expectImportedModule(channel, second.callId, _tools, _versionOne);
  expect(calls, 1, reason: 'the cached module answers the second resume');
}

/// Waits until [condition] holds, without a timing sleep: the loop yields
/// to the event loop and looks again.
Future<void> _waitUntil(bool Function() condition) async {
  for (var turn = 0; turn < 100; turn++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('the condition never held');
}

/// The answers the channel recorded: the replies the driver sent.
int _answers(ScriptedChannel channel) =>
    channel.requests.where((request) => request.hasResumeCall()).length;

/// The answer to the call [callId] is the integer [value].
void _expectValue(ScriptedChannel channel, int callId, BigInt value) {
  final answer = _answerFor(channel, callId);
  expect(
    answer.result.hasReturnValue(),
    isTrue,
    reason: 'the call $callId returns a value',
  );
  final node = itemAt(answer.values.nodes, answer.result.returnValue);
  expect(node.hasInt_5(), isTrue, reason: 'the value $callId is an integer');
  expect(intOfNode(node), value, reason: 'the call $callId');
}

/// Feeds [code] on [session], which must succeed, and fails the test when
/// it does not: the failure is the outcome, not a thrown exception.
Future<void> _feedOk(
  ProtoSession session,
  String code,
  List<String> osCalls,
) async {
  final outcome = await _outcome(
    () => session.feed(code, onOsCall: _recording(osCalls)),
  );
  _expectNoError(outcome, 'the feed');
}

/// The snapshot the feed suspended on: it must be the import.
Future<FunctionSnapshot> _suspendedOnImport(
  MontySession session,
  OsHandler os,
) async {
  final outcome = await _outcome(
    () => session.feedStart('import tools', os: os),
  );
  _expectNoError(outcome, 'the feed');
  expect(
    outcome.value,
    isA<FunctionSnapshot>(),
    reason: 'the import suspends the feed',
  );

  return switch (outcome.value) {
    final FunctionSnapshot found => found,
    _ => fail('the import suspends the feed'),
  };
}

/// An OS handler that records every call's name in [calls] and answers
/// `None`.
OsHandler _recording(List<String> calls) => (name, _, _) {
  calls.add(name);

  return const MontyNone();
};

/// The outcome of an operation: the value it returned, or the error it
/// threw.
///
/// Only the operation's own failure is caught, so the assertions that read
/// the outcome fail on their own.
Future<_Outcome> _outcome(Future<Object?> Function() operation) async {
  try {
    return (value: await operation(), error: null);
  } on Object catch (error) {
    return (value: null, error: error);
  }
}

/// The outcome of an operation that must not have failed: the error, when
/// there is one, is what the test reports.
void _expectNoError(_Outcome outcome, String what) {
  expect(
    outcome.error,
    isNull,
    reason: '$what must not fail: ${outcome.error}',
  );
}

/// What an operation under test returned, or the error it threw.
typedef _Outcome = ({Object? value, Object? error});

/// The reply the channel recorded for the call [callId].
pb.ResumeCall _answerFor(ScriptedChannel channel, int callId) {
  final answers = [
    for (final request in channel.requests)
      if (request.hasResumeCall() && request.resumeCall.callId == callId)
        request.resumeCall,
  ];
  expect(answers, hasLength(1), reason: 'one reply for the call $callId');

  return onlyItem(answers);
}

/// The answer to the call [callId] finds no module: the name [name] is the
/// one upstream reports.
void _expectNotFound(ScriptedChannel channel, int callId, String name) {
  final answer = _answerFor(channel, callId);
  expect(
    answer.result.whichKind(),
    pb.ExtFunctionResult_Kind.notFound,
    reason: 'the call $callId finds no module',
  );
  expect(answer.result.notFound, name, reason: 'the call $callId');
}

/// The answer to the call [callId] is the module [name], whose `VERSION`
/// attribute is [version].
void _expectImportedModule(
  ScriptedChannel channel,
  int callId,
  String name,
  int version,
) {
  final answer = _answerFor(channel, callId);
  expect(
    answer.result.whichKind(),
    pb.ExtFunctionResult_Kind.returnValue,
    reason: 'the call $callId returns the module',
  );
  final nodes = answer.values.nodes;
  final root = answer.result.returnValue;
  final inArena = inInclusiveRange(0, nodes.length - 1);
  expect(root, inArena, reason: 'the module is in the arena');
  final module = _moduleIn(nodes, root);
  expect(module.name, name, reason: 'the call $callId');
  final versions = [
    for (final (key, value) in module.attrs)
      if (_nodeString(nodes, key) == 'VERSION') value,
  ];
  expect(versions, hasLength(1), reason: 'the module has one VERSION');
  final index = onlyItem(versions);
  expect(index, inArena, reason: 'the version is in the arena');
  final value = itemAt(nodes, index);
  expect(value.hasInt_5(), isTrue, reason: 'VERSION is an integer');
  // The version is compared as a whole number, so the comparison is exact
  // on every platform, dart2js included.
  expect(
    intOfNode(value),
    BigInt.from(version),
    reason: 'the module is the one the session holds',
  );
}

/// The answer to the call [callId] fails with the exception [excType], whose
/// message mentions [detail].
void _expectError(
  ScriptedChannel channel,
  int callId,
  String excType,
  String detail,
) {
  final answer = _answerFor(channel, callId);
  expect(
    answer.result.whichKind(),
    pb.ExtFunctionResult_Kind.error,
    reason: 'the call $callId fails',
  );
  final error = answer.result.error;
  expect(error.excType, excType, reason: 'the call $callId');
  expect(error.message, contains(detail), reason: 'the call $callId');
}

/// The module the node at [index] carries: its name and its attributes, as
/// the indexes of their nodes in the same arena.
_Module _moduleIn(List<pb.MontyNode> nodes, int index) {
  final body = _wireBytes(itemAt(nodes, index).writeToBuffer(), 32);
  expect(body, isNotEmpty, reason: 'the node carries a module');
  final name = _wireBytes(body, 1);
  expect(name, isNotEmpty, reason: 'the module has a name');
  final attrs = _wireBytes(body, 3);
  expect(attrs, isNotEmpty, reason: 'the module has attributes');
  final pairs = <(int, int)>[];
  for (final pair in _wireBytesAll(attrs, 1)) {
    pairs.add((_wireVarint(pair, 1), _wireVarint(pair, 2)));
  }

  return _Module(utf8.decode(name), pairs);
}

/// The module a reply carries: its name and its attributes, as the indexes
/// of their nodes in the reply's arena.
final class _Module {
  const _Module(this.name, this.attrs);

  /// The module's dotted name.
  final String name;

  /// The module's attributes, as the (key, value) node indexes.
  final List<(int, int)> attrs;
}

/// The string the node at [index] carries, or null when it carries none.
String? _nodeString(List<pb.MontyNode> nodes, int index) {
  if (index < 0 || index >= nodes.length) return null;
  final node = itemAt(nodes, index);

  return node.hasStr() ? node.str : null;
}

/// The `ChildEvent` of the OS call [id] whose body is [arm].
pb.ChildEvent _osCall(int id, List<int> arm) => pb.ChildEvent.fromBuffer(
  _bytesField(3, [..._varintField(1, id), ...arm]),
);

/// The `ChildEvent` of an `import` of the module [module]: the `import` arm
/// is field 31 of an `OsCall`, as a v1.2.0 worker sends it.
pb.ChildEvent _importEvent(int id, String module) =>
    _osCall(id, _bytesField(31, _stringField(1, module)));

/// The `ChildEvent` of a `Path.scan` of [path]: the `scan` arm is field 33
/// of an `OsCall`.
pb.ChildEvent _scanEvent(int id, String path) =>
    _osCall(id, _bytesField(33, _stringField(1, path)));

/// The tag of the field [number], with the wire type [wire].
List<int> _tag(int number, int wire) => _varint((number << 3) | wire);

/// A varint, as the wire carries it.
List<int> _varint(int value) {
  final out = <int>[];
  var rest = value;
  do {
    var byte = rest & 0x7f;
    rest >>= 7;
    if (rest != 0) byte |= 0x80;
    out.add(byte);
  } while (rest != 0);

  return out;
}

/// A varint field [number] holding [value].
List<int> _varintField(int number, int value) => [
  ..._tag(number, 0),
  ..._varint(value),
];

/// A length-delimited field [number] holding [bytes].
List<int> _bytesField(int number, List<int> bytes) => [
  ..._tag(number, 2),
  ..._varint(bytes.length),
  ...bytes,
];

/// A length-delimited field [number] holding the UTF-8 of [text].
List<int> _stringField(int number, String text) =>
    _bytesField(number, utf8.encode(text));

/// One field of a protobuf message: its number, its wire type and its
/// value: the bytes of a length-delimited field, the number of a varint
/// one.
typedef _Field = ({int number, int wireType, List<int> bytes, int value});

/// The fields of the protobuf message [bytes], in the order they appear.
List<_Field> _wireFields(List<int> bytes) {
  final fields = <_Field>[];
  var offset = 0;
  while (offset < bytes.length) {
    final tag = _wireVarintAt(bytes, offset);
    offset += tag.length;
    final number = tag.value >> 3;
    final wireType = tag.value & 7;
    if (wireType == 0) {
      final value = _wireVarintAt(bytes, offset);
      offset += value.length;
      fields.add((
        number: number,
        wireType: wireType,
        bytes: const [],
        value: value.value,
      ));
    } else if (wireType == 2) {
      final length = _wireVarintAt(bytes, offset);
      offset += length.length;
      final value = bytes.sublist(offset, offset + length.value);
      offset += length.value;
      fields.add((
        number: number,
        wireType: wireType,
        bytes: value,
        value: 0,
      ));
    } else {
      throw StateError('unsupported wire type $wireType');
    }
  }

  return fields;
}

/// The varint at [offset] in [bytes]: its value and the bytes it took.
({int value, int length}) _wireVarintAt(List<int> bytes, int offset) {
  var value = 0;
  var shift = 0;
  var read = 0;
  while (offset + read < bytes.length) {
    final byte = itemAt(bytes, offset + read);
    value |= (byte & 0x7f) << shift;
    read++;
    if (byte < 0x80) return (value: value, length: read);
    shift += 7;
  }

  throw StateError('a truncated varint');
}

/// The bytes of the length-delimited field [number] in the message [bytes],
/// or an empty list when the message does not carry it.
List<int> _wireBytes(List<int> bytes, int number) {
  for (final field in _wireFields(bytes)) {
    if (field.number == number && field.wireType == 2) return field.bytes;
  }

  return const [];
}

/// The bytes of every length-delimited field [number] in the message
/// [bytes], in the order they appear.
List<List<int>> _wireBytesAll(List<int> bytes, int number) => [
  for (final field in _wireFields(bytes))
    if (field.number == number && field.wireType == 2) field.bytes,
];

/// The number of the varint field [number] in the message [bytes], or zero
/// when the message does not carry it: a proto3 default is left out of the
/// wire.
int _wireVarint(List<int> bytes, int number) {
  for (final field in _wireFields(bytes)) {
    if (field.number == number && field.wireType == 0) return field.value;
  }

  return 0;
}
