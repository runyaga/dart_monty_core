// MontyPool and its sessions (lib/src/worker/monty_pool.dart,
// pool_session.dart) over scripted workers: checkout and Configure, feedRun,
// print delivery in order, idle close and Reset, close during host code,
// requestTimeout and the duration backstops on turns only, the memory-limit
// exit, and the scoped helpers; and the failure paths: a failing or stalled
// print callback, close while busy, and oversized requests. No worker runs.
// Pure Dart: vm, dart2js and dart2wasm.
import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart'
    hide MontyError, MontySyntaxError, MontyTypingError;
import 'package:dart_monty_core/src/platform/exception_attributes.dart';
import 'package:dart_monty_core/src/worker/collect_streams.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/monty_snapshot.dart';
import 'package:dart_monty_core/src/worker/os_policy.dart';
import 'package:dart_monty_core/src/worker/pool_session.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/wire_scalars.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_scripted_channel.dart';

const pb.PrintStream _stdout = pb.PrintStream.PRINT_STREAM_STDOUT;
const pb.PrintStream _stderr = pb.PrintStream.PRINT_STREAM_STDERR;

/// Workers for a pool: each start takes the next channel.
final class Workers {
  Workers(Iterable<ScriptedChannel> channels) : _next = Queue.of(channels);

  /// Every channel handed out, in order.
  final List<ScriptedChannel> started = [];

  final Queue<ScriptedChannel> _next;

  SpawnHandle open() => PendingSpawn((_) async {
    final channel = _next.removeFirst();
    started.add(channel);

    return channel;
  });
}

/// A pool over [workers], none started up front.
Future<MontyPool> _pool(
  Workers workers, {
  int maxProcesses = 1,
  Duration? requestTimeout,
  Duration? feedGrace = PoolOptions.defaultDurationLimitGrace,
  Duration? turnGrace = PoolOptions.defaultDurationLimitGrace,
}) => MontyPool.startWith(
  PoolOptions(
    minProcesses: 0,
    maxProcesses: maxProcesses,
    requestTimeout: requestTimeout,
    feedDurationLimitGrace: feedGrace,
    turnDurationLimitGrace: turnGrace,
  ),
  open: workers.open,
);

/// A reply that accepts `Configure`.
final Reply _configureOk = expecting(pb.ParentRequest_Kind.configure, [ok()]);

/// A reply that accepts `Reset`.
final Reply _resetOk = expecting(pb.ParentRequest_Kind.reset, [ok()]);

/// The kind of the last request [ch] received.
pb.ParentRequest_Kind _lastKind(ScriptedChannel ch) {
  final requests = ch.requests;

  return itemAt(requests, requests.length - 1).whichKind();
}

/// `Complete` of the int [n].
pb.ChildEvent _int(int n) => complete([intNode(n)]);

/// A `FunctionCall` to [name] with no arguments, reporting [feedMicros] of
/// feed execution so far.
pb.ChildEvent _call(String name, {int feedMicros = 0}) => pb.ChildEvent(
  functionCall: pb.FunctionCall(functionName: name, callId: 1),
  feedExecutionMicros: Int64(feedMicros),
);

/// A `NameLookup` of [name].
pb.ChildEvent _lookup(String name) =>
    pb.ChildEvent(nameLookup: pb.NameLookup(name: name));

/// A session's print callback that records what it sees.
(List<(String, String)>, ProtoPrintCallback) _recorder() {
  final seen = <(String, String)>[];

  return (seen, (stream, text) => seen.add((stream, text)));
}

Duration _ms(int n) => Duration(milliseconds: n);

/// What a test passes as `printCallback` when it does not look at prints.
void _ignore(String stream, String text) => _ignored++;

/// How many prints [_ignore] dropped; never looked at.
var _ignored = 0;

/// A throw whose text changes.
final class _Changing implements Exception {
  _Changing(this.text);

  String text;

  @override
  String toString() => text;
}

/// A throw whose text cannot be rendered.
final class _BadText implements Exception {
  const _BadText();

  @override
  String toString() => throw StateError('no text');
}

/// The error a print callback's throw is raised as: [MontyRuntimeError]
/// with the Python exception [excType] and [message], as upstream's
/// `exc_py_to_monty` classifies a host exception, and no traceback.
Matcher _printFailure(String excType, String message) =>
    isA<MontyRuntimeError>()
        .having((e) => e.exception.excType, 'excType', excType)
        .having((e) => e.exception.message, 'exception message', message)
        .having((e) => e.traceback, 'traceback', isEmpty);

/// A worker killed at a deadline of [limit] (Rust's Duration format), as
/// upstream reports a request timeout.
Matcher _timedOut(String limit) => isA<MontyCrashedError>()
    .having((e) => e.cause, 'cause', CrashCause.killed)
    .having((e) => e.timedOut, 'timedOut', isTrue)
    .having((e) => e.exitStatus, 'exitStatus', isNull)
    .having(
      (e) => e.message,
      'message',
      'monty worker killed after exceeding request timeout of $limit',
    )
    .having((e) => e.exception.excType, 'exception', 'RuntimeError');

/// A worker discarded for answering against the protocol.
Matcher _violation(String detail) => isA<MontyCrashedError>()
    .having((e) => e.cause, 'cause', CrashCause.protocol)
    .having((e) => e.timedOut, 'timedOut', isFalse)
    .having((e) => e.exitStatus, 'exitStatus', isNull)
    .having(
      (e) => e.message,
      'message',
      'monty worker protocol error: $detail',
    );

Matcher _crashed(CrashCause cause, [Object? message]) =>
    isA<MontyCrashedError>()
        .having((e) => e.cause, 'cause', cause)
        .having((e) => e.message, 'message', message ?? anything);

final Matcher _finished = isA<StateError>().having(
  (e) => e.message,
  'message',
  contains('finished'),
);

/// Expects a feed on [session] to be refused: a suspension is pending.
Future<void> _refusedAsPending(PoolSession session) => expectLater(
  session.feedRun('1', printCallback: _ignore),
  throwsA(_pending),
);

/// A feed refused while a suspension waits for its answer.
final Matcher _pending = isA<StateError>().having(
  (e) => e.message,
  'message',
  'feed called while a suspension is awaiting an answer',
);

