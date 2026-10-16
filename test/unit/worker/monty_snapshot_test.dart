// Step-by-step driving of a pool session (lib/src/worker/monty_session.dart,
// monty_snapshot.dart, host_answers.dart, sleep_budget.dart) over scripted
// workers: feedStart and the four snapshot kinds, validate-then-consume,
// incremental future settlement, resumeAuto, OS calls as values, coroutines
// and asyncio.sleep through the futures protocol, the suspension and sleep
// budgets, and an oversized manual resume. No worker runs. Pure Dart: vm,
// dart2js and dart2wasm.
import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart'
    hide MontyComplete, MontyError, MontySyntaxError, MontyTypingError;
import 'package:dart_monty_core/src/worker/arena_writer.dart';
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/host_objects.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_scripted_channel.dart';
import '_worker_class_oracle.g.dart';

/// A pool over the scripted [channel], none started up front.
Future<Monty> _pool(ScriptedChannel channel) {
  final next = Queue.of([channel]);

  return startMonty(
    const PoolOptions(minProcesses: 0, maxProcesses: 1),
    open: () => PendingSpawn((_) async => next.removeFirst()),
  );
}

/// A session over a worker that accepts `Configure`, then answers [script].
Future<(MontySession, ScriptedChannel)> _session(
  List<Reply> script, {
  SessionConfig config = const SessionConfig(scriptName: 'job.py'),
}) async {
  final ch = ScriptedChannel([
    expecting(pb.ParentRequest_Kind.configure, [ok()]),
    ...script,
  ]);
  final pool = await _pool(ch);
  addTearDown(pool.close);
  final session = await pool.checkoutWith(config);
  addTearDown(session.close);

  return (session, ch);
}

/// A dict keyed by a list, which upstream refuses to send.
const MontyValue _unhashableKey = MontyDict([
  (MontyList([MontyInt(1)]), MontyInt(1)),
]);

/// A reply that accepts `Reset`.
final Reply _resetOk = expecting(pb.ParentRequest_Kind.reset, [ok()]);

pb.SourceRange _at(int start, int end) =>
    pb.SourceRange(filename: '<python-input-0>', start: start, end: end);

/// A call to [name] with the int arguments [args] and `k=` [kw].
pb.ChildEvent _call(
  String name,
  int id, {
  List<int> args = const [],
  int? kw,
  bool eager = false,
  pb.SourceRange? position,
}) {
  final writer = ArenaWriter();
  final call = pb.FunctionCall(
    functionName: name,
    callId: id,
    allowEagerAwait: eager,
    args: [for (final a in args) writer.add(MontyInt(a))],
    position: position,
  );
  if (kw != null) {
    call.kwargs.add(
      pb.NodePair(
        key: writer.add(const MontyString('k')),
        value: writer.add(MontyInt(kw)),
      ),
    );
  }

  return pb.ChildEvent(functionCall: call..values = writer.arena);
}

pb.ChildEvent _os(pb.OsCall call) => pb.ChildEvent(osCall: call);

pb.ChildEvent _futures(List<int> ids) => pb.ChildEvent(
  resolveFutures: pb.ResolveFutures(
    pendingCallIds: ids,
    position: _at(10, 20),
  ),
);

pb.ChildEvent _int(int n) => complete([intNode(n)]);

pb.ParentRequest _last(ScriptedChannel ch) =>
    itemAt(ch.requests, ch.requests.length - 1);

/// The int each `ResumeFutures` result of [request] settles to, by call id.
Map<int, Object> _settled(pb.ParentRequest request) {
  final futures = request.resumeFutures;

  return {
    for (final r in futures.results)
      r.callId: r.result.hasError()
          ? r.result.error.excType
          : intOfNode(
              itemAt(futures.values.nodes, r.result.returnValue),
            ).toInt(),
  };
}

final Matcher _spent = isA<StateError>().having(
  (e) => e.message,
  'message',
  'snapshot has already been resumed',
);

final Matcher _pending = isA<StateError>().having(
  (e) => e.message,
  'message',
  'feed called while a suspension is awaiting an answer',
);

final Matcher _finished = isA<StateError>().having(
  (e) => e.message,
  'message',
  contains('finished'),
);

Matcher _raised(String excType, [Object? message]) => isA<MontyRuntimeError>()
    .having((e) => e.exception.excType, 'excType', excType)
    .having((e) => e.exception.message, 'message', message ?? anything);

final class _ThrowingLookup extends MapBase<String, MontyValue> {
  const _ThrowingLookup();

  @override
  MontyValue? operator [](Object? key) =>
      throw const FormatException('lookup failed');

  @override
  void operator []=(String key, MontyValue value) => throw UnimplementedError();

  @override
  Iterable<String> get keys => const ['f'];

  @override
  void clear() => throw UnimplementedError();

  @override
  MontyValue? remove(Object? key) => throw UnimplementedError();
}

