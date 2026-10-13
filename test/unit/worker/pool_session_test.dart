// MontyPool and its sessions (lib/src/worker/monty_pool.dart,
// pool_session.dart) over scripted workers: checkout and Configure, feedRun,
// print delivery in order, idle close and Reset, close during host code,
// requestTimeout and the duration backstops on turns only, the memory-limit
// exit, and the scoped helpers. No worker runs. Pure Dart: vm, dart2js and
// dart2wasm.
import 'dart:async';
import 'dart:collection';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/pool_session.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/proto_session.dart';
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

/// What a test passes as `printCallback` when it does not look at prints.
void _ignore(String stream, String text) => _ignored++;

/// How many prints [_ignore] dropped; never looked at.
var _ignored = 0;

Matcher _crashed(CrashCause cause, [Object? message]) =>
    isA<MontyCrashedError>()
        .having((e) => e.cause, 'cause', cause)
        .having((e) => e.message, 'message', message ?? anything);

final Matcher _finished = isA<StateError>().having(
  (e) => e.message,
  'message',
  contains('finished'),
);

void main() {
  group('checkout', () {
    test('sends Configure with the name, limits and knobs', () async {
      final ch = ScriptedChannel([_configureOk]);
      final pool = await _pool(Workers([ch]));
      addTearDown(pool.close);
      await pool.checkout(
        scriptName: 'case.py',
        limits: const SessionLimits(
          maxMemoryBytes: 1 << 24,
          maxRecursionDepth: 50,
          maxFeedDuration: Duration(milliseconds: 1500),
          maxTurnDuration: Duration(milliseconds: 250),
        ),
        assertMessageAnnotations: 0,
        printFlushInterval: const Duration(milliseconds: 5),
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
        throwsA(_crashed(CrashCause.killed, contains('Configure'))),
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
        throwsA(_crashed(CrashCause.killed, contains('no reply within'))),
      );
      expect(pool.liveWorkers, 0);
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
          isA<MontyScriptError>().having(
            (e) => e.excType,
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

    test('a second call while one runs throws StateError', () async {
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
        throwsA(isA<StateError>()),
      );
      release.complete(const MontyNone());
      expect(await first, const MontyNone());
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

    test('a throwing callback kills the worker, frees the slot', () async {
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
      await expectLater(
        session.feedRun(
          'print("x")',
          printCallback: (stream, text) async => throw StateError('sink'),
        ),
        throwsA(
          isA<StateError>().having((e) => e.message, 'message', 'sink'),
        ),
      );
      expect(ch.kills, greaterThan(0));
      expect(pool.liveWorkers, 0);
      await expectLater(
        session.feedRun('1', printCallback: _ignore),
        throwsA(_finished),
      );
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

    test('during host code: Reset now; the drive fails later', () async {
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
      await session.close();
      // Reset went out while the callback still ran, and the worker is back.
      expect(_lastKind(ch), pb.ParentRequest_Kind.reset);
      final sent = ch.requests.length;
      expect(pool.idleWorkers, 1);
      expect(ch.kills, 0);
      release.complete(const MontyInt(1));
      await expectLater(run, throwsA(_finished));
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
        throwsA(_crashed(CrashCause.killed, contains('0:00:00.040000'))),
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
        throwsA(_crashed(CrashCause.killed, contains('no reply within'))),
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
        limits: const SessionLimits(
          maxFeedDuration: Duration(milliseconds: 200),
        ),
      );
      await expectLater(
        session.feedRun(
          'f()',
          externals: {'f': (args, kwargs) => const MontyNone()},
          printCallback: _ignore,
        ),
        // 200 - 150 + 100.
        throwsA(_crashed(CrashCause.killed, contains('0:00:00.150000'))),
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
        limits: const SessionLimits(
          maxFeedDuration: Duration(milliseconds: 1),
          maxTurnDuration: Duration(milliseconds: 20),
        ),
      );
      await expectLater(
        session.feedRun('while True: pass', printCallback: _ignore),
        throwsA(_crashed(CrashCause.killed, contains('0:00:00.030000'))),
      );
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
          isA<MontyScriptError>()
              .having((e) => e.excType, 'excType', 'MemoryError')
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
        scriptName: 'scoped.py',
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
          minProcesses: 0,
          workerLocation: 'unused',
        ),
        throwsA(isA<StateError>().having((e) => e.message, 'm', 'body')),
      );
      final pool = seen ?? fail('withPool never ran its body');
      await expectLater(pool.checkout(), throwsA(isA<StateError>()));
    });

    test('withPool returns the body value', () async {
      expect(
        await MontyPool.withPool((pool) async => 7, minProcesses: 0),
        7,
      );
    });
  });
}