void main() {
  group('checkout', () {
    test('sends Configure with the name, limits and knobs', () async {
      final ch = ScriptedChannel([_configureOk]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      await pool.checkout(
        options: const SessionConfig(
          scriptName: 'case.py',
          limits: ResourceLimits(
            maxMemory: 1 << 24,
            maxRecursionDepth: 50,
            maxFeedDuration: Duration(milliseconds: 1500),
            maxTurnDuration: Duration(milliseconds: 250),
          ),
          assertMessageAnnotations: 0,
          printFlushInterval: Duration(milliseconds: 5),
        ),
      );
      final configure = onlyItem(ch.requests).configure;
      expect(configure.scriptName, 'case.py');
      expect(configure.limits.maxMemoryBytes, Int64(1 << 24));
      expect(configure.limits.maxRecursionDepth, Int64(50));
      expect(configure.limits.maxFeedDurationMicros, Int64(1500000));
      expect(configure.limits.maxTurnDurationMicros, Int64(250000));
      expect(configure.assertMessageAnnotations, 0);
      expect(configure.printFlushIntervalMs, 5);
    });

    test('defaults leave every knob to the worker', () async {
      final ch = ScriptedChannel([_configureOk]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      await pool.checkout();
      final configure = onlyItem(ch.requests).configure;
      expect(configure.scriptName, 'main.py');
      expect(configure.hasLimits(), isFalse);
      expect(configure.hasAssertMessageAnnotations(), isFalse);
      expect(configure.hasPrintFlushIntervalMs(), isFalse);
    });

    test('any other Configure failure frees the slot too', () async {
      // A worker with nothing scripted: the turn fails with a StateError.
      final pool = await _pool(Workers([ScriptedChannel([])]));
      addTearDown(pool.close);
      await expectLater(pool.checkout(), throwsA(isA<StateError>()));
      expect(pool.liveWorkers, 0);
    });

    test('a refused Configure frees the slot and throws', () async {
      final ch = ScriptedChannel([
        answer([fatal('protocol_version 5 outside 6..=6')]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      await expectLater(pool.checkout(), throwsA(_crashed(CrashCause.fatal)));
      expect(pool.liveWorkers, 0);
    });

    test('a Configure answered out of turn kills the worker', () async {
      final ch = ScriptedChannel([
        answer([completeNone()]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      await expectLater(
        pool.checkout(),
        throwsA(_violation('unexpected reply to Configure: complete')),
      );
      expect(ch.kills, greaterThan(0));
      expect(pool.liveWorkers, 0);
    });

    test('a Configure past requestTimeout kills the worker', () async {
      final ch = ScriptedChannel([hangAfter([])]);
      final pool = await _pool(
        Workers([ch]),
        requestTimeout: const Duration(milliseconds: 20),
      );
      addTearDown(pool.close);
      await expectLater(
        pool.checkout(),
        throwsA(_timedOut('20ms')),
      );
      expect(pool.liveWorkers, 0);
    });
  });

  group('working directory', () {
    test('the first feed, stepped or run, switches to "/"; later ones keep '
        'the directory', () async {
      final done = expecting(pb.ParentRequest_Kind.feed, [completeNone()]);
      final ch = ScriptedChannel([_configureOk, done, done, _resetOk]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      await session.feedStart('1', printCallback: _ignore);
      await session.feedRun('2', printCallback: _ignore);
      await session.close();
      final feeds = [
        for (final r in ch.requests)
          if (r.whichKind() == pb.ParentRequest_Kind.feed) r.feed,
      ];
      expect([for (final f in feeds) f.hasCwd()], [true, false]);
      expect(feeds.firstOrNull?.cwd, '/');
    });
  });

  group('feedRun', () {
    test('returns the value; inputs, externals and os get through', () async {
      final ch = ScriptedChannel([
        _configureOk,
        expecting(pb.ParentRequest_Kind.feed, [_lookup('ext')]),
        expecting(pb.ParentRequest_Kind.resumeNameLookup, [_call('ext')]),
        expecting(pb.ParentRequest_Kind.resumeCall, [
          pb.ChildEvent(
            osCall: pb.OsCall(callId: 2, exists: '/x'),
          ),
        ]),
        expecting(pb.ParentRequest_Kind.resumeCall, [_int(42)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final os = <String>[];
      final value = await session.feedRun(
        'ext()',
        inputs: {'x': const MontyInt(1)},
        externals: {'ext': (args, kwargs) => const MontyInt(7)},
        os: (name, args, kwargs) {
          os.add(name);

          return const MontyBool(true);
        },
        printCallback: _ignore,
      );
      expect(value, const MontyInt(42));
      expect(os, ['Path.exists']);
      final feed = itemAt(ch.requests, 1).feed;
      expect(feed.code, 'ext()');
      expect(onlyItem(feed.inputs).name, 'x');
    });

    test('a Python exception is in-band; the session runs on', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([raised('ZeroDivisionError', 'division by zero')]),
        answer([_int(2)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      await expectLater(
        session.feedRun('1/0', printCallback: _ignore),
        throwsA(
          isA<MontyRuntimeError>().having(
            (e) => e.exception.excType,
            'excType',
            'ZeroDivisionError',
          ),
        ),
      );
      expect(
        await session.feedRun('1+1', printCallback: _ignore),
        const MontyInt(2),
      );
    });
  });

  group('concurrent feeds (serialized as upstream)', () {
    /// A first feed whose turn waits on [gate] in its print callback, so it
    /// holds the turn while later feeds are queued.
    Future<MontyValue> heldFeed(PoolSession s, Completer<void> gate) =>
        s.feedRun('print("held")\n1', printCallback: (_, _) => gate.future);

    test('a feed queued behind a turn runs after it, in order', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'held\n')]),
          _int(1),
        ]),
        answer([_int(2)]),
        answer([_int(3)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final gate = Completer<void>();
      final done = <int>[];
      Future<void> run(Future<MontyValue> feed) async {
        done.add(((await feed) as MontyInt).value);
      }

      final all = Future.wait([
        run(heldFeed(session, gate)),
        run(session.feedRun('2', printCallback: _ignore)),
        run(session.feedRun('3', printCallback: _ignore)),
      ]);
      await pumpEventQueue();
      // The later feeds wait for the turn; nothing more was sent.
      expect(ch.requests, hasLength(2));
      gate.complete();
      await all;
      expect(done, [1, 2, 3]);
      expect(
        [for (final r in ch.requests.skip(1)) r.feed.code],
        [
          'print("held")\n1',
          '2',
          '3',
        ],
      );
    });

    test('queued feeds keep their order against a new feed', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'held\n')]),
          _int(1),
        ]),
        for (var i = 2; i <= 5; i++) answer([_int(i)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final gate = Completer<void>();
      final order = <String>[];
      // The first feed's caller submits the next feed the moment its own
      // returns, three times over.
      Future<void> producer() async {
        await heldFeed(session, gate);
        order.add('first');
        for (var i = 0; i < 3; i++) {
          await session.feedRun('p$i', printCallback: _ignore);
          order.add('producer-$i');
        }
      }

      Future<void> queued() async {
        await session.feedRun('q', printCallback: _ignore);
        order.add('queued');
      }

      final all = Future.wait([producer(), queued()]);
      await pumpEventQueue();
      gate.complete();
      await all;
      expect(order, [
        'first',
        'queued',
        'producer-0',
        'producer-1',
        'producer-2',
      ]);
    });

    test(
      'print callbacks calling each other across sessions are refused',
      () async {
        final a = ScriptedChannel([
          _configureOk,
          answer([
            printed([(_stdout, 'a\n')]),
            _int(1),
          ]),
        ]);
        final b = ScriptedChannel([
          _configureOk,
          answer([
            printed([(_stdout, 'b\n')]),
            _int(2),
          ]),
        ]);
        final pool = await _pool(Workers([a, b]), maxProcesses: 2);
        addTearDown(pool.close);
        final [sa, sb] = await Future.wait(
          // Two sessions on two workers.
          [for (var i = 0; i < 2; i++) pool.checkout()],
        );
        Object? refused;
        final value = await sa
            .feedRun(
              'print("a")',
              // A's print callback runs a feed on B, whose print callback
              // calls back into A: A is inside its own turn.
              printCallback: (_, _) => sb.feedRun(
                'print("b")',
                printCallback: (_, _) async {
                  try {
                    await sa.feedRun('1', printCallback: _ignore);
                  } on Object catch (e) {
                    refused = e;
                  }
                },
              ),
            )
            .timeout(const Duration(seconds: 5));
        expect(value, const MontyInt(1));
        expect(refused, isA<StateError>());
      },
    );

    test('a feed while another is suspended on a host call fails', () async {
      final release = Completer<MontyValue>();
      final ch = ScriptedChannel([
        _configureOk,
        answer([_lookup('wait')]),
        answer([_call('wait')]),
        answer([completeNone()]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final entered = Completer<void>();
      final first = session.feedRun(
        'wait()',
        externals: {
          'wait': (args, kwargs) {
            entered.complete();

            return release.future;
          },
        },
        printCallback: _ignore,
      );
      await entered.future;
      await expectLater(
        session.feedRun('1', printCallback: _ignore),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('suspension'),
          ),
        ),
      );
      release.complete(const MontyNone());
      expect(await first, const MontyNone());
    });

    test('a queued feed fails once the running feed suspends', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'held\n')]),
          _lookup('f'),
        ]),
        answer([_call('f')]),
        answer([_int(1)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final gate = Completer<void>();
      final first = session.feedRun(
        'print("held")\nf()',
        externals: {'f': (args, kwargs) => const MontyNone()},
        printCallback: (_, _) => gate.future,
      );
      final queued = expectLater(
        session.feedRun('2', printCallback: _ignore),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            contains('suspension'),
          ),
        ),
      );
      await pumpEventQueue();
      // The first feed's turn ends in a suspension: the queued feed gets
      // the turn and refuses, as upstream's checkout does.
      gate.complete();
      await queued;
      expect(await first, const MontyInt(1));
      expect(ch.remaining, 0);
    });

    test('a queued feed fails as finished when the session closes', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'held\n')]),
          _int(1),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final gate = Completer<void>();
      final held = expectLater(
        heldFeed(session, gate),
        throwsA(_crashed(CrashCause.killed)),
      );
      final queued = expectLater(
        session.feedRun('2', printCallback: _ignore),
        throwsA(_finished),
      );
      await pumpEventQueue();
      await session.close();
      await held;
      await queued;
      expect(ch.requests, hasLength(2));
      expect(pool.liveWorkers, 0);
    });
  });

  group('print delivery', () {
    test('each callback is awaited before the next and the end', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'a'), (_stderr, 'b')]),
          printed([(_stdout, 'c')]),
          _int(1),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final log = <String>[];
      final gates = <Completer<void>>[];
      var done = false;
      Future<void> gated(String stream, String text) async {
        log.add('start $stream $text');
        final gate = Completer<void>();
        gates.add(gate);
        await gate.future;
        log.add('end $text');
      }

      Future<MontyValue> feed() async {
        final value = await session.feedRun('p()', printCallback: gated);
        done = true;

        return value;
      }

      final run = feed();
      for (var i = 0; i < 3; i++) {
        await pumpEventQueue();
        // Only the callback for the current fragment has started.
        expect(gates, hasLength(i + 1), reason: log.join('; '));
        expect(done, isFalse);
        itemAt(gates, i).complete();
      }
      expect(await run, const MontyInt(1));
      expect(log, [
        'start stdout a',
        'end a',
        'start stderr b',
        'end b',
        'start stdout c',
        'end c',
      ]);
    });

    test('prints across a host call arrive in order', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'before\n')]),
          _lookup('f'),
        ]),
        answer([_call('f')]),
        answer([
          printed([(_stdout, 'after\n')]),
          completeNone(),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final (seen, record) = _recorder();
      await session.feedRun(
        'f()',
        externals: {'f': (args, kwargs) => const MontyNone()},
        printCallback: record,
      );
      expect(seen, [('stdout', 'before\n'), ('stdout', 'after\n')]);
    });

    test('a call from inside a print callback throws StateError', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'x')]),
          completeNone(),
        ]),
        _resetOk,
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      Object? inner;
      await session.feedRun(
        'print("x")',
        printCallback: (stream, text) async {
          try {
            await session.feedRun('1', printCallback: _ignore);
          } on Object catch (e) {
            inner = e;
          }
        },
      );
      expect(inner, isA<StateError>());
      await session.close();
      expect(pool.idleWorkers, 1);
    });
  });

  group('print failure (upstream binding)', () {
    test('then completion: later prints are dropped, the failure wins, the '
        'session runs on', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'a'), (_stdout, 'b')]),
          printed([(_stdout, 'c')]),
          _int(1),
        ]),
        answer([_int(2)]),
        _resetOk,
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final seen = <String>[];
      await expectLater(
        session.feedRun(
          'print("a", "b")\nprint("c")\n1',
          printCallback: (stream, text) {
            seen.add(text);
            throw StateError('sink');
          },
        ),
        throwsA(_printFailure('Exception', 'Bad state: sink')),
      );
      expect(seen, ['a']);
      // The turn was read to its end and the worker kept.
      expect(ch.kills, 0);
      expect(
        await session.feedRun('2', printCallback: _ignore),
        const MontyInt(2),
      );
      await session.close();
      expect(pool.idleWorkers, 1);
    });

    test('then a Python exception: the failure wins', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'a')]),
          raised('KeyError', 'k'),
        ]),
        answer([_int(5)]),
        _resetOk,
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      await expectLater(
        session.feedRun(
          'print("a")\nraise KeyError("k")',
          printCallback: (stream, text) async => throw StateError('sink'),
        ),
        throwsA(_printFailure('Exception', 'Bad state: sink')),
      );
      expect(ch.kills, 0);
      expect(
        await session.feedRun('5', printCallback: _ignore),
        const MontyInt(5),
      );
      await session.close();
    });

    test('then a suspension: the session is discarded, its slot serves a new '
        'checkout', () async {
      final first = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'a')]),
          _lookup('f'),
        ]),
      ]);
      final second = ScriptedChannel([
        _configureOk,
        answer([_int(3)]),
        _resetOk,
      ]);
      final pool = await _pool(Workers([first, second]));
      addTearDown(pool.close);
      // Each checkout takes the slot anew, on purpose.
      // ignore: prefer-moving-to-variable
      final session = await pool.checkout();
      var calls = 0;
      await expectLater(
        session.feedRun(
          'print("a")\nf()',
          externals: {'f': (args, kwargs) => MontyInt(++calls)},
          printCallback: (stream, text) async => throw StateError('sink'),
        ),
        throwsA(_printFailure('Exception', 'Bad state: sink')),
      );
      // Nobody answers the suspension: the worker is killed, not left
      // waiting for a resume.
      expect(calls, 0);
      expect(first.kills, greaterThan(0));
      expect(_lastKind(first), pb.ParentRequest_Kind.feed);
      expect(pool.liveWorkers, 0);
      await expectLater(
        session.feedRun('1', printCallback: _ignore),
        throwsA(_finished),
      );
      await session.close();
      // Each checkout takes the slot anew, on purpose.
      // ignore: prefer-moving-to-variable
      final next = await pool.checkout();
      expect(
        await next.feedRun('3', printCallback: _ignore),
        const MontyInt(3),
      );
      await next.close();
    });

    test('then a crash: the failure still wins', () async {
      final ch = ScriptedChannel([
        _configureOk,
        hangAfter([
          printed([(_stdout, 'a')]),
          printed([(_stdout, 'b')]),
        ]),
      ]);
      final pool = await _pool(Workers([ch]), requestTimeout: _ms(30));
      addTearDown(pool.close);
      final session = await pool.checkout();
      var calls = 0;
      await expectLater(
        session.feedRun(
          'while True: print("x")',
          printCallback: (stream, text) {
            calls++;
            throw StateError('sink');
          },
        ),
        throwsA(_printFailure('Exception', 'Bad state: sink')),
      );
      expect(calls, 1);
      expect(pool.liveWorkers, 0);
    });
  });

  group('print failure classification', () {
    // The first print raises; the turn completes; the session runs on.
    Future<Object?> failWith(ProtoPrintCallback callback) async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'a')]),
          _int(1),
        ]),
        answer([_int(2)]),
        _resetOk,
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      Object? thrown;
      try {
        await session.feedRun('print("a")\n1', printCallback: callback);
      } on Object catch (e) {
        thrown = e;
      }
      expect(ch.kills, 0);
      expect(
        await session.feedRun('2', printCallback: _ignore),
        const MontyInt(2),
      );
      await session.close();

      return thrown;
    }

    test('an ExternalException raises its type and message', () async {
      expect(
        await failWith(
          (_, _) => throw const ExternalException('KeyError', 'k'),
        ),
        _printFailure('KeyError', 'k'),
      );
    });

    test('an ExternalException of a type upstream does not know raises '
        'Exception with the refusal', () async {
      expect(
        await failWith((_, _) => throw const ExternalException('NoSuchError')),
        _printFailure(
          'Exception',
          'Invalid argument (excType): '
              '''Unknown exception type: 'NoSuchError': "NoSuchError"''',
        ),
      );
    });

    test('a SyntaxError is MontySyntaxError, as upstream raises it', () async {
      expect(
        await failWith(
          (_, _) => throw const ExternalException('SyntaxError', 'bad'),
        ),
        isA<MontySyntaxError>()
            .having((e) => e.message, 'message', 'bad')
            .having(
              (e) => e.display('type-msg'),
              'type-msg',
              'SyntaxError: bad',
            ),
      );
    });

    test('a collector overflow is thrown as the collector threw it, also '
        'from a callback that calls the collector', () async {
      final collector = CollectString(maxBytes: 0);
      Object? overflow;
      final thrown = await failWith((stream, text) {
        try {
          collector(stream, text);
        } on Object catch (e) {
          overflow = e;
          rethrow;
        }
      });
      expect(thrown, same(overflow));
      expect(
        thrown,
        isA<MontyRuntimeError>().having(
          (e) => e.display('type-msg'),
          'type-msg',
          'MemoryError: memory limit exceeded: 1 bytes > 0 bytes',
        ),
      );
    });

    test('a collector overflow passes through also when the callback awaits '
        'before calling the collector', () async {
      final collector = CollectStreams(maxBytes: 0);
      final thrown = await failWith((stream, text) async {
        await Future<void>.delayed(Duration.zero);
        collector(stream, text);
      });
      expect(
        thrown,
        isA<MontyRuntimeError>().having(
          (e) => e.display('type-msg'),
          'type-msg',
          'MemoryError: memory limit exceeded: 65 bytes > 0 bytes',
        ),
      );
    });

    test('an overflow thrown outside this feed and rethrown by its callback '
        'is a host exception like any other MontyError', () async {
      final collector = CollectString(maxBytes: 0);
      late MontyRuntimeError saved;
      try {
        collector('stdout', 'x');
      } on MontyRuntimeError catch (e) {
        saved = e;
      }
      expect(
        await failWith((_, _) => throw saved),
        _printFailure(
          'Exception',
          'MemoryError: memory limit exceeded: 1 bytes > 0 bytes',
        ),
      );
    });

    test('a SyntaxError without a message reads None, as upstream str()s '
        'SyntaxError()', () async {
      expect(
        await failWith((_, _) => throw const ExternalException('SyntaxError')),
        isA<MontySyntaxError>().having(
          (e) => e.display('type-msg'),
          'type-msg',
          'SyntaxError: None',
        ),
      );
    });

    test('a throw whose toString throws raises Exception with no message, '
        'not the toString error', () async {
      expect(
        await failWith((_, _) => throw const _BadText()),
        allOf(
          _printFailure('Exception', ''),
          isA<MontyRuntimeError>().having(
            (e) => e.display('type-msg'),
            'type-msg',
            'Exception',
          ),
        ),
      );
    });

    test('a JSONDecodeError keeps its data host-side, a pos past its doc '
        'too', () async {
      const attributes = {
        'msg': MontyString('bad'),
        'doc': MontyString(''),
        'pos': MontyInt(1),
        'lineno': MontyInt(1),
        'colno': MontyInt(2),
      };
      final thrown = await failWith(
        (_, _) => throw const ExternalException(
          'json.JSONDecodeError',
          'bad: line 1 column 2 (char 1)',
          attributes,
        ),
      );
      expect(
        thrown,
        isA<MontyRuntimeError>()
            .having(
              (e) => e.exception.excType,
              'excType',
              'json.JSONDecodeError',
            )
            .having(
              (e) => exceptionAttributes(e.exception),
              'attributes',
              attributes,
            ),
      );
    });

    test('a throw is classified when it is thrown, not after the turn: a '
        'later change to it does not reach the error', () async {
      final trouble = _Changing('at throw');
      expect(
        await failWith((_, _) {
          scheduleMicrotask(() => trouble.text = 'after throw');
          throw trouble;
        }),
        _printFailure('Exception', 'at throw'),
      );
    });

    test('any other MontyError a callback throws is a host exception like '
        'any other: Exception with its text', () async {
      // As if the callback awaited another session's feed that raised.
      final elsewhere = raisedError(
        pb.RaisedException(excType: 'KeyError', message: 'k'),
      );
      expect(
        await failWith((_, _) => throw elsewhere),
        _printFailure('Exception', 'KeyError: k'),
      );
    });
  });

  group('print failure and a dead worker', () {
    test('a failure, then the worker dies: the failure wins and the slot is '
        'freed without a close', () async {
      final first = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'a')]),
          fatal('panic'),
        ]),
      ]);
      final second = ScriptedChannel([
        _configureOk,
        answer([_int(9)]),
        _resetOk,
      ]);
      final pool = await _pool(Workers([first, second]));
      addTearDown(pool.close);
      // Each checkout takes the slot anew, on purpose.
      // ignore: prefer-moving-to-variable
      final session = await pool.checkout();
      await expectLater(
        session.feedRun(
          'print("a")\nboom()',
          printCallback: (stream, text) async => throw StateError('sink'),
        ),
        throwsA(_printFailure('Exception', 'Bad state: sink')),
      );
      expect(pool.liveWorkers, 0);
      // The failed session is not closed: its slot must already be free.
      // Each checkout takes the slot anew, on purpose.
      // ignore: prefer-moving-to-variable
      final next = await pool.checkout().timeout(const Duration(seconds: 5));
      expect(
        await next.feedRun('9', printCallback: _ignore),
        const MontyInt(9),
      );
      await next.close();
      await session.close();
    });

    test('a callback that closes its session, then throws: the close '
        'wins, the late failure is ignored', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'a')]),
          completeNone(),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      await expectLater(
        session.feedRun(
          'print("a")',
          printCallback: (stream, text) {
            unawaited(session.close());
            throw StateError('late');
          },
        ),
        throwsA(_crashed(CrashCause.killed)),
      );
      expect(pool.liveWorkers, 0);
    });

    for (final cause in [CrashCause.killed, CrashCause.outOfMemory]) {
      test('a callback that throws MontyCrashedError(${cause.name}) is a '
          'print failure like any other: raised as Exception with its text, '
          'the worker kept', () async {
        final ch = ScriptedChannel([
          _configureOk,
          answer([
            printed([(_stdout, 'a')]),
            _int(1),
          ]),
          answer([_int(2)]),
          _resetOk,
        ]);
        final pool = await _pool(Workers([ch]));
        addTearDown(pool.close);
        final session = await pool.checkout();
        // As if the callback awaited another session that crashed.
        final elsewhere = crashedError(cause, detail: 'elsewhere');
        await expectLater(
          session.feedRun(
            'print("a")\n1',
            printCallback: (stream, text) async => throw elsewhere,
          ),
          throwsA(_printFailure('Exception', elsewhere.message)),
        );
        expect(ch.kills, 0);
        expect(
          await session.feedRun('2', printCallback: _ignore),
          const MontyInt(2),
        );
        await session.close();
        expect(pool.idleWorkers, 1);
      });
    }
  });

  group('print stall (gate)', () {
    // A print callback that never completes, ended once by requestTimeout
    // and once by close: the call fails at once, the slot is released once
    // and serves a new checkout, and the callback's late return is ignored.
    for (final byClose in [false, true]) {
      final how = byClose ? 'close' : 'requestTimeout';
      test('ended by $how: the call fails, the slot serves a new '
          'checkout', () async {
        final stalled = ScriptedChannel([
          _configureOk,
          answer([
            printed([(_stdout, 'x')]),
            printed([(_stdout, 'y')]),
            completeNone(),
          ]),
        ]);
        final fresh = ScriptedChannel([
          _configureOk,
          answer([_int(4)]),
          _resetOk,
        ]);
        final pool = await _pool(
          Workers([stalled, fresh]),
          requestTimeout: byClose ? null : _ms(40),
        );
        addTearDown(pool.close);
        // Each checkout takes the slot anew, on purpose.
        // ignore: prefer-moving-to-variable
        final session = await pool.checkout();
        final seen = <String>[];
        final entered = Completer<void>();
        final never = Completer<void>();
        final run = session.feedRun(
          'print("x")\nprint("y")',
          printCallback: (stream, text) {
            seen.add(text);
            if (!entered.isCompleted) entered.complete();

            return never.future;
          },
        );
        final failed = expectLater(run, throwsA(_crashed(CrashCause.killed)));
        await entered.future;
        if (byClose) await session.close();
        await failed.timeout(const Duration(seconds: 5));
        expect(stalled.kills, greaterThan(0));
        expect(pool.liveWorkers, 0);
        // Each checkout takes the slot anew, on purpose.
        // ignore: prefer-moving-to-variable
        final next = await pool.checkout().timeout(const Duration(seconds: 5));
        expect(
          await next.feedRun('4', printCallback: _ignore),
          const MontyInt(4),
        );
        // The stalled callback returns at last: nothing follows from it.
        never.complete();
        await pumpEventQueue();
        expect(seen, ['x']);
        await session.close();
        await next.close();
        expect(pool.idleWorkers, 1);
        expect(pool.liveWorkers, 1);
      });
    }
  });

  group('close while busy (q8 gates)', () {
    test('during a turn, after feedRun(...).timeout: close ends it', () async {
      final ch = ScriptedChannel([_configureOk, hangAfter([])]);
      final fresh = ScriptedChannel([
        _configureOk,
        answer([_int(6)]),
        _resetOk,
      ]);
      final pool = await _pool(Workers([ch, fresh]));
      addTearDown(pool.close);
      // Each checkout takes the slot anew, on purpose.
      // ignore: prefer-moving-to-variable
      final session = await pool.checkout();
      await expectLater(
        session
            .feedRun('while True: pass', printCallback: _ignore)
            .timeout(_ms(30)),
        throwsA(isA<TimeoutException>()),
      );
      await session.close().timeout(const Duration(seconds: 5));
      expect(ch.kills, greaterThan(0));
      expect(pool.liveWorkers, 0);
      await expectLater(
        session.feedRun('1', printCallback: _ignore),
        throwsA(_finished),
      );
      // Each checkout takes the slot anew, on purpose.
      // ignore: prefer-moving-to-variable
      final next = await pool.checkout();
      expect(
        await next.feedRun('6', printCallback: _ignore),
        const MontyInt(6),
      );
      await next.close();
    });

    test('during an unresolved host call: the call fails at once, Reset '
        'now, close returns, the worker serves the next checkout', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_lookup('never')]),
        answer([_call('never')]),
        _resetOk,
        _configureOk,
        answer([_int(8)]),
        _resetOk,
      ]);
      final workers = Workers([ch]);
      final pool = await _pool(workers);
      addTearDown(pool.close);
      // Each checkout takes the slot anew, on purpose.
      // ignore: prefer-moving-to-variable
      final session = await pool.checkout();
      final entered = Completer<void>();
      final run = session.feedRun(
        'never()',
        externals: {
          'never': (args, kwargs) {
            entered.complete();

            // Never completes: host code is not interrupted.
            return Completer<MontyValue>().future;
          },
        },
        printCallback: _ignore,
      );
      await entered.future;
      final failed = expectLater(run, throwsA(_finished));
      await session.close().timeout(const Duration(seconds: 5));
      // The pending call fails at once, though the callback never returns.
      await failed.timeout(const Duration(seconds: 5));
      expect(_lastKind(ch), pb.ParentRequest_Kind.reset);
      expect(ch.kills, 0);
      expect(pool.idleWorkers, 1);
      // Each checkout takes the slot anew, on purpose.
      // ignore: prefer-moving-to-variable
      final next = await pool.checkout();
      expect(
        await next.feedRun('8', printCallback: _ignore),
        const MontyInt(8),
      );
      await next.close();
      expect(workers.started, hasLength(1));
    });

    test('twice during a turn: the second close is a no-op, the slot is '
        'released once', () async {
      final ch = ScriptedChannel([_configureOk, hangAfter([])]);
      final fresh = ScriptedChannel([_configureOk, _resetOk]);
      final third = ScriptedChannel([_configureOk]);
      final pool = await _pool(Workers([ch, fresh, third]));
      addTearDown(pool.close);
      // Each checkout takes the slot anew, on purpose.
      // ignore: prefer-moving-to-variable
      final session = await pool.checkout();
      final run = session.feedRun('while True: pass', printCallback: _ignore);
      final failed = expectLater(run, throwsA(_crashed(CrashCause.killed)));
      await pumpEventQueue();
      await Future.wait([session.close(), session.close()]);
      await session.close();
      await failed;
      expect(pool.liveWorkers, 0);
      // One slot (maxProcesses 1): a second release would admit two.
      // Each checkout takes the slot anew, on purpose.
      // ignore: prefer-moving-to-variable
      final next = await pool.checkout();
      var second = false;
      Future<PoolSession> wait() async {
        // A further checkout on purpose: it must wait for the slot.
        final waited = await pool.checkout();
        second = true;

        return waited;
      }

      final waiting = wait();
      await pumpEventQueue();
      expect(second, isFalse);
      expect(pool.liveWorkers, 1);
      // The waiting checkout outlives the pool's close, as upstream's does,
      // and gets the slot once it is free.
      await pool.close();
      await pumpEventQueue();
      expect(second, isFalse);
      await next.close();
      final late = await waiting;
      expect(second, isTrue);
      expect(pool.liveWorkers, 1);
      await late.close();
      expect(third.kills, 1, reason: 'a closed pool keeps no worker');
      expect(pool.liveWorkers, 0);
    });
  });

  group('outbound outcomes', () {
    /// A string whose input or answer is over [_frameLimit].
    const big = MontyString(
      'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx'
      'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
    );
    const frameLimit = 64;
    final oversized = isA<MontyRuntimeError>()
        .having((e) => e.exception.excType, 'excType', 'RuntimeError')
        .having(
          (e) => e.message,
          'message',
          matches(
            RegExp(
              r'^RuntimeError: request frame of \d+ bytes exceeds the maximum of 64 '
              r'bytes$',
            ),
          ),
        );

    test('an oversized input: the call fails, nothing is sent, the session '
        'runs on', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_int(3)]),
        _resetOk,
      ], frameLimit: frameLimit);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      await expectLater(
        session.feedRun(
          'len(v)',
          inputs: {'v': big},
          printCallback: _ignore,
        ),
        throwsA(oversized),
      );
      expect(ch.requests, hasLength(1));
      expect(ch.kills, 0);
      // The retry, with a value that fits, runs.
      expect(
        await session.feedRun(
          'len(v)',
          inputs: {'v': const MontyString('abc')},
          printCallback: _ignore,
        ),
        const MontyInt(3),
      );
      await session.close();
      expect(pool.idleWorkers, 1);
    });

    test('an oversized automatic answer: the error propagates, the '
        'suspension stays pending, later feeds are refused', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_lookup('g')]),
        answer([_call('g')]),
        _resetOk,
        _configureOk,
        answer([_int(4)]),
        _resetOk,
      ], frameLimit: frameLimit);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      // Each checkout takes the slot anew, on purpose.
      // ignore: prefer-moving-to-variable
      final session = await pool.checkout();
      await expectLater(
        session.feedRun(
          'g()\n3',
          externals: {'g': (args, kwargs) => big},
          printCallback: _ignore,
        ),
        throwsA(oversized),
      );
      // The answer never left: the worker still waits for it.
      // The last request so far: it changes as the test runs.
      // ignore: prefer-moving-to-variable
      expect(_lastKind(ch), pb.ParentRequest_Kind.resumeNameLookup);
      expect(ch.kills, 0);
      final refusedPending = throwsA(
        isA<StateError>().having(
          (e) => e.message,
          'message',
          'feed called while a suspension is awaiting an answer',
        ),
      );
      await expectLater(
        session.feedRun('1', printCallback: _ignore),
        refusedPending,
      );
      // The retry is refused too: upstream recovers no more than this.
      await expectLater(
        session.feedRun(
          'g()\n3',
          externals: {'g': (args, kwargs) => const MontyString('ok')},
          printCallback: _ignore,
        ),
        refusedPending,
      );
      // The last request so far: it changes as the test runs.
      // ignore: prefer-moving-to-variable
      expect(_lastKind(ch), pb.ParentRequest_Kind.resumeNameLookup);
      // close resets the worker, which serves the next checkout.
      await session.close();
      // The last request so far: it changes as the test runs.
      // ignore: prefer-moving-to-variable
      expect(_lastKind(ch), pb.ParentRequest_Kind.reset);
      expect(pool.idleWorkers, 1);
      // Each checkout takes the slot anew, on purpose.
      // ignore: prefer-moving-to-variable
      final next = await pool.checkout();
      expect(
        await next.feedRun('4', printCallback: _ignore),
        const MontyInt(4),
      );
      await next.close();
    });
  });

  group('close', () {
    test('idle: Reset, the worker returns and is reused', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_int(1)]),
        _resetOk,
        _configureOk,
        answer([_int(2)]),
        _resetOk,
      ]);
      final workers = Workers([ch]);
      final pool = await _pool(workers);
      addTearDown(pool.close);
      // Two checkouts on purpose: the second must get this worker back.
      // ignore: prefer-moving-to-variable
      final first = await pool.checkout();
      expect(
        await first.feedRun('1', printCallback: _ignore),
        const MontyInt(1),
      );
      await first.close();
      expect(pool.idleWorkers, 1);
      expect(pool.liveWorkers, 1);
      // A second checkout on purpose: it must get the same worker back.
      // ignore: prefer-moving-to-variable
      final second = await pool.checkout();
      expect(
        await second.feedRun('2', printCallback: _ignore),
        const MontyInt(2),
      );
      await second.close();
      expect(workers.started, hasLength(1));
      expect(
        [for (final r in ch.requests) r.whichKind()],
        [
          pb.ParentRequest_Kind.configure,
          pb.ParentRequest_Kind.feed,
          pb.ParentRequest_Kind.reset,
          pb.ParentRequest_Kind.configure,
          pb.ParentRequest_Kind.feed,
          pb.ParentRequest_Kind.reset,
        ],
      );
    });

    test('twice: one Reset; later calls fail as finished', () async {
      final ch = ScriptedChannel([_configureOk, _resetOk]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      await Future.wait([session.close(), session.close()]);
      await session.close();
      expect(ch.requests, hasLength(2));
      expect(ch.remaining, 0);
      await expectLater(
        session.feedRun('1', printCallback: _ignore),
        throwsA(_finished),
      );
    });

    test('a failed Reset kills the worker; close does not throw', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([completeNone()]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      await session.close();
      expect(ch.kills, 1);
      expect(pool.liveWorkers, 0);
    });

    test('during host code: Reset now; the call fails at once; the '
        "callback's late answer is dropped", () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_lookup('slow')]),
        answer([_call('slow')]),
        _resetOk,
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final entered = Completer<void>();
      final release = Completer<MontyValue>();
      final run = session.feedRun(
        'slow()',
        externals: {
          'slow': (args, kwargs) {
            entered.complete();

            return release.future;
          },
        },
        printCallback: _ignore,
      );
      await entered.future;
      final failed = expectLater(run, throwsA(_finished));
      await session.close();
      // The call failed with the close, while the callback still runs.
      await failed;
      // Reset went out while the callback still ran, and the worker is back.
      expect(_lastKind(ch), pb.ParentRequest_Kind.reset);
      final sent = ch.requests.length;
      expect(pool.idleWorkers, 1);
      expect(ch.kills, 0);
      release.complete(const MontyInt(1));
      await pumpEventQueue();
      // The callback's answer was dropped: nothing was sent after Reset.
      expect(ch.requests, hasLength(sent));
    });

    test('during a turn: kills, the call fails as killed', () async {
      final ch = ScriptedChannel([_configureOk, hangAfter([])]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final run = session.feedRun('while True: pass', printCallback: _ignore);
      final failed = expectLater(run, throwsA(_crashed(CrashCause.killed)));
      await pumpEventQueue();
      await session.close();
      await failed;
      expect(ch.kills, greaterThan(0));
      expect(pool.liveWorkers, 0);
    });

    test('during a turn stuck in a print callback: fails at once', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'x')]),
          completeNone(),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final entered = Completer<void>();
      final never = Completer<void>();
      final run = session.feedRun(
        'print("x")',
        printCallback: (stream, text) {
          entered.complete();

          return never.future;
        },
      );
      final failed = expectLater(run, throwsA(_crashed(CrashCause.killed)));
      await entered.future;
      await session.close();
      await failed.timeout(const Duration(seconds: 5));
      expect(pool.liveWorkers, 0);
    });

    test('no print is delivered after a busy close', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'a'), (_stdout, 'b')]),
          completeNone(),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final seen = <String>[];
      final first = Completer<void>();
      final run = session.feedRun(
        'print("a", "b")',
        printCallback: (stream, text) {
          seen.add(text);

          return text == 'a' ? first.future : null;
        },
      );
      final failed = expectLater(run, throwsA(_crashed(CrashCause.killed)));
      await pumpEventQueue();
      await session.close();
      await failed;
      // The stalled callback returns after the call failed: 'b' never comes.
      first.complete();
      await pumpEventQueue();
      expect(seen, ['a']);
    });

    test('after pool close: the session runs on, then is killed', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_int(3)]),
      ]);
      final pool = await _pool(Workers([ch]));
      final session = await pool.checkout();
      await pool.close();
      expect(
        await session.feedRun('3', printCallback: _ignore),
        const MontyInt(3),
      );
      await session.close();
      expect(ch.kills, 1);
      expect(_lastKind(ch), pb.ParentRequest_Kind.feed);
      expect(pool.liveWorkers, 0);
      await expectLater(pool.checkout(), throwsA(isA<StateError>()));
    });
  });

  group('timeouts', () {
    test('requestTimeout bounds turns, not host callbacks', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_lookup('slow')]),
        answer([_call('slow')]),
        answer([_int(5)]),
        hangAfter([]),
      ]);
      final pool = await _pool(
        Workers([ch]),
        requestTimeout: const Duration(milliseconds: 40),
      );
      addTearDown(pool.close);
      final session = await pool.checkout();
      // The host call takes 3x the timeout; it falls between turns.
      final value = await session.feedRun(
        'slow()',
        externals: {
          'slow': (args, kwargs) async {
            await Future<void>.delayed(const Duration(milliseconds: 120));

            return const MontyNone();
          },
        },
        printCallback: _ignore,
      );
      expect(value, const MontyInt(5));
      await expectLater(
        session.feedRun('while True: pass', printCallback: _ignore),
        throwsA(_timedOut('40ms')),
      );
      expect(pool.liveWorkers, 0);
      await expectLater(
        session.feedRun('1', printCallback: _ignore),
        throwsA(_finished),
      );
    });

    test('requestTimeout covers print delivery', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'x')]),
          completeNone(),
        ]),
      ]);
      final pool = await _pool(
        Workers([ch]),
        requestTimeout: const Duration(milliseconds: 30),
      );
      addTearDown(pool.close);
      final session = await pool.checkout();
      final never = Completer<void>();
      await expectLater(
        session.feedRun('print("x")', printCallback: (s, t) => never.future),
        throwsA(_timedOut('30ms')),
      );
      expect(pool.liveWorkers, 0);
    });

    test('feed backstop: the budget left, plus its grace', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_lookup('f')]),
        // 150 ms of the 200 ms budget used when the host is asked.
        answer([_call('f', feedMicros: 150000)]),
        hangAfter([]),
      ]);
      final pool = await _pool(
        Workers([ch]),
        feedGrace: const Duration(milliseconds: 100),
        turnGrace: null,
      );
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: const SessionConfig(
          limits: ResourceLimits(
            maxFeedDuration: Duration(milliseconds: 200),
          ),
        ),
      );
      await expectLater(
        session.feedRun(
          'f()',
          externals: {'f': (args, kwargs) => const MontyNone()},
          printCallback: _ignore,
        ),
        // 200 - 150 + 100.
        throwsA(_timedOut('150ms')),
      );
    });

    test('feed backstop: a worker cannot rewind its feed clock', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_lookup('f')]),
        answer([_call('f', feedMicros: 150000)]),
        // Reports less than before, mid-feed.
        answer([_call('f', feedMicros: 1000)]),
        hangAfter([]),
      ]);
      final pool = await _pool(
        Workers([ch]),
        feedGrace: const Duration(milliseconds: 100),
        turnGrace: null,
      );
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: const SessionConfig(
          limits: ResourceLimits(
            maxFeedDuration: Duration(milliseconds: 200),
          ),
        ),
      );
      await expectLater(
        session.feedRun(
          'f(); f()',
          externals: {'f': (args, kwargs) => const MontyNone()},
          printCallback: _ignore,
        ),
        // Still 200 - 150 + 100, not 200 - 1 + 100.
        throwsA(_timedOut('150ms')),
      );
    });

    test('turn backstop: the turn budget plus its grace', () async {
      final ch = ScriptedChannel([_configureOk, hangAfter([])]);
      final pool = await _pool(
        Workers([ch]),
        requestTimeout: const Duration(seconds: 30),
        feedGrace: null,
        turnGrace: const Duration(milliseconds: 10),
      );
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: const SessionConfig(
          limits: ResourceLimits(
            maxFeedDuration: Duration(milliseconds: 1),
            maxTurnDuration: Duration(milliseconds: 20),
          ),
        ),
      );
      await expectLater(
        session.feedRun('while True: pass', printCallback: _ignore),
        throwsA(_timedOut('30ms')),
      );
    });
  });

  group('suspension budget', () {
    test('past maxSuspensions the feed is aborted in the sandbox', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_lookup('f')]),
        // The second and third suspensions; the third is over a budget of 2
        // and never handed over.
        for (var i = 0; i < 2; i++) answer([_call('f')]),
        expecting(pb.ParentRequest_Kind.abortFeed, [
          raised('RuntimeError', 'suspension limit 2 exceeded'),
        ]),
        answer([_int(4)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: const SessionConfig(
          limits: ResourceLimits(
            maxSuspensions: 2,
          ),
        ),
      );
      var calls = 0;
      await expectLater(
        session.feedRun(
          'while True: f()',
          externals: {'f': (args, kwargs) => MontyInt(++calls)},
          printCallback: _ignore,
        ),
        throwsA(
          isA<MontyRuntimeError>()
              .having((e) => e.exception.excType, 'excType', 'RuntimeError')
              .having((e) => e.message, 'message', contains('limit 2')),
        ),
      );
      expect(calls, 1);
      final abort = itemAt(ch.requests, 4).abortFeed.exception;
      expect(abort.excType, 'RuntimeError');
      expect(abort.message, 'suspension limit 2 exceeded');
      expect(itemAt(ch.requests, 0).configure.limits.maxSuspensions, Int64(2));
      // The session runs on.
      expect(
        await session.feedRun('4', printCallback: _ignore),
        const MontyInt(4),
      );
    });

    test("a reply's limit is unsigned: u64::MAX does not tighten", () async {
      // Upstream's update_from takes min(limit, reported) over u64s, so a
      // reply reporting u64::MAX leaves the checkout's limit as it was; a
      // smaller one (here 1) is the limit from then on.
      final huge = _call('f')..maxSuspensions = Int64(-1);
      final one = _call('f')..maxSuspensions = Int64.ONE;
      final ch = ScriptedChannel([
        _configureOk,
        answer([huge]),
        answer([one]),
        expecting(pb.ParentRequest_Kind.abortFeed, [
          raised('RuntimeError', 'suspension limit 1 exceeded'),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: const SessionConfig(
          limits: ResourceLimits(maxSuspensions: 5),
        ),
      );
      await expectLater(
        session.feedRun(
          'f(); f()',
          externals: {'f': (args, kwargs) => const MontyNone()},
          printCallback: _ignore,
        ),
        throwsA(
          isA<MontyRuntimeError>().having(
            (e) => e.exception.message,
            'exception',
            'suspension limit 1 exceeded',
          ),
        ),
      );
      expect(ch.remaining, 0);
    });

    test("the abort's reply tightens the limit too", () async {
      // Upstream passes every event, the AbortFeed's Error included,
      // through update_from.
      final call = _call('f');
      final ch = ScriptedChannel([
        _configureOk,
        answer([call]),
        answer([call]),
        expecting(pb.ParentRequest_Kind.abortFeed, [
          raised('RuntimeError', 'suspension limit 1 exceeded')
            ..maxSuspensions = Int64.ZERO,
        ]),
        expecting(pb.ParentRequest_Kind.feed, [call]),
        expecting(pb.ParentRequest_Kind.abortFeed, [
          raised('RuntimeError', 'suspension limit 0 exceeded'),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: const SessionConfig(
          limits: ResourceLimits(maxSuspensions: 1),
        ),
      );
      final externals = {'f': (_, _) => const MontyNone()};
      for (var i = 0; i < 2; i++) {
        await expectLater(
          session.feedRun(
            'f(); f()',
            externals: externals,
            printCallback: _ignore,
          ),
          throwsA(isA<MontyRuntimeError>()),
        );
      }
      expect(ch.remaining, 0);
      // The aborts core sent: the second names the tightened limit.
      expect(
        [
          for (final i in [3, 5])
            itemAt(ch.requests, i).abortFeed.exception.message,
        ],
        ['suspension limit 1 exceeded', 'suspension limit 0 exceeded'],
      );
    });

    test('the default budget is 1000', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_lookup('f')]),
        for (var i = 0; i < 999; i++) answer([_call('f')]),
        answer([_call('f')]),
        expecting(pb.ParentRequest_Kind.abortFeed, [
          raised('RuntimeError', 'suspension limit 1000 exceeded'),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      await expectLater(
        session.feedRun(
          'while True: f()',
          externals: {'f': (args, kwargs) => const MontyNone()},
          printCallback: _ignore,
        ),
        throwsA(isA<MontyRuntimeError>()),
      );
      expect(ch.remaining, 0);
      expect(_lastKind(ch), pb.ParentRequest_Kind.abortFeed);
    });

    test('the abort runs under the turn deadline it replaces', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_lookup('f')]),
        // The abort is never answered.
        hangAfter([]),
      ]);
      final pool = await _pool(
        Workers([ch]),
        feedGrace: _ms(10),
        turnGrace: null,
      );
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: SessionConfig(
          limits: ResourceLimits(
            maxSuspensions: 0,
            maxFeedDuration: _ms(20),
          ),
        ),
      );
      await expectLater(
        session.feedRun('f()', printCallback: _ignore),
        throwsA(_timedOut('30ms')),
      );
      expect(_lastKind(ch), pb.ParentRequest_Kind.abortFeed);
      expect(pool.liveWorkers, 0);
    });

    test('a worker lost while the abort is written: aborting a feed', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_lookup('f')]),
        crash(CrashCause.vanished, 'EPIPE', 1, sendingRequest),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: const SessionConfig(
          limits: ResourceLimits(maxSuspensions: 0),
        ),
      );
      await expectLater(
        session.feedRun('f()', printCallback: _ignore),
        throwsA(
          isA<MontyCrashedError>().having(
            (e) => e.message,
            'message',
            'monty worker crashed while aborting a feed (exit status: 1)',
          ),
        ),
      );
      expect(_lastKind(ch), pb.ParentRequest_Kind.abortFeed);
    });

    test('an abort answered with anything but Error kills', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_lookup('f')]),
        answer([completeNone()]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: const SessionConfig(
          limits: ResourceLimits(
            maxSuspensions: 0,
          ),
        ),
      );
      await expectLater(
        session.feedRun('f()', printCallback: _ignore),
        throwsA(
          _violation(
            'worker answered AbortFeed with something other than an Error',
          ),
        ),
      );
      expect(pool.liveWorkers, 0);
    });
  });

  group('system sleep', () {
    pb.ChildEvent sleep(double seconds) => pb.ChildEvent(
      osCall: pb.OsCall(
        callId: 3,
        systemSleep: pb.OsCall_Sleep(seconds: seconds),
      ),
    );

    test('is waited and answered with None, without an os handler', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([sleep(0.05)]),
        expecting(pb.ParentRequest_Kind.resumeCall, [_int(1)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final clock = Stopwatch()..start();
      expect(
        await session.feedRun('time.sleep(0.05)', printCallback: _ignore),
        const MontyInt(1),
      );
      expect(clock.elapsed, greaterThanOrEqualTo(_ms(45)));
      final resume = itemAt(ch.requests, 2).resumeCall;
      expect(resume.callId, 3);
      expect(resume.result.hasReturnValue(), isTrue);
      expect(itemAt(resume.values.nodes, 0).hasNone(), isTrue);
    });

    test(
      "is cut to the policy's maximum; a bad delay waits the maximum",
      () async {
        final ch = ScriptedChannel([
          _configureOk,
          answer([sleep(30)]),
          answer([sleep(double.nan)]),
          answer([_int(1)]),
        ]);
        final pool = await _pool(Workers([ch]));
        addTearDown(pool.close);
        const policy = OsPolicy(sleepSystemMax: Duration(milliseconds: 20));
        final session = await pool.checkout(
          options: const SessionConfig(osPolicy: policy),
        );
        final clock = Stopwatch()..start();
        await session.feedRun('time.sleep(30)', printCallback: _ignore);
        expect(clock.elapsed, lessThan(const Duration(seconds: 5)));
        expect(clock.elapsed, greaterThanOrEqualTo(_ms(35)));
        expect(
          itemAt(ch.requests, 0).configure.osPolicy.sleep.system.maxMicros,
          Int64(20000),
        );
      },
    );
  });

  group('sleep budget', () {
    pb.ChildEvent sleep(double seconds) => pb.ChildEvent(
      osCall: pb.OsCall(
        callId: 3,
        systemSleep: pb.OsCall_Sleep(seconds: seconds),
      ),
    );

    Matcher timedOut(String message) => throwsA(
      isA<MontyRuntimeError>()
          .having((e) => e.exception.excType, 'excType', 'TimeoutError')
          .having((e) => e.exception.message, 'exception', message)
          .having((e) => e.message, 'message', 'TimeoutError: $message'),
    );

    test('the sleep that passes maxTotalSleep aborts, unwaited', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([sleep(0.04)]),
        expecting(pb.ParentRequest_Kind.resumeCall, [_int(1)]),
        // The charge is the session's: 40 ms from the last feed, 70 now.
        answer([sleep(0.07)]),
        expecting(pb.ParentRequest_Kind.abortFeed, [
          raised('TimeoutError', 'sleep limit exceeded: 110ms > 100ms'),
        ]),
        answer([_int(2)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: const SessionConfig(
          limits: ResourceLimits(maxTotalSleep: Duration(milliseconds: 100)),
        ),
      );
      expect(
        itemAt(ch.requests, 0).configure.limits.maxTotalSleepMicros,
        Int64(100000),
      );
      await session.feedRun('time.sleep(0.04)', printCallback: _ignore);
      await expectLater(
        session.feedRun('time.sleep(0.07)', printCallback: _ignore),
        timedOut('sleep limit exceeded: 110ms > 100ms'),
      );
      // Unwaited: the abort is the answer, with no resume before it.
      expect(itemAt(ch.requests, 3).whichKind(), pb.ParentRequest_Kind.feed);
      final abort = itemAt(ch.requests, 4).abortFeed.exception;
      expect(abort.excType, 'TimeoutError');
      expect(abort.message, 'sleep limit exceeded: 110ms > 100ms');
      // The session runs on.
      expect(
        await session.feedRun('2', printCallback: _ignore),
        const MontyInt(2),
      );
    });

    test('a capped sleep is charged its cap; a bad delay the cap', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([sleep(30)]),
        answer([sleep(double.nan)]),
        answer([sleep(0.015)]),
        expecting(pb.ParentRequest_Kind.abortFeed, [
          raised('TimeoutError', 'sleep limit exceeded: 55ms > 50ms'),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: const SessionConfig(
          limits: ResourceLimits(maxTotalSleep: Duration(milliseconds: 50)),
          osPolicy: OsPolicy(sleepSystemMax: Duration(milliseconds: 20)),
        ),
      );
      await expectLater(
        session.feedRun('...', printCallback: _ignore),
        timedOut('sleep limit exceeded: 55ms > 50ms'),
      );
    });

    test('charged in nanoseconds; uncapped is the request itself', () async {
      for (final (seconds, config, message) in [
        (
          0.0000014,
          const SessionConfig(
            limits: ResourceLimits(maxTotalSleep: Duration(microseconds: 1)),
          ),
          'sleep limit exceeded: 1.4µs > 1µs',
        ),
        (
          9.1e9,
          const SessionConfig(
            limits: ResourceLimits(maxTotalSleep: Duration(seconds: 1)),
            osPolicy: OsPolicy(sleepSystemMax: uncappedSleep),
          ),
          'sleep limit exceeded: 9100000000s > 1s',
        ),
      ]) {
        final ch = ScriptedChannel([
          _configureOk,
          answer([sleep(seconds)]),
          expecting(pb.ParentRequest_Kind.abortFeed, [
            raised('TimeoutError', message),
          ]),
        ]);
        final pool = await _pool(Workers([ch]));
        addTearDown(pool.close);
        final session = await pool.checkout(options: config);
        await expectLater(
          session.feedRun('...', printCallback: _ignore),
          timedOut(message),
        );
        expect(itemAt(ch.requests, 2).abortFeed.exception.message, message);
      }
    });

    test("the worker's echoed sleep limit tightens the session's", () async {
      // Upstream's update_from: a reply reporting a smaller limit (a loaded
      // dump's, or a saturated one) is the limit from then on.
      final echoed = sleep(0.15)..maxTotalSleepMicros = Int64(100000);
      final ch = ScriptedChannel([
        _configureOk,
        answer([echoed]),
        expecting(pb.ParentRequest_Kind.abortFeed, [
          raised('TimeoutError', 'sleep limit exceeded: 150ms > 100ms'),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: const SessionConfig(
          limits: ResourceLimits(maxTotalSleep: Duration(seconds: 1)),
        ),
      );
      await expectLater(
        session.feedRun('...', printCallback: _ignore),
        timedOut('sleep limit exceeded: 150ms > 100ms'),
      );
    });

    test('no limit: sleeps are waited, never charged against one', () async {
      final ch = ScriptedChannel([
        _configureOk,
        for (var i = 0; i < 2; i++) answer([sleep(0.01)]),
        expecting(pb.ParentRequest_Kind.resumeCall, [_int(1)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      expect(
        await session.feedRun('...', printCallback: _ignore),
        const MontyInt(1),
      );
      expect(itemAt(ch.requests, 0).configure.hasLimits(), isFalse);
    });
  });

  group('settings refused', () {
    final refused = {
      'a negative limit': const SessionConfig(
        limits: ResourceLimits(maxMemory: -1),
      ),
      'an unknown policy mode': const SessionConfig(
        osPolicy: OsPolicy(sleep: 'nap'),
      ),
      'a non-finite seed': const SessionConfig(
        osPolicy: OsPolicy(randomSeed: RandomSeed.float(double.nan)),
      ),
      'both forms of one field': const SessionConfig(
        osPolicy: OsPolicy(
          randomStart: 'system',
          randomSeed: RandomSeed.string('x'),
        ),
      ),
      'an annotation length past u32': const SessionConfig(
        assertMessageAnnotations: 0x100000000,
      ),
      'a negative flush interval': SessionConfig(printFlushInterval: _ms(-1)),
    };
    for (final MapEntry(key: name, value: config) in refused.entries) {
      test('$name, before a worker is taken', () async {
        final workers = Workers([]);
        final pool = await _pool(workers);
        addTearDown(pool.close);
        await expectLater(
          pool.checkout(options: config),
          throwsA(isA<ArgumentError>()),
        );
        expect(workers.started, isEmpty);
        expect(pool.liveWorkers, 0);
      });
    }

    // Upstream refuses an unknown zone while parsing the checkout's
    // arguments (os_policy.rs:144-150), before a worker is taken.
    test('an unknown zone name: ArgumentError, no worker taken', () async {
      final workers = Workers([]);
      final pool = await _pool(workers);
      addTearDown(pool.close);
      await expectLater(
        pool.checkout(
          options: const SessionConfig(osPolicy: OsPolicy(timezone: 'Q/Z')),
        ),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.message,
            'message',
            "unknown timezone 'Q/Z'",
          ),
        ),
      );
      expect(workers.started, isEmpty);
      expect(pool.liveWorkers, 0);
    });

    // An Error reply to Configure is raised as any error is (upstream's
    // PoolError::Runtime, checkout.rs:773-776), and the worker discarded.
    test(
      'one the worker refuses: raised as converted, the slot freed',
      () async {
        const refusal =
            "protocol violation: invalid os_policy: unknown timezone 'Q/Z'";
        final ch = ScriptedChannel([
          answer([raised('RuntimeError', refusal)]),
        ]);
        final pool = await _pool(Workers([ch]));
        addTearDown(pool.close);
        await expectLater(
          pool.checkout(
            options: const SessionConfig(
              osPolicy: OsPolicy(timezone: 'Europe/London'),
            ),
          ),
          throwsA(
            isA<MontyRuntimeError>().having(
              (e) => e.display('type-msg'),
              'display',
              'RuntimeError: $refusal',
            ),
          ),
        );
        expect(ch.kills, greaterThan(0));
        expect(pool.liveWorkers, 0);
      },
    );
  });

  group('type check', () {
    test('Configure carries the settings; a rejection is in-band', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          pb.ChildEvent(typingError: pb.TypingError(diagnostics: 'bad: int')),
        ]),
        expecting(pb.ParentRequest_Kind.feed, [_int(5)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: const SessionConfig(
          typeCheck: true,
          typeCheckStubs: 'x: int',
          typeCheckFormat: 'concise',
          typeCheckColor: true,
        ),
      );
      final configure = itemAt(ch.requests, 0).configure;
      expect(configure.typeCheck, isTrue);
      expect(configure.typeCheckStubs, 'x: int');
      expect(
        configure.typeCheckFormat,
        pb.TypeCheckFormat.TYPE_CHECK_FORMAT_CONCISE,
      );
      expect(configure.typeCheckColor, isTrue);
      await expectLater(
        session.feedRun('x: int = "a"', printCallback: _ignore),
        throwsA(
          isA<MontyTypingError>().having(
            (e) => e.message,
            'message',
            'bad: int',
          ),
        ),
      );
      expect(itemAt(ch.requests, 1).feed.skipTypeCheck, isFalse);
      expect(
        await session.feedRun(
          'x: int = "a"',
          skipTypeCheck: true,
          printCallback: _ignore,
        ),
        const MontyInt(5),
      );
      expect(itemAt(ch.requests, 2).feed.skipTypeCheck, isTrue);
    });

    test('an unknown format is refused before a worker is taken', () async {
      final workers = Workers([]);
      final pool = await _pool(workers);
      addTearDown(pool.close);
      await expectLater(
        pool.checkout(
          options: const SessionConfig(
            typeCheck: true,
            typeCheckFormat: 'fancy',
          ),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(workers.started, isEmpty);
      expect(pool.liveWorkers, 0);
    });
  });

  group('the worker dies', () {
    test('exit 65 is a MemoryError and finishes the session', () async {
      final first = ScriptedChannel([
        _configureOk,
        crash(CrashCause.outOfMemory, 'exit 65'),
      ]);
      final second = ScriptedChannel([_configureOk]);
      final workers = Workers([first, second]);
      final pool = await _pool(workers);
      addTearDown(pool.close);
      // Two checkouts on purpose: the second gets a fresh worker.
      // ignore: prefer-moving-to-variable
      final session = await pool.checkout();
      await expectLater(
        session.feedRun('x = [0] * 10**9', printCallback: _ignore),
        throwsA(
          isA<MontyRuntimeError>()
              .having((e) => e.exception.excType, 'excType', 'MemoryError')
              .having((e) => e.message, 'message', contains('memory limit')),
        ),
      );
      expect(pool.liveWorkers, 0);
      await expectLater(
        session.feedRun('1', printCallback: _ignore),
        throwsA(_finished),
      );
      // Closing a finished session sends nothing.
      await session.close();
      expect(first.requests, hasLength(2));
      // The freed slot serves a fresh worker: a second checkout on purpose.
      // ignore: prefer-moving-to-variable
      await pool.checkout();
      expect(workers.started, [first, second]);
    });

    test('a dead worker: its exit status, if the OS gave one', () async {
      for (final (exitCode, status, message) in [
        (
          3,
          3,
          'monty worker crashed while waiting for a reply '
              '(exit status: 3)',
        ),
        (
          -9,
          null,
          'monty worker crashed while waiting for a reply '
              '(signal: 9 (SIGKILL))',
        ),
      ]) {
        final ch = ScriptedChannel([
          _configureOk,
          crash(CrashCause.vanished, 'EOF', exitCode),
        ]);
        final pool = await _pool(Workers([ch]));
        addTearDown(pool.close);
        final session = await pool.checkout();
        await expectLater(
          session.feedRun('...', printCallback: _ignore),
          throwsA(
            isA<MontyCrashedError>()
                .having((e) => e.exitStatus, 'exitStatus', status)
                .having((e) => e.timedOut, 'timedOut', isFalse)
                .having((e) => e.message, 'message', message)
                .having((e) => e.exception.message, 'exception', message),
          ),
        );
        expect(pool.liveWorkers, 0);
      }
    });

    test('a forged exception: a protocol violation, the session gone', () {
      return Future.forEach(
        <pb.ChildEvent, String>{
          raised('Bogus', 'x'): 'unknown exception type "Bogus"',
          raised('ValueError', 'x', [
            pb.StackFrame(filename: 'f', start: pb.CodeLoc(line: 1, column: 1)),
          ]): 'missing required field StackFrame.end',
          pb.ChildEvent(error: pb.Error()): '',
        }.entries,
        (entry) async {
          final MapEntry(key: event, value: detail) = entry;
          final ch = ScriptedChannel([
            _configureOk,
            answer([event]),
          ]);
          final pool = await _pool(Workers([ch]));
          addTearDown(pool.close);
          final session = await pool.checkout();
          await expectLater(
            session.feedRun('...', printCallback: _ignore),
            throwsA(
              _violation(
                detail.isEmpty
                    ? 'error event with no exception'
                    : 'invalid exception payload: $detail',
              ),
            ),
          );
          expect(ch.kills, greaterThan(0));
          expect(pool.liveWorkers, 0);
          await expectLater(
            session.feedRun('1', printCallback: _ignore),
            throwsA(_finished),
          );
        },
      );
    });

    test('any other crash is rethrown and frees the slot', () async {
      final ch = ScriptedChannel([
        _configureOk,
        crash(CrashCause.vanished, 'EOF'),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      await expectLater(
        session.feedRun('1', printCallback: _ignore),
        throwsA(_crashed(CrashCause.vanished)),
      );
      expect(pool.liveWorkers, 0);
    });
  });

  group('scoped helpers', () {
    test('withSession closes on success and on a throw', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_int(9)]),
        _resetOk,
        _configureOk,
        _resetOk,
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final value = await pool.withSession(
        (s) => s.feedRun('9', printCallback: _ignore),
        options: const SessionConfig(
          scriptName: 'scoped.py',
        ),
      );
      expect(value, const MontyInt(9));
      expect(pool.idleWorkers, 1);
      await expectLater(
        pool.withSession<void>((s) async => throw StateError('body')),
        throwsA(isA<StateError>().having((e) => e.message, 'm', 'body')),
      );
      expect(pool.idleWorkers, 1);
      expect(ch.remaining, 0);
      expect(itemAt(ch.requests, 0).configure.scriptName, 'scoped.py');
    });

    test('withPool closes the pool however the body ends', () async {
      MontyPool? seen;
      await expectLater(
        MontyPool.withPool<void>(
          (pool) async {
            seen = pool;
            throw StateError('body');
          },
          options: const PoolOptions(
            minProcesses: 0,
            workerLocation: 'unused',
          ),
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'm', 'body')),
      );
      final pool = seen ?? fail('withPool never ran its body');
      await expectLater(pool.checkout(), throwsA(isA<StateError>()));
    });

    test('withPool returns the body value', () async {
      expect(
        await MontyPool.withPool(
          (pool) async => 7,
          options: const PoolOptions(
            minProcesses: 0,
          ),
        ),
        7,
      );
    });
  });

  group('dump and load', () {
    /// A `DumpResult` of [bytes].
    pb.ChildEvent dumped(List<int> bytes) =>
        pb.ChildEvent(dumpResult: pb.DumpResult(state: bytes));

    final state = Uint8List.fromList([1, 2, 3]);

    test('a dump keeps a suspension pending: a feed is still refused, and '
        'the snapshot still resumes', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_call('f')]),
        expecting(pb.ParentRequest_Kind.dump, [
          dumped([7]),
        ]),
        expecting(pb.ParentRequest_Kind.dump, [
          raised('MemoryError', 'dump too large'),
        ]),
        expecting(pb.ParentRequest_Kind.resumeCall, [_int(2)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final snapshot =
          await session.feedStart('f()', printCallback: _ignore)
              as FunctionSnapshot;
      expect(await session.dump(), [7]);
      // The same feed, refused before and after the next dump.
      await _refusedAsPending(session);
      // An error reply to a Dump does not end the feed either (upstream
      // keeps the pending call).
      await expectLater(
        snapshot.dump(),
        throwsA(
          isA<MontyRuntimeError>().having(
            (e) => e.exception.excType,
            'excType',
            'MemoryError',
          ),
        ),
      );
      await _refusedAsPending(session);
      expect(
        await snapshot.resume(const ExternalReturnValue(MontyInt(1))),
        isA<SessionComplete>(),
      );
      expect(ch.remaining, 0);
    });

    test('a dump waits for the turn in flight, as upstream takes the '
        'session lock', () async {
      final release = Completer<void>();
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'x')]),
          _int(1),
        ]),
        expecting(pb.ParentRequest_Kind.dump, [
          dumped([9]),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final printing = Completer<void>();
      final order = <String>[];
      Future<void> feeding() async {
        await session.feedRun(
          'print("x")',
          printCallback: (stream, text) async {
            printing.complete();
            await release.future;
          },
        );
        order.add('feed');
      }

      Future<void> dumping() async => order.add('dump ${await session.dump()}');

      final feed = feeding();
      await printing.future;
      expect(session.workerPid, isNull, reason: 'a turn is in flight');
      final dump = dumping();
      await pumpEventQueue();
      expect(order, isEmpty);
      release.complete();
      await Future.wait([feed, dump]);
      expect(order, ['feed', 'dump [9]']);
    });

    test('a feed made while a dump runs is refused once the dump ends: the '
        'suspension is still pending', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_call('f')]),
        expecting(pb.ParentRequest_Kind.dump, [
          dumped([1]),
        ]),
        expecting(pb.ParentRequest_Kind.resumeCall, [_int(2)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final snapshot =
          await session.feedStart('f()', printCallback: _ignore)
              as FunctionSnapshot;
      final dump = session.dump();
      await expectLater(
        session.feedRun('1', printCallback: _ignore),
        throwsA(_pending),
      );
      expect(await dump, [1]);
      expect(
        await snapshot.resume(const ExternalReturnValue(MontyNone())),
        isA<SessionComplete>(),
      );
      expect(ch.remaining, 0);
    });

    test('a feed queued behind a dump from host code is refused, not left '
        'waiting', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_call('f')]),
        expecting(pb.ParentRequest_Kind.dump, [
          dumped([1]),
        ]),
        expecting(pb.ParentRequest_Kind.resumeCall, [_int(2)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      Object? refused;
      Future<Uint8List>? dump;
      final value = await session.feedRun(
        'f()',
        externals: {
          'f': (args, kwargs) async {
            dump = session.dump();
            try {
              await session.feedRun('1', printCallback: _ignore);
              // The refusal is the outcome under test.
              // ignore: avoid_catching_errors
            } on StateError catch (e) {
              refused = e;
            }

            return const MontyNone();
          },
        },
        printCallback: _ignore,
      );
      expect(value, const MontyInt(2));
      expect(refused, _pending);
      expect(await dump, [1]);
    }, timeout: const Timeout(Duration(seconds: 5)));

    test(
      "a snapshot's dump is checked and sent in one step: a free channel "
      'takes it at once, and a resume made meanwhile spends it first',
      () async {
        final ch = ScriptedChannel([
          _configureOk,
          answer([_call('f')]),
          expecting(pb.ParentRequest_Kind.dump, [
            dumped([1]),
          ]),
          // The second dump is never sent: the resume is next.
          expecting(pb.ParentRequest_Kind.resumeCall, [_int(3)]),
        ]);
        final pool = await _pool(Workers([ch]));
        addTearDown(pool.close);
        final session = await pool.checkout();
        final snapshot =
            await session.feedStart('f()', printCallback: _ignore)
                as FunctionSnapshot;
        final sent = ch.requests.length;
        final first = snapshot.dump();
        // Sent before this test's next statement: nothing can come between
        // the check and the send.
        expect(ch.requests.length, sent + 1);
        // Busy now: this one waits, and a resume made meanwhile spends the
        // snapshot before the dump's check.
        final second = expectLater(
          snapshot.dump(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'cannot dump a snapshot that has already been resumed',
            ),
          ),
        );
        final resumed = snapshot.resume(
          const ExternalReturnValue(MontyNone()),
        );
        expect(await first, [1]);
        await second;
        expect(await resumed, isA<SessionComplete>());
        expect(ch.remaining, 0);
      },
    );

    test('a feed and a resume made while a dump runs: the feed is refused, '
        'the resume runs after the dump', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_call('f')]),
        expecting(pb.ParentRequest_Kind.dump, [
          dumped([1]),
        ]),
        expecting(pb.ParentRequest_Kind.resumeCall, [_int(2)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final snapshot =
          await session.feedStart('f()', printCallback: _ignore)
              as FunctionSnapshot;
      final dump = session.dump();
      final feed = session.feedRun('1', printCallback: _ignore);
      final resumed = snapshot.resume(const ExternalReturnValue(MontyNone()));
      await expectLater(feed, throwsA(_pending));
      expect(await dump, [1]);
      expect(await resumed, isA<SessionComplete>());
      expect(ch.remaining, 0);
    });

    test('a feed made after a resume, both while a dump runs, waits for the '
        'resume and then runs', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([_call('f')]),
        expecting(pb.ParentRequest_Kind.dump, [
          dumped([1]),
        ]),
        expecting(pb.ParentRequest_Kind.resumeCall, [_int(2)]),
        expecting(pb.ParentRequest_Kind.feed, [_int(3)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final snapshot =
          await session.feedStart('f()', printCallback: _ignore)
              as FunctionSnapshot;
      final dump = session.dump();
      final resumed = snapshot.resume(const ExternalReturnValue(MontyNone()));
      final feed = session.feedRun('3', printCallback: _ignore);
      expect(await dump, [1]);
      expect(await resumed, isA<SessionComplete>());
      expect(await feed, const MontyInt(3));
      expect(ch.remaining, 0);
    });

    test('a close while a dump runs fails the feed waiting on host code at '
        'once', () async {
      // The Dump is never answered: only the close's kill ends it.
      final hung = ScriptedChannel([
        _configureOk,
        answer([_call('f')]),
        hangAfter([]),
      ]);
      final pool = await _pool(Workers([hung]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final never = Completer<MontyValue>();
      final dumping = Completer<void>();
      Future<Uint8List>? dump;
      final feed = session.feedRun(
        'f()',
        externals: {
          'f': (args, kwargs) {
            dump = session.dump();
            dumping.complete();

            return never.future;
          },
        },
        printCallback: _ignore,
      );
      await dumping.future;
      await pumpEventQueue();
      final feedFails = expectLater(feed, throwsA(_finished));
      final dumpFails = expectLater(dump, throwsA(isA<MontyCrashedError>()));
      await session.close();
      await feedFails;
      await dumpFails;
      expect(pool.liveWorkers, 0);
    }, timeout: const Timeout(Duration(seconds: 5)));

    test('a dump from inside a print callback throws StateError', () async {
      final ch = ScriptedChannel([
        _configureOk,
        answer([
          printed([(_stdout, 'x')]),
          _call('f'),
        ]),
        answer([
          printed([(_stdout, 'y')]),
          _int(1),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      Object? fromSession;
      final snapshot =
          await session.feedStart(
                'f()',
                printCallback: (stream, text) async {
                  try {
                    await session.dump();
                  } on Object catch (e) {
                    fromSession = e;
                  }
                },
              )
              as FunctionSnapshot;
      expect(fromSession, isA<StateError>());
      expect(
        await snapshot.resume(const ExternalReturnValue(MontyNone())),
        isA<SessionComplete>(),
      );
      expect(ch.remaining, 0);
    });

    test("a Load the worker refuses puts back the session's budgets, then "
        'records the reply', () async {
      // Upstream restores the pre-load budget, then records the reply on it
      // (checkout.rs abort_if_over_budget, update_from): the session's feed
      // backstop is back, and the reply's suspension limit tightens.
      final refusal = raised('RuntimeError', 'not a monty dump')
        ..maxSuspensions = Int64.ZERO;
      final ch = ScriptedChannel([
        _configureOk,
        expecting(pb.ParentRequest_Kind.load, [refusal]),
        answer([_call('f')]),
        expecting(pb.ParentRequest_Kind.abortFeed, [
          raised('RuntimeError', 'suspension limit 0 exceeded'),
        ]),
        hangAfter([]),
      ]);
      final pool = await _pool(Workers([ch]), feedGrace: Duration.zero);
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: SessionConfig(
          limits: ResourceLimits(maxFeedDuration: _ms(30)),
        ),
      );
      await expectLater(
        session.loadSession(state),
        throwsA(isA<MontyRuntimeError>()),
      );
      expect(itemAt(ch.requests, 1).load.state, state);
      await expectLater(
        session.feedRun('f()', printCallback: _ignore),
        throwsA(
          isA<MontyRuntimeError>().having(
            (e) => e.exception.message,
            'message',
            'suspension limit 0 exceeded',
          ),
        ),
      );
      await expectLater(
        session.feedRun('while True: pass', printCallback: _ignore),
        throwsA(_timedOut('30ms')),
      );
    }, timeout: const Timeout(Duration(seconds: 5)));

    test("a load adopts the dump's feed budget: the session's is "
        'forgotten', () async {
      final ch = ScriptedChannel([
        _configureOk,
        expecting(pb.ParentRequest_Kind.load, [
          ok()..maxFeedDurationMicros = Int64(30000),
        ]),
        hangAfter([]),
      ]);
      final pool = await _pool(Workers([ch]), feedGrace: Duration.zero);
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: const SessionConfig(
          limits: ResourceLimits(maxFeedDuration: Duration(seconds: 30)),
        ),
      );
      await session.loadSession(state);
      await expectLater(
        session.feedRun('while True: pass', printCallback: _ignore),
        throwsA(_timedOut('30ms')),
      );
    }, timeout: const Timeout(Duration(seconds: 5)));

    test("a load adopts the dump's turn budget, and none when the dump has "
        'none', () async {
      final ch = ScriptedChannel([
        _configureOk,
        expecting(pb.ParentRequest_Kind.load, [ok()]),
        hangAfter([]),
      ]);
      final pool = await _pool(
        Workers([ch]),
        requestTimeout: _ms(200),
        turnGrace: Duration.zero,
      );
      addTearDown(pool.close);
      final session = await pool.checkout(
        options: SessionConfig(
          limits: ResourceLimits(maxTurnDuration: _ms(20)),
        ),
      );
      await session.loadSession(state);
      // The session's 20 ms backstop went with the load; requestTimeout
      // is all that is left.
      await expectLater(
        session.feedRun('while True: pass', printCallback: _ignore),
        throwsA(_timedOut('200ms')),
      );
    });

    test('loadSnapshot keeps its host functions for resumeAuto, and the '
        "dump's script name", () async {
      final reannounced = _call('f')..restoredScriptName = 'dumped.py';
      final ch = ScriptedChannel([
        _configureOk,
        expecting(pb.ParentRequest_Kind.load, [reannounced]),
        expecting(pb.ParentRequest_Kind.resumeCall, [_int(5)]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final calls = <String>[];
      final snapshot =
          await session.loadSnapshot(
                state,
                externals: {
                  'f': (args, kwargs) {
                    calls.add('f');

                    return const MontyInt(4);
                  },
                },
                printCallback: _ignore,
              )
              as FunctionSnapshot;
      expect(snapshot.scriptName, 'dumped.py');
      expect(
        await snapshot.resumeAuto(),
        isA<SessionComplete>().having(
          (c) => c.output,
          'output',
          const MontyInt(5),
        ),
      );
      expect(calls, ['f']);
    });

    test("a restored FutureSnapshot's coroutines are gone: resumeAuto ends "
        'the session', () async {
      final ch = ScriptedChannel([
        _configureOk,
        expecting(pb.ParentRequest_Kind.load, [
          pb.ChildEvent(
            resolveFutures: pb.ResolveFutures(pendingCallIds: [1]),
          ),
        ]),
      ]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      final snapshot =
          await session.loadSnapshot(state, printCallback: _ignore)
              as FutureSnapshot;
      await expectLater(snapshot.resumeAuto(), throwsA(isA<StateError>()));
      expect(ch.kills, greaterThan(0));
      expect(pool.liveWorkers, 0);
    });

    test('a Dump or a Load answered out of turn kills the worker', () async {
      final dumping = ScriptedChannel([
        _configureOk,
        expecting(pb.ParentRequest_Kind.dump, [ok()]),
      ]);
      final loading = ScriptedChannel([
        _configureOk,
        expecting(pb.ParentRequest_Kind.load, [_int(1)]),
      ]);
      final pool = await _pool(Workers([dumping, loading]), maxProcesses: 2);
      addTearDown(pool.close);
      // One checkout per worker.
      final [a, b] = await Future.wait([
        for (var i = 0; i < 2; i++) pool.checkout(),
      ]);
      await expectLater(
        a.dump(),
        throwsA(_violation('unexpected reply to Dump: ok')),
      );
      await expectLater(
        b.loadSession(state),
        throwsA(_violation('unexpected reply to Load: complete')),
      );
      expect([dumping.kills, loading.kills], everyElement(greaterThan(0)));
      expect(pool.liveWorkers, 0);
    });

    test('workerPid: null for a channel with no process, and once '
        'finished', () async {
      final ch = ScriptedChannel([_configureOk, _resetOk]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      final session = await pool.checkout();
      expect(session.workerPid, isNull);
      await session.close();
      expect(session.workerPid, isNull);
      await expectLater(session.dump(), throwsA(_finished));
    });
  });
}