void main() {
  group('feedStart', () {
    test('a host call is a FunctionSnapshot; resume completes', () async {
      final (s, ch) = await _session([
        expecting(pb.ParentRequest_Kind.feed, [
          _call('f', 7, args: [2], kw: 3, position: _at(4, 13)),
        ]),
        expecting(pb.ParentRequest_Kind.resumeCall, [_int(5)]),
      ]);
      final snap = await s.feedStart('y = f(2, k=3)\ny');
      expect(snap, isA<FunctionSnapshot>());
      final call = snap as FunctionSnapshot;
      expect(call.functionName, 'f');
      expect(call.callId, 7);
      expect(call.args, [const MontyInt(2)]);
      expect(call.kwargs, {'k': const MontyInt(3)});
      expect(call.isOsFunction, isFalse);
      expect(call.allowEagerAwait, isFalse);
      expect(call.objectId, isNull);
      expect(
        call.position,
        SourceRange(filename: '<python-input-0>', start: 4, end: 13),
      );
      expect(call.scriptName, 'job.py');
      final done = await call.resume(const ExternalReturnValue(MontyInt(5)));
      expect(done, isA<MontyComplete>());
      expect((done as MontyComplete).output, const MontyInt(5));
      final resume = _last(ch).resumeCall;
      expect(resume.callId, 7);
      expect(intOfNode(itemAt(resume.values.nodes, 0)).toInt(), 5);
    });

    test('a missing position reads as the unknown range', () async {
      final (s, _) = await _session([
        answer([_call('f', 1)]),
      ]);
      final snap = await s.feedStart('f()') as FunctionSnapshot;
      expect(snap.position, SourceRange.unknown);
    });

    test('a name lookup resumes with a value or as undefined', () async {
      final (s, ch) = await _session([
        answer([
          pb.ChildEvent(
            nameLookup: pb.NameLookup(name: 'missing', position: _at(8, 15)),
          ),
        ]),
        answer([
          pb.ChildEvent(nameLookup: pb.NameLookup(name: 'other')),
        ]),
        answer([raised('NameError', "name 'other' is not defined")]),
      ]);
      final first = await s.feedStart('t = 1 + missing') as NameLookupSnapshot;
      expect(first.variableName, 'missing');
      expect(
        first.position,
        SourceRange(filename: '<python-input-0>', start: 8, end: 15),
      );
      final second =
          await first.resume(value: const MontyInt(41)) as NameLookupSnapshot;
      final lookup = itemAt(ch.requests, 2).resumeNameLookup;
      expect(intOfNode(itemAt(lookup.values.nodes, lookup.value)).toInt(), 41);
      await expectLater(second.resume(), throwsA(_raised('NameError')));
      expect(_last(ch).resumeNameLookup.hasUndefined(), isTrue);
    });

    test("an OS call is a FunctionSnapshot with upstream's name and "
        'arguments', () async {
      final (s, ch) = await _session([
        answer([
          _os(
            pb.OsCall(
              callId: 4,
              mkdir: pb.OsCall_Mkdir(path: 'd/./e/../f', parents: true),
              position: _at(0, 5),
            ),
          ),
        ]),
        answer([raised('PermissionError', "Permission denied: '/d/f'")]),
      ]);
      final snap = await s.feedStart('mk') as FunctionSnapshot;
      expect(snap.isOsFunction, isTrue);
      expect(snap.functionName, 'Path.mkdir');
      expect(snap.args, [MontyPath('/d/f')]);
      expect(snap.kwargs, {
        'parents': const MontyBool(true),
        'exist_ok': const MontyBool(false),
      });
      await expectLater(
        snap.resumeNotHandled(),
        throwsA(_raised('PermissionError')),
      );
      expect(_last(ch).resumeCall.result.hasNotHandled(), isTrue);
    });

    test(
      'a system sleep is surfaced, not waited (upstream feed_start)',
      () async {
        final (s, _) = await _session([
          answer([
            _os(
              pb.OsCall(
                callId: 1,
                asyncSystemSleep: pb.OsCall_AsyncSleep(delay: 0.5),
                allowEagerAwait: true,
              ),
            ),
          ]),
        ]);
        final snap = await s.feedStart('sleep') as FunctionSnapshot;
        expect(snap.functionName, 'system.async_sleep');
        expect(snap.args, [const MontyFloat(0.5)]);
        expect(snap.allowEagerAwait, isTrue);
      },
    );

    test(
      "a worker's eager bit on a call no future may answer is dropped",
      () async {
        final (s, _) = await _session([
          answer([
            _os(pb.OsCall(callId: 1, readText: '/x', allowEagerAwait: true)),
          ]),
        ]);
        final snap = await s.feedStart('read') as FunctionSnapshot;
        expect(snap.allowEagerAwait, isFalse);
      },
    );

    test('completion is MontyComplete', () async {
      final (s, _) = await _session([
        answer([_int(2)]),
      ]);
      final done = await s.feedStart('1 + 1');
      expect((done as MontyComplete).output, const MontyInt(2));
    });

    test('a feed while a snapshot awaits an answer is refused; after it, '
        'feeds run', () async {
      final (s, _) = await _session([
        answer([_call('f', 1)]),
        answer([_int(5)]),
        answer([_int(3)]),
      ]);
      final snap = await s.feedStart('f()') as FunctionSnapshot;
      final refused = throwsA(_pending);
      await expectLater(s.feedRun('1'), refused);
      await expectLater(s.feedStart('1'), refused);
      await snap.resume(const ExternalReturnValue(MontyInt(5)));
      expect(await s.feedRun('3'), const MontyInt(3));
    });

    test('a close with a snapshot held Resets; the snapshot then fails as '
        'finished', () async {
      final (s, ch) = await _session([
        answer([_call('f', 1)]),
        _resetOk,
      ]);
      final snap = await s.feedStart('f()') as FunctionSnapshot;
      await s.close();
      expect(_last(ch).whichKind(), pb.ParentRequest_Kind.reset);
      await expectLater(
        snap.resume(const ExternalReturnValue(MontyNone())),
        throwsA(_finished),
      );
    });
  });

  test('a close during a feedRun sleep ends its timer and fails the feed '
      'as finished', () async {
    final (s, _) = await _session([
      answer([
        _os(pb.OsCall(callId: 1, systemSleep: pb.OsCall_Sleep(seconds: 9))),
      ]),
      _resetOk,
    ]);
    final sleeps = <Timer>[];
    final run = runZoned(
      () => s.feedRun('time.sleep(9)'),
      zoneSpecification: ZoneSpecification(
        createTimer: (self, parent, zone, duration, f) {
          final timer = parent.createTimer(zone, duration, f);
          if (duration == const Duration(seconds: 9)) sleeps.add(timer);

          return timer;
        },
      ),
    );
    await pumpEventQueue();
    final sleep = onlyItem(sleeps);
    expect(sleep.isActive, isTrue);
    final failed = expectLater(run, throwsA(_finished));
    await s.close();
    expect(sleep.isActive, isFalse);
    await failed;
  });

  group('feedStart, failure paths', () {
    test('prints reach the callback during a step', () async {
      final seen = <String>[];
      final (s, _) = await _session([
        answer([
          printed([(pb.PrintStream.PRINT_STREAM_STDOUT, 'hi\n')]),
          _call('f', 1),
        ]),
      ]);
      await s.feedStart(
        'print("hi")\nf()',
        printCallback: (_, t) => seen.add(t),
      );
      expect(seen, ['hi\n']);
    });

    test('a worker that dies during a resume ends the session', () async {
      final (s, _) = await _session([
        answer([_call('f', 1)]),
        crash(CrashCause.vanished),
      ]);
      final snap = await s.feedStart('f()') as FunctionSnapshot;
      await expectLater(
        snap.resume(const ExternalReturnValue(MontyNone())),
        throwsA(isA<MontyCrashedError>()),
      );
      await expectLater(s.feedRun('1'), throwsA(_finished));
    });

    test('a lazy attribute lookup carries its receiver', () async {
      final (s, _) = await _session([
        answer([
          pb.ChildEvent(
            nameLookup: pb.NameLookup(
              name: 'attr',
              objectId: pb.Uuid(data: List.generate(16, (i) => i)),
            ),
          ),
        ]),
      ]);
      final snap = await s.feedStart('o.attr') as NameLookupSnapshot;
      expect(snap.objectId, '00010203-0405-0607-0809-0a0b0c0d0e0f');
    });

    test('an OS call no arm describes is a protocol violation', () async {
      final (s, ch) = await _session([
        answer([_os(pb.OsCall(callId: 1))]),
      ]);
      await expectLater(
        s.feedStart('bad'),
        throwsA(
          isA<MontyCrashedError>().having(
            (e) => e.toString(),
            'message',
            'monty worker protocol error: invalid OS call payload: missing '
                'required field OsCall.call',
          ),
        ),
      );
      expect(ch.kills, 1);
    });

    test(
      'a queued feedStart whose inputs are refused hands the turn on',
      () async {
        final gate = Completer<void>();
        final (s, _) = await _session([
          answer([
            printed([(pb.PrintStream.PRINT_STREAM_STDOUT, 'held\n')]),
            _int(1),
          ]),
          answer([_int(3)]),
        ]);
        // The first feed holds the turn until the gate opens.
        final first = s.feedRun('1', printCallback: (_, _) => gate.future);
        await pumpUntil(() => true);
        final refused = s.feedStart('x', inputs: {'x': _unhashableKey});
        final third = s.feedRun('3');
        gate.complete();
        expect(await first, const MontyInt(1));
        await expectLater(refused, throwsArgumentError);
        expect(
          await third.timeout(const Duration(seconds: 5)),
          const MontyInt(3),
        );
      },
    );

    test(
      'a close while resumeAuto waits on host code fails it at once',
      () async {
        final (s, _) = await _session([
          answer([_call('f', 1)]),
          _resetOk,
        ]);
        final never = Completer<MontyValue>();
        final snap =
            await s.feedStart(
                  'f()',
                  externalLookup: {
                    'f': MontyHostFunction('f', (args, kwargs) => never.future),
                  },
                )
                as FunctionSnapshot;
        final resumed = expectLater(snap.resumeAuto(), throwsA(_finished));
        await pumpEventQueue();
        await s.close();
        await resumed;
        expect(never.isCompleted, isFalse);
      },
    );

    test('host code that closes the session at once, then never answers: '
        'resumeAuto fails as finished', () async {
      final (s, _) = await _session([
        answer([_call('f', 1)]),
        _resetOk,
      ]);
      final never = Completer<MontyValue>();
      late final MontySession session;
      final snap =
          await s.feedStart(
                'f()',
                externalLookup: {
                  'f': MontyHostFunction('f', (args, kwargs) {
                    unawaited(session.close());

                    return never.future;
                  }),
                },
              )
              as FunctionSnapshot;
      session = s;
      await expectLater(snap.resumeAuto(), throwsA(_finished));
    });

    test('a close while resumeAuto waits on a pending coroutine fails it at '
        'once', () async {
      final (s, _) = await _session([
        answer([_call('af', 1)]),
        answer([
          _futures([1]),
        ]),
        _resetOk,
      ]);
      final never = Completer<MontyValue>();
      final call =
          await s.feedStart(
                'await af()',
                externalLookup: {
                  'af': MontyHostFunction(
                    'af',
                    coroutine((args, kwargs) => never.future),
                  ),
                },
              )
              as FunctionSnapshot;
      final futures = await call.resumeAuto() as FutureSnapshot;
      final resumed = expectLater(futures.resumeAuto(), throwsA(_finished));
      await pumpEventQueue();
      await s.close();
      await resumed;
      expect(never.isCompleted, isFalse);
    });

    test('resumeAuto after a close runs no host code', () async {
      final (s, _) = await _session([
        answer([
          _os(
            pb.OsCall(
              callId: 1,
              writeText: pb.OsCall_TextWrite(path: '/a', data: 'x'),
            ),
          ),
        ]),
        _resetOk,
      ]);
      var wrote = 0;
      final snap =
          await s.feedStart(
                'write',
                os: (name, args, kwargs) {
                  wrote++;

                  return const MontyNone();
                },
              )
              as FunctionSnapshot;
      await s.close();
      await expectLater(snap.resumeAuto(), throwsA(_finished));
      expect(wrote, 0);
    });

    test('SourceRange is a value', () {
      final a = SourceRange(filename: '<string>', start: 1, end: 2);
      expect(a, SourceRange(filename: '<string>', start: 1, end: 2));
      expect(
        a.hashCode,
        SourceRange(filename: '<string>', start: 1, end: 2).hashCode,
      );
      expect(a, isNot(SourceRange(filename: '<string>', start: 1, end: 3)));
      // Upstream's repr (exceptions.rs:613-620): the name as it is, quoted.
      expect('$a', "SourceRange(filename='<string>', start=1, end=2)");
    });
  });

  group('validate, then consume', () {
    test('an unknown exception type is refused and leaves the snapshot '
        'resumable', () async {
      final (s, ch) = await _session([
        answer([_call('f', 1)]),
        answer([raised('ValueError', 'bad')]),
      ]);
      final snap = await s.feedStart('f()') as FunctionSnapshot;
      final sent = ch.requests.length;
      expect(
        () => snap.resume(const ExternalException('NotAnError', 'x')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            "Unknown exception type: 'NotAnError'",
          ),
        ),
      );
      expect(ch.requests, hasLength(sent));
      await expectLater(
        snap.resume(const ExternalException('ValueError', 'bad')),
        throwsA(_raised('ValueError', 'bad')),
      );
      final error = _last(ch).resumeCall.result.error;
      expect((error.excType, error.message), ('ValueError', 'bad'));
    });

    test('a value the writer refuses leaves the snapshot resumable', () async {
      final (s, ch) = await _session([
        answer([_call('f', 1)]),
        answer([_int(1)]),
      ]);
      final snap = await s.feedStart('f()') as FunctionSnapshot;
      expect(
        () => snap.resume(const ExternalReturnValue(_unhashableKey)),
        throwsArgumentError,
      );
      final sent = ch.requests.length;
      expect(sent, 2, reason: 'nothing was sent for the refused answer');
      await snap.resume(const ExternalReturnValue(MontyInt(1)));
    });

    test('resumeNotHandled on a host call is refused, unspent', () async {
      final (s, _) = await _session([
        answer([_call('f', 1)]),
        answer([_int(1)]),
      ]);
      final snap = await s.feedStart('f()') as FunctionSnapshot;
      expect(snap.resumeNotHandled, throwsStateError);
      expect(snap.isSpent, isFalse);
      await snap.resume(const ExternalReturnValue(MontyInt(1)));
    });

    test('a second resume is refused', () async {
      final (s, _) = await _session([
        answer([_call('f', 1)]),
        answer([_int(1)]),
      ]);
      final snap = await s.feedStart('f()') as FunctionSnapshot;
      await snap.resume(const ExternalReturnValue(MontyInt(1)));
      final spent = throwsA(_spent);
      expect(
        () => snap.resume(const ExternalReturnValue(MontyInt(1))),
        spent,
      );
      expect(snap.resumeAuto, spent);
    });

    test('a future settled with a refused value leaves the snapshot '
        'resumable', () async {
      final (s, _) = await _session([
        answer([_call('f', 1)]),
        answer([
          _futures([1]),
        ]),
        answer([_int(9)]),
      ]);
      final call = await s.feedStart('await f()') as FunctionSnapshot;
      final futures =
          await call.resume(const ExternalFuture()) as FutureSnapshot;
      expect(
        () => futures.resume({1: const ExternalReturnValue(_unhashableKey)}),
        throwsArgumentError,
      );
      expect(
        () => futures.resume({1: const ExternalException('Nope')}),
        throwsArgumentError,
      );
      expect(futures.isSpent, isFalse);
      await futures.resume({1: const ExternalReturnValue(MontyInt(9))});
    });

    test('an oversized manual resume fails, spent; the call stays pending, '
        'so a feed is refused', () async {
      final (s, ch) = await _session([
        answer([_call('f', 1)]),
        (_) => throw const FrameTooLargeException(268435487, 268435456),
      ]);
      final snap = await s.feedStart('f()') as FunctionSnapshot;
      await expectLater(
        snap.resume(const ExternalReturnValue(MontyNone())),
        throwsA(
          _raised(
            'RuntimeError',
            'request frame of 268435487 bytes exceeds the maximum of '
                '268435456 bytes',
          ),
        ),
      );
      expect(
        () => snap.resume(const ExternalReturnValue(MontyInt(1))),
        throwsA(_spent),
      );
      await expectLater(s.feedRun('3'), throwsA(_pending));
      expect(ch.kills, 0);
    });
  });

  group('futures', () {
    test('settled incrementally: what is left is reported again', () async {
      final (s, ch) = await _session([
        answer([_call('f', 1)]),
        answer([_call('f', 2)]),
        answer([
          _futures([1, 2]),
        ]),
        answer([
          _futures([2]),
        ]),
        answer([_int(30)]),
      ]);
      final a = await s.feedStart('gather') as FunctionSnapshot;
      final b = await a.resume(const ExternalFuture()) as FunctionSnapshot;
      expect(itemAt(ch.requests, 2).resumeCall.result.future, 1);
      final both = await b.resume(const ExternalFuture()) as FutureSnapshot;
      expect(both.pendingCallIds, [1, 2]);
      expect(
        both.position,
        SourceRange(filename: '<python-input-0>', start: 10, end: 20),
      );
      final rest =
          await both.resume({1: const ExternalReturnValue(MontyInt(10))})
              as FutureSnapshot;
      expect(_settled(itemAt(ch.requests, 4)), {1: 10});
      expect(rest.pendingCallIds, [2]);
      final done = await rest.resume({
        2: const ExternalException('ValueError', 'no'),
      });
      expect(_settled(itemAt(ch.requests, 5)), {2: 'ValueError'});
      expect((done as MontyComplete).output, const MontyInt(30));
    });

    test(
      'resumeAuto settles the coroutines it started, as each finishes',
      () async {
        final slow = Completer<MontyValue>();
        final fast = Completer<MontyValue>();
        final (s, ch) = await _session([
          answer([
            _call('af', 1, args: [1]),
          ]),
          answer([
            _call('af', 2, args: [2]),
          ]),
          answer([
            _futures([1, 2]),
          ]),
          answer([
            _futures([1]),
          ]),
          answer([_int(3)]),
        ]);
        final coroutines = {
          'af': MontyHostFunction(
            'af',
            coroutine(
              (args, kwargs) => firstItem(args) == const MontyInt(1)
                  ? slow.future
                  : fast.future,
            ),
          ),
        };
        final a =
            await s.feedStart('gather', externalLookup: coroutines)
                as FunctionSnapshot;
        final b = await a.resumeAuto() as FunctionSnapshot;
        expect(itemAt(ch.requests, 2).resumeCall.result.future, 1);
        final both = await b.resumeAuto() as FutureSnapshot;
        expect(itemAt(ch.requests, 3).resumeCall.result.future, 2);
        fast.complete(const MontyInt(20));
        final left = await both.resumeAuto() as FutureSnapshot;
        expect(_settled(itemAt(ch.requests, 4)), {2: 20});
        slow.complete(const MontyInt(10));
        await left.resumeAuto();
        expect(_settled(itemAt(ch.requests, 5)), {1: 10});
      },
    );

    test(
      'an eagerly awaited coroutine is answered with ResumeFutures',
      () async {
        final (s, ch) = await _session([
          answer([_call('af', 5, eager: true)]),
          answer([_int(7)]),
        ]);
        final snap =
            await s.feedStart(
                  'await af()',
                  externalLookup: {
                    'af': MontyHostFunction(
                      'af',
                      coroutine(
                        (args, kwargs) => Future.value(const MontyInt(7)),
                      ),
                    ),
                  },
                )
                as FunctionSnapshot;
        await snap.resumeAuto();
        expect(_settled(_last(ch)), {5: 7});
      },
    );

    test('resumeAuto with nothing pending ends the session', () async {
      final (s, ch) = await _session([
        answer([
          _futures([1]),
        ]),
      ]);
      final futures = await s.feedStart('await x') as FutureSnapshot;
      await expectLater(futures.resumeAuto(), throwsStateError);
      expect(ch.kills, 1);
      await expectLater(s.feedRun('1'), throwsA(_finished));
    });
  });

  group('resumeAuto', () {
    test(
      'a throwing external lookup becomes a Python exception and leaves '
      'the session usable',
      () async {
        final (s, ch) = await _session([
          answer([_call('f', 1)]),
          answer([_int(1)]),
          answer([_int(2)]),
        ]);
        final call =
            await s.feedStart(
                  'try:\n'
                  '    f()\n'
                  'except Exception:\n'
                  '    1',
                  externalLookup: const _ThrowingLookup(),
                )
                as FunctionSnapshot;

        final done = await call.resumeAuto();
        expect((done as MontyComplete).output, const MontyInt(1));
        final error = _last(ch).resumeCall.result.error;
        expect(
          (error.excType, error.message),
          ('Exception', 'FormatException: lookup failed'),
        );
        expect(await s.feedRun('2'), const MontyInt(2));
      },
    );

    test('a host function answers with its value; an unknown name is '
        'not found', () async {
      final (s, ch) = await _session([
        answer([
          _call('f', 1, args: [4]),
        ]),
        answer([_call('g', 2)]),
        answer([raised('NameError', "name 'g' is not defined")]),
      ]);
      final first =
          await s.feedStart(
                'f(4) + g()',
                externalLookup: {
                  'f': MontyHostFunction(
                    'f',
                    (args, kwargs) => Future.value(
                      MontyInt((firstItem(args) as MontyInt).value * 10),
                    ),
                  ),
                },
              )
              as FunctionSnapshot;
      final second = await first.resumeAuto() as FunctionSnapshot;
      final resume = itemAt(ch.requests, 2).resumeCall;
      expect(intOfNode(itemAt(resume.values.nodes, 0)).toInt(), 40);
      await expectLater(second.resumeAuto(), throwsA(_raised('NameError')));
      expect(_last(ch).resumeCall.result.notFound, 'g');
    });

    test('a lookup of a host function resolves to it', () async {
      final (s, ch) = await _session([
        answer([pb.ChildEvent(nameLookup: pb.NameLookup(name: 'f'))]),
        answer([_int(1)]),
      ]);
      final snap =
          await s.feedStart(
                'f',
                externalLookup: {
                  'f': MontyHostFunction('f', (a, k) => const MontyNone()),
                },
              )
              as NameLookupSnapshot;
      await snap.resumeAuto();
      final lookup = _last(ch).resumeNameLookup;
      expect(itemAt(lookup.values.nodes, lookup.value).function.name, 'f');
    });

    test('an OS call goes to the handler, a system sleep too', () async {
      final seen = <String>[];
      final (s, ch) = await _session([
        answer([_os(pb.OsCall(callId: 1, readText: '/a/../b'))]),
        answer([
          _os(
            pb.OsCall(callId: 2, systemSleep: pb.OsCall_Sleep(seconds: 9)),
          ),
        ]),
        answer([raised('RuntimeError')]),
      ]);
      final read =
          await s.feedStart(
                'read',
                os: (name, args, kwargs) {
                  seen.add('$name ${firstItem(args)}');

                  return name == 'Path.read_text'
                      ? const MontyString('text')
                      : throw const OsCallNotHandledException();
                },
              )
              as FunctionSnapshot;
      final sleep = await read.resumeAuto() as FunctionSnapshot;
      await expectLater(sleep.resumeAuto(), throwsA(_raised('RuntimeError')));
      expect(seen, [
        "Path.read_text ${MontyPath('/b')}",
        'system.sleep ${const MontyFloat(9)}',
      ]);
      expect(_last(ch).resumeCall.result.hasNotHandled(), isTrue);
    });
  });

  group('feedRun', () {
    test(
      'coroutines in a gather settle through the futures protocol',
      () async {
        final (s, ch) = await _session([
          answer([
            _call('af', 1, args: [1]),
          ]),
          answer([
            _call('af', 2, args: [2]),
          ]),
          answer([
            _futures([1, 2]),
          ]),
          answer([
            _futures([1]),
          ]),
          answer([_int(30)]),
        ]);
        final slow = Completer<MontyValue>();
        final run = s.feedRun(
          'await asyncio.gather(af(1), af(2))',
          externalLookup: {
            'af': MontyHostFunction(
              'af',
              coroutine(
                (args, kwargs) => firstItem(args) == const MontyInt(1)
                    ? slow.future
                    : Future.value(const MontyInt(20)),
              ),
            ),
          },
        );
        // The second settles first and is delivered alone; the first follows.
        await pumpUntil(() => ch.requests.length == 5);
        expect(_settled(itemAt(ch.requests, 4)), {2: 20});
        slow.complete(const MontyInt(10));
        expect(await run, const MontyInt(30));
        expect(_settled(_last(ch)), {1: 10});
      },
    );

    test('asyncio.sleep is a future the session settles once waited', () async {
      final (s, ch) = await _session([
        answer([
          _os(
            pb.OsCall(
              callId: 3,
              asyncSystemSleep: pb.OsCall_AsyncSleep(delay: 0.01),
            ),
          ),
        ]),
        answer([
          _futures([3]),
        ]),
        answer([
          _os(
            pb.OsCall(
              callId: 4,
              asyncSystemSleep: pb.OsCall_AsyncSleep(delay: 0.01),
              allowEagerAwait: true,
            ),
          ),
        ]),
        answer([_int(1)]),
      ]);
      expect(await s.feedRun('sleeps'), const MontyInt(1));
      expect(itemAt(ch.requests, 2).resumeCall.result.future, 3);
      expect(_settled(itemAt(ch.requests, 3)).keys, [3]);
      expect(_settled(_last(ch)).keys, [4]);
    });

    test('OS calls reach the handler as values; a returned future is awaited, '
        "except asyncio.sleep's", () async {
      final calls = <(String, List<MontyValue>, Map<String, MontyValue>)>[];
      final (s, ch) = await _session([
        answer([
          _os(
            pb.OsCall(
              callId: 1,
              writeText: pb.OsCall_TextWrite(path: '/a.txt', data: 'hi'),
            ),
          ),
        ]),
        answer([
          _os(pb.OsCall(callId: 2, asyncSleep: pb.OsCall_AsyncSleep(delay: 0))),
        ]),
        answer([
          _futures([2]),
        ]),
        answer([_int(2)]),
      ]);
      final value = await s.feedRun(
        'os',
        os: (name, args, kwargs) async {
          calls.add((name, args, kwargs));
          await Future<void>.delayed(Duration.zero);

          return name == 'Path.write_text'
              ? const MontyInt(2)
              : throw const OsCallNotHandledException();
        },
      );
      expect(value, const MontyInt(2));
      expect(calls.map((c) => c.$1), ['Path.write_text', 'asyncio.sleep']);
      expect(firstItem(calls).$2, [
        MontyPath('/a.txt'),
        const MontyString('hi'),
      ]);
      final write = itemAt(ch.requests, 2).resumeCall;
      expect(
        intOfNode(itemAt(write.values.nodes, write.result.returnValue)).toInt(),
        2,
      );
      expect(itemAt(ch.requests, 3).resumeCall.result.future, 2);
      expect(_settled(itemAt(ch.requests, 4)).keys, [2]);
    });
  });

  group('host answers in feedRun', () {
    test(
      'a coroutine that throws settles its future with the exception',
      () async {
        final (s, ch) = await _session([
          answer([_call('af', 1)]),
          answer([
            _futures([1]),
          ]),
          answer([_int(0)]),
        ]);
        await s.feedRun(
          'await asyncio.gather(af())',
          externalLookup: {
            'af': MontyHostFunction(
              'af',
              coroutine(
                (args, kwargs) => Future.error(
                  const ExternalException('ValueError', 'no'),
                ),
              ),
            ),
          },
        );
        expect(_settled(itemAt(ch.requests, 3)), {1: 'ValueError'});
      },
    );

    test(
      "a coroutine's value the writer refuses settles as Exception",
      () async {
        final (s, ch) = await _session([
          answer([_call('af', 1)]),
          answer([
            _futures([1]),
          ]),
          answer([_int(0)]),
        ]);
        await s.feedRun(
          'await asyncio.gather(af())',
          externalLookup: {
            'af': MontyHostFunction(
              'af',
              coroutine((args, kwargs) => Future.value(_unhashableKey)),
            ),
          },
        );
        expect(_settled(itemAt(ch.requests, 3)), {1: 'Exception'});
      },
    );

    test('asyncio.sleep answered synchronously by the handler', () async {
      final (s, ch) = await _session([
        answer([
          _os(pb.OsCall(callId: 1, asyncSleep: pb.OsCall_AsyncSleep(delay: 0))),
        ]),
        answer([
          _os(pb.OsCall(callId: 2, asyncSleep: pb.OsCall_AsyncSleep(delay: 0))),
        ]),
        answer([_int(0)]),
      ]);
      var calls = 0;
      await s.feedRun(
        'sleeps',
        os: (name, args, kwargs) => calls++ == 0
            ? const MontyNone()
            : throw const OsCallNotHandledException(),
      );
      expect(itemAt(ch.requests, 2).resumeCall.result.hasReturnValue(), isTrue);
      expect(itemAt(ch.requests, 3).resumeCall.result.hasNotHandled(), isTrue);
    });

    test('a host call whose argument arena upstream rejects is a protocol '
        'violation, the function never called', () async {
      final (s, ch) = await _session([
        answer([
          pb.ChildEvent(
            functionCall: pb.FunctionCall(
              functionName: 'f',
              callId: 1,
              args: [5],
              values: pb.Arena(nodeCount: 1, nodes: [intNode(1)]),
            ),
          ),
        ]),
      ]);
      var called = false;
      await expectLater(
        s.feedRun(
          'f(1)',
          externalLookup: {
            'f': MontyHostFunction('f', (args, kwargs) {
              called = true;

              return const MontyNone();
            }),
          },
        ),
        throwsA(
          isA<MontyCrashedError>().having(
            (e) => e.toString(),
            'message',
            'monty worker protocol error: invalid payload from worker: '
                'invalid value for Arena: value root 5 is out of range for an '
                'arena of 1 nodes',
          ),
        ),
      );
      expect(called, isFalse);
      expect(ch.kills, 1);
    });

    // One int node, as an argument arena.
    final oneInt = pb.Arena(nodeCount: 1, nodes: [intNode(1)]);

    // Upstream converts a FunctionCall's arguments when the frame arrives
    // (checkout.rs:1735-1752, `into_call_args`; a failure is
    // `convert_turn`'s protocol violation, :1926-1933): the suspension is
    // never returned, and the worker is discarded.
    for (final (name, call, detail) in [
      (
        'a positional argument',
        pb.FunctionCall(
          functionName: 'f',
          callId: 1,
          args: [5],
          values: oneInt,
        ),
        'value root 5 is out of range for an arena of 1 nodes',
      ),
      (
        'a keyword argument',
        pb.FunctionCall(
          functionName: 'f',
          callId: 1,
          kwargs: [pb.NodePair(key: 0, value: 7)],
          values: oneInt,
        ),
        'value root 7 is out of range for an arena of 1 nodes',
      ),
    ]) {
      test('a suspension whose $name root upstream rejects is a protocol '
          'violation: no snapshot, the worker killed', () async {
        final (s, ch) = await _session([
          answer([pb.ChildEvent(functionCall: call)]),
        ]);
        await expectLater(
          s.feedStart('f()'),
          throwsA(
            isA<MontyCrashedError>().having(
              (e) => e.toString(),
              'message',
              'monty worker protocol error: invalid payload from worker: '
                  'invalid value for Arena: $detail',
            ),
          ),
        );
        expect(ch.kills, 1);
      });
    }

    test('an OS call no arm describes is a protocol violation, as '
        "upstream's conversion on arrival makes it", () async {
      final (s, ch) = await _session([
        answer([_os(pb.OsCall(callId: 1))]),
      ]);
      await expectLater(
        s.feedRun('bad', os: (name, args, kwargs) => const MontyNone()),
        throwsA(
          isA<MontyCrashedError>().having(
            (e) => e.toString(),
            'message',
            'monty worker protocol error: invalid OS call payload: missing '
                'required field OsCall.call',
          ),
        ),
      );
      expect(ch.kills, 1);
    });
  });

  group('budgets', () {
    pb.ChildEvent sleep(int id, double seconds) => _os(
      pb.OsCall(
        callId: id,
        systemSleep: pb.OsCall_Sleep(seconds: seconds),
      ),
    );

    test('each system sleep is charged before it is waited; past the '
        'budget the feed is aborted with the total', () async {
      final (s, ch) = await _session(
        [
          answer([sleep(1, 0.2)]),
          answer([_int(1)]),
          answer([sleep(2, 0.1)]),
          expecting(pb.ParentRequest_Kind.abortFeed, [
            raised('TimeoutError', 'sleep limit exceeded: 300ms > 250ms'),
          ]),
          answer([
            _os(
              pb.OsCall(
                callId: 3,
                asyncSystemSleep: pb.OsCall_AsyncSleep(delay: 0.04),
                allowEagerAwait: true,
              ),
            ),
          ]),
          answer([_int(4)]),
        ],
        config: const SessionConfig(
          limits: ResourceLimits(maxTotalSleep: Duration(milliseconds: 250)),
        ),
      );
      expect(await s.feedRun('a'), const MontyInt(1));
      await expectLater(
        s.feedRun('b'),
        throwsA(_raised('TimeoutError', 'sleep limit exceeded: 300ms > 250ms')),
      );
      final abort = itemAt(ch.requests, 4).abortFeed.exception;
      expect(abort.excType, 'TimeoutError');
      expect(abort.message, 'sleep limit exceeded: 300ms > 250ms');
      // The refused 100 ms was not charged: 240 ms fits.
      expect(await s.feedRun('c'), const MontyInt(4));
      expect(
        itemAt(ch.requests, 0).configure.limits.maxTotalSleepMicros,
        Int64(250000),
      );
    });

    test('a sleep is charged capped at the system-sleep maximum', () async {
      final (s, _) = await _session(
        [
          answer([sleep(1, 1000000000)]),
          answer([_int(1)]),
        ],
        config: const SessionConfig(
          limits: ResourceLimits(maxTotalSleep: Duration(seconds: 1)),
          osPolicy: OsPolicy(sleepSystemMax: Duration(milliseconds: 1)),
        ),
      );
      expect(await s.feedRun('a'), const MontyInt(1));
    });

    test('a worker can only tighten the sleep budget', () async {
      final (s, _) = await _session(
        [
          answer([
            sleep(1, 0.002)..maxTotalSleepMicros = Int64(1000),
          ]),
          expecting(pb.ParentRequest_Kind.abortFeed, [
            raised('TimeoutError', 'sleep limit exceeded: 2ms > 1ms'),
          ]),
        ],
        config: const SessionConfig(
          limits: ResourceLimits(maxTotalSleep: Duration(seconds: 5)),
        ),
      );
      await expectLater(s.feedRun('a'), throwsA(_raised('TimeoutError')));
    });

    test('a worker can only tighten the suspension budget', () async {
      final (s, _) = await _session(
        [
          answer([_call('f', 1)..maxSuspensions = Int64()]),
          expecting(pb.ParentRequest_Kind.abortFeed, [
            raised('RuntimeError', 'suspension limit 0 exceeded'),
          ]),
        ],
        config: const SessionConfig(limits: ResourceLimits(maxSuspensions: 5)),
      );
      await expectLater(
        s.feedRun('f()'),
        throwsA(_raised('RuntimeError', 'suspension limit 0 exceeded')),
      );
    });

    test('the suspension budget counts snapshot turns too', () async {
      final (s, ch) = await _session(
        [
          answer([_call('f', 1)]),
          answer([_call('f', 2)]),
          answer([_call('f', 3)]),
          expecting(pb.ParentRequest_Kind.abortFeed, [
            raised('RuntimeError', 'suspension limit 2 exceeded'),
          ]),
        ],
        config: const SessionConfig(limits: ResourceLimits(maxSuspensions: 2)),
      );
      final a = await s.feedStart('f()+f()+f()') as FunctionSnapshot;
      final b =
          await a.resume(const ExternalReturnValue(MontyInt(1)))
              as FunctionSnapshot;
      await expectLater(
        b.resume(const ExternalReturnValue(MontyInt(1))),
        throwsA(_raised('RuntimeError', 'suspension limit 2 exceeded')),
      );
      expect(_last(ch).whichKind(), pb.ParentRequest_Kind.abortFeed);
    });
  });

  // Upstream's members, measured on pydantic-monty 1.1.0 by
  // tool/generate_worker_class_oracle.py (_worker_class_oracle.g.dart).
  group("upstream's members", () {
    test("ExternalReturnValue equality is its value's", () {
      // Upstream's is a TypedDict, so a dict, compared by value
      // (pydantic_monty/__init__.py:235-238).
      // Each built anew, so equal ones are distinct objects.
      final [one, alsoOne, two] = [
        for (final n in [1, 1, 2]) _ret(n),
      ];
      expect(identical(one, alsoOne), isFalse);
      expect(_py(one == alsoOne), workerClassOracle['return_value_equal']);
      expect(_py(one == two), workerClassOracle['return_value_unequal']);
      expect(one.hashCode, alsoOne.hashCode);
      expect(one, isNot(const ExternalFuture()));
      final [list, sameList] = [
        for (final n in [1, 1]) ExternalReturnValue(MontyList([MontyInt(n)])),
      ];
      expect(list, sameList);
      expect(list.hashCode, sameList.hashCode);
    });

    test(
      'kwargs is the same mutable map on every read; args a fixed list',
      () async {
        final (s, _) = await _session([
          answer([_callKw()]),
        ]);
        final snap = await s.feedStart('f(1, a=2, b=3)') as FunctionSnapshot;
        expect(
          _py(_sameEachRead(() => snap.kwargs)),
          workerClassOracle['kwargs_same_object'],
        );
        expect('value: ${_repr(snap.kwargs)}', workerClassOracle['kwargs']);
        // Each change is made through one read and seen through the next.
        for (final (id, change)
            in <(String, void Function(Map<String, MontyValue>))>[
              ('kwargs_after_set', (k) => k['c'] = const MontyInt(4)),
              ('kwargs_after_del', (k) => k.remove('a')),
            ]) {
          expect(
            'value: ${_repr(_changed(snap, change))}',
            workerClassOracle[id],
            reason: id,
          );
        }
        expect(
          _py(_sameEachRead(() => snap.args)),
          workerClassOracle['args_same_object'],
        );
        // A tuple: upstream's `TypeError` on item assignment.
        expect(workerClassOracle['args_set'], startsWith('TypeError: '));
        expect(() => snap.args[0] = const MontyInt(9), throwsUnsupportedError);
      },
    );

    test(
      'a changed kwargs does not change what resumeAuto calls with',
      () async {
        // Upstream dispatches from the call it received, not from the dict
        // `kwargs` returned (snapshot.rs:917-923).
        final (s, _) = await _session([
          answer([_callKw()]),
          answer([_int(0)]),
        ]);
        Map<String, MontyValue>? seen;
        final snap =
            await s.feedStart(
                  'f(1, a=2, b=3)',
                  externalLookup: {
                    'f': MontyHostFunction('f', (
                      args,
                      kwargs,
                    ) {
                      seen = Map.of(kwargs);

                      return const MontyNone();
                    }),
                  },
                )
                as FunctionSnapshot;
        snap.kwargs
          ..clear()
          ..['z'] = const MontyInt(0);
        await snap.resumeAuto();
        expect(seen, {'a': const MontyInt(2), 'b': const MontyInt(3)});
      },
    );

    test("SourceRange's offsets are u32s", () {
      // Upstream's constructor takes u32s (exceptions.rs:597-602): Python's
      // OverflowError, Dart's ArgumentError (D-036).
      for (final (id, start, end) in [
        ('range_start_negative', -1, 0),
        ('range_end_negative', 0, -1),
        ('range_start_too_large', 0x100000000, 0),
        ('range_end_too_large', 0, 0x100000000),
      ]) {
        expect(
          workerClassOracle[id],
          startsWith('OverflowError: '),
          reason: id,
        );
        expect(
          () => SourceRange(filename: 'f', start: _n(start), end: _n(end)),
          throwsArgumentError,
          reason: id,
        );
      }
      // The bounds, and a reversed range, are accepted.
      final u32Max = _n(0xFFFFFFFF);
      final max = SourceRange(filename: 'f', start: u32Max, end: u32Max);
      expect('value: $max', workerClassOracle['range_u32_max']);
      final reversed = SourceRange(filename: 'f', start: _n(5), end: _n(1));
      expect('value: $reversed', workerClassOracle['range_reversed']);
    });

    // Upstream converts MontyComplete.output on each access, and compares
    // completions by identity (snapshot.rs:1360-1379).
    test('MontyComplete: output decoded on each access; identity ==', () async {
      final (s, _) = await _session([
        for (var i = 0; i < 2; i++) answer([_list12()]),
      ]);
      final [done, again] = [
        for (var i = 0; i < 2; i++)
          await s.feedStart('[1, 2]') as MontyComplete,
      ];
      expect(
        _py(_sameEachRead(() => done.output)),
        workerClassOracle['complete_output_same_object'],
      );
      final [first, second] = [for (var i = 0; i < 2; i++) done.output];
      expect(
        _py(first == second),
        workerClassOracle['complete_output_equal'],
      );
      expect(_py(done == done), workerClassOracle['complete_equal_self']);
      expect(_py(done == again), workerClassOracle['complete_equal_other']);
      expect(
        'value: MontyComplete(output=${_listRepr(first)})',
        workerClassOracle['complete_repr'],
      );
      // The value's own text is Dart's toString, not a Python repr.
      expect('$done', 'MontyComplete(output=$first)');
    });

    // A registered host object is the wrapped object on every read, as
    // upstream's store resolves it (decode.rs:146-148), the session's close
    // notwithstanding.
    test('MontyComplete: a host object resolves on every read, after close '
        'too', () async {
      final box = ClassInstance(
        Object(),
        classType: ClassType(const HostClass('Box')),
      );
      final writer = ArenaWriter(objects: HostObjects());
      final root = writer.add(box);
      final (s, _) = await _session([
        answer([_call('f', 1)]),
        answer([
          pb.ChildEvent(
            complete: pb.Complete(values: writer.arena, value: root),
          ),
        ]),
        _resetOk,
      ]);
      final call = await s.feedStart('f()') as FunctionSnapshot;
      final done = await call.resume(ExternalReturnValue(box)) as MontyComplete;
      Object? hostOf(MontyValue v) => switch (v) {
        ClassInstance(:final value) => value,
        _ => null,
      };
      final wrapped = box.value;
      final before = hostOf(done.output);
      await s.close();
      final after = hostOf(done.output);
      for (final read in [before, after]) {
        expect(read, same(wrapped));
      }
    });

    // Upstream's pool decodes every suspension's position through
    // SourceRange::new, which cuts the file name to 256 UTF-8 bytes on a
    // character boundary (checkout.rs:1736-1821, exceptions.rs:777-792).
    test('a decoded position keeps at most 256 bytes of its file name, on '
        'every suspension kind', () async {
      // 1 + 2 * 200 bytes; 'x' and 127 'é' is 255, the next 'é' would pass.
      final long = 'x${'é' * 200}';
      final cut = 'x${'é' * 127}';
      final [atCall, atOs, atLookup, atFutures] = [
        for (var i = 0; i < 4; i++)
          pb.SourceRange(filename: long, start: 1, end: 2),
      ];
      final (s, _) = await _session([
        answer([_call('f', 1, position: atCall)]),
        answer([
          _os(pb.OsCall(callId: 2, readText: '/x', position: atOs)),
        ]),
        answer([
          pb.ChildEvent(
            nameLookup: pb.NameLookup(name: 'n', position: atLookup),
          ),
        ]),
        answer([
          pb.ChildEvent(
            resolveFutures: pb.ResolveFutures(
              pendingCallIds: [1],
              position: atFutures,
            ),
          ),
        ]),
      ]);
      final call = await s.feedStart('f(1)') as FunctionSnapshot;
      final os = await call.resume(const ExternalFuture()) as FunctionSnapshot;
      final lookup =
          await os.resume(const ExternalReturnValue(MontyNone()))
              as NameLookupSnapshot;
      final futures =
          await lookup.resume(value: const MontyInt(1)) as FutureSnapshot;
      for (final (kind, position) in [
        ('function call', call.position),
        ('os call', os.position),
        ('name lookup', lookup.position),
        ('futures', futures.position),
      ]) {
        expect(
          position,
          SourceRange(filename: cut, start: 1, end: 2),
          reason: kind,
        );
        expect(utf8.encode(position.filename), hasLength(255), reason: kind);
      }
    });

    test('a hand-built SourceRange keeps its file name whole', () {
      final range = SourceRange(filename: 'é' * 200, start: 0, end: 0);
      expect(
        'value: ${utf8.encode(range.filename).length}',
        workerClassOracle['range_long_filename_bytes'],
      );
    });
  });
}

/// [n], as a value the compiler cannot make constant.
int _n(int n) => int.parse('$n');

/// A return of [n], built anew each time.
ExternalReturnValue _ret(int n) => ExternalReturnValue(MontyInt(_n(n)));

/// [snap]'s kwargs read again after [change] was made through a first read.
Map<String, MontyValue> _changed(
  FunctionSnapshot snap,
  void Function(Map<String, MontyValue>) change,
) {
  final [first, again] = [
    for (var i = 0; i < 2; i++) snap.kwargs,
  ];
  change(first);

  return again;
}

/// A completion with the value `[1, 2]`.
pb.ChildEvent _list12() {
  final writer = ArenaWriter();
  final root = writer.add(const MontyList([MontyInt(1), MontyInt(2)]));

  return pb.ChildEvent(
    complete: pb.Complete(values: writer.arena, value: root),
  );
}

/// [b] as Python shows a bool, as an outcome.
String _py(bool b) => 'value: ${b ? 'True' : 'False'}';

/// Whether two reads of [read] give the identical object.
bool _sameEachRead(Object Function() read) {
  final [a, b] = [for (var i = 0; i < 2; i++) read()];

  return identical(a, b);
}

/// The suspension of `f(1, a=2, b=3)`.
pb.ChildEvent _callKw() {
  final writer = ArenaWriter();
  final call = pb.FunctionCall(
    functionName: 'f',
    callId: 1,
    args: [writer.add(const MontyInt(1))],
  );
  for (final (k, v) in [('a', 2), ('b', 3)]) {
    call.kwargs.add(
      pb.NodePair(
        key: writer.add(MontyString(k)),
        value: writer.add(MontyInt(v)),
      ),
    );
  }

  return pb.ChildEvent(functionCall: call..values = writer.arena);
}

/// [value], a list of ints, as Python's `repr` of it.
String _listRepr(MontyValue value) {
  final items = (value as MontyList).items;

  return '[${[for (final item in items) (item as MontyInt).value].join(', ')}]';
}

/// [kwargs] of ints as Python's `repr` of the dict.
String _repr(Map<String, MontyValue> kwargs) {
  final items = [
    for (final MapEntry(:key, :value) in kwargs.entries)
      "'$key': ${(value as MontyInt).value}",
  ];

  return '{${items.join(', ')}}';
}

/// Lets the event loop run until [done] holds.
Future<void> pumpUntil(bool Function() done) async {
  for (var i = 0; i < 1000 && !done(); i++) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(done(), isTrue, reason: 'the condition never held');
}
