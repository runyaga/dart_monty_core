// Deadlines from behaviour/pool-and-lifetimes.md, using virtual timer firing.
import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:fixnum/fixnum.dart';
import 'package:test/test.dart';

import '_pool_support.dart';
import '_scripted_channel.dart';

const _seconds = Duration(seconds: 1);
const _limits = ResourceLimits(
  maxFeedDuration: Duration(seconds: 10),
  maxTurnDuration: Duration(seconds: 4),
);
final Matcher _expired = throwsA(
  isA<MontyCrashedError>().having((e) => e.timedOut, 'timedOut', isTrue),
);

pb.ChildEvent _suspension(String kind) => (switch (kind) {
  'call' => poolCall(),
  'lookup' => pb.ChildEvent(nameLookup: pb.NameLookup(name: 'x')),
  'futures' => pb.ChildEvent(
    resolveFutures: pb.ResolveFutures(
      pendingCallIds: [1],
    ),
  ),
  _ => throw ArgumentError.value(kind),
})..feedExecutionMicros = Int64(4000000);

Future<MontySnapshot> _execute(MontySession session, String kind) async {
  final started = session.feedStart('x');
  if (kind == 'feed') return started;
  final snapshot = await started;

  return switch (snapshot) {
    FunctionSnapshot() => snapshot.resume(
      const ExternalReturnValue(MontyNone()),
    ),
    NameLookupSnapshot() => snapshot.resume(value: const MontyInt(1)),
    FutureSnapshot() => snapshot.resume({
      1: const ExternalReturnValue(MontyInt(1)),
    }),
    _ => throw StateError('expected a suspension'),
  };
}

Future<void> _deadline(
  String kind,
  Duration? request,
  Duration? feedGrace,
  Duration? turnGrace,
  Duration? expected,
) async {
  final timers = PoolTimers();
  await timers.run(() async {
    final channel = ScriptedChannel([
      configurePool,
      if (kind != 'feed') answer([_suspension(kind)]),
      hangAfter([]),
    ]);
    final pool = await poolWith(
      [channel],
      options: PoolOptions(
        minProcesses: 0,
        maxProcesses: 1,
        requestTimeout: request,
        feedDurationLimitGrace: feedGrace,
        turnDurationLimitGrace: turnGrace,
      ),
    );
    final session = await pool.checkout(limits: _limits);
    final failed = expectLater(
      _execute(session, kind),
      expected == null ? throwsA(isA<MontyCrashedError>()) : _expired,
    );
    await pumpEventQueue();
    expect(timers.active, expected == null ? <Duration>[] : [expected]);
    if (expected == null) {
      await session.close();
    } else {
      timers.fire();
    }
    await failed;
    expect(channel.isAlive, isFalse);
    expect(pool.liveWorkers, 0);
  });
}

Future<void> _nonExecution(String kind) async {
  final timers = PoolTimers();
  await timers.run(() async {
    final channel = ScriptedChannel([configurePool, hangAfter([])]);
    final pool = await poolWith(
      [channel],
      options: const PoolOptions(
        minProcesses: 0,
        maxProcesses: 1,
        requestTimeout: Duration(seconds: 20),
        feedDurationLimitGrace: Duration.zero,
        turnDurationLimitGrace: Duration.zero,
      ),
    );
    final session = await pool.checkout(limits: _limits);
    final Future<void> outcome;
    if (kind == 'reset') {
      outcome = session.close();
    } else {
      final work = kind == 'load'
          ? session.loadSession(Uint8List.fromList([1]))
          : session.dump();
      outcome = expectLater(work, _expired);
    }
    await pumpEventQueue();
    expect(timers.active, [const Duration(seconds: 20)]);
    timers.fire();
    await outcome;
    expect(channel.isAlive, isFalse);
  });
}

void main() {
  for (final kind in ['feed', 'call', 'lookup', 'futures']) {
    for (final (label, request, feedGrace, turnGrace, expected) in [
      (
        'request wins',
        const Duration(seconds: 2),
        _seconds,
        _seconds,
        const Duration(seconds: 2),
      ),
      (
        'feed wins',
        const Duration(seconds: 20),
        _seconds,
        const Duration(seconds: 20),
        Duration(seconds: kind == 'feed' ? 11 : 7),
      ),
      (
        'turn wins',
        const Duration(seconds: 20),
        _seconds,
        _seconds,
        const Duration(seconds: 5),
      ),
      ('null graces disable backstops', null, null, null, null),
    ]) {
      test(
        '$kind $label',
        () => _deadline(kind, request, feedGrace, turnGrace, expected),
      );
    }
  }
  for (final kind in ['load', 'dump', 'reset']) {
    test(
      '$kind uses only requestTimeout',
      () => _nonExecution(kind),
    );
  }
  test(
    'a new feed forgets previous execution time',
    () async {
      final timers = PoolTimers();
      await timers.run(() async {
        final channel = ScriptedChannel([
          configurePool,
          answer([completeNone()..feedExecutionMicros = Int64(99000000)]),
          hangAfter([]),
        ]);
        final pool = await poolWith(
          [channel],
          options: const PoolOptions(
            minProcesses: 0,
            maxProcesses: 1,
            turnDurationLimitGrace: null,
          ),
        );
        final session = await pool.checkout(limits: _limits);
        expect(await session.feedRun('first'), const MontyNone());
        final failed = expectLater(session.feedRun('second'), _expired);
        await pumpEventQueue();
        expect(timers.active, [const Duration(seconds: 11)]);
        timers.fire();
        await failed;
      });
    },
  );
  test(
    'capacity timeout excludes startup '
    'and Configure',
    () async {
      final timers = PoolTimers();
      await timers.run(() async {
        final arrival = Completer<HeldPoolChannel>();
        final channel = HeldPoolChannel(holdConfigure: true);
        final pool = await startMonty(
          const PoolOptions(
            minProcesses: 0,
            maxProcesses: 1,
            checkoutTimeout: Duration(seconds: 1),
            requestTimeout: Duration(seconds: 5),
          ),
          open: () => PendingSpawn((_) => arrival.future),
        );
        addTearDown(pool.close);
        final checking = pool.checkout();
        await pumpEventQueue();
        expect(timers.active, [const Duration(seconds: 30)]);
        arrival.complete(channel);
        await channel.entered.future;
        expect(timers.active, [const Duration(seconds: 5)]);
        final failed = expectLater(checking, _expired);
        timers.fire();
        await failed;
        expect(channel.isAlive, isFalse);
        expect(pool.liveWorkers, 0);
        channel.reply.complete(ok());
      });
    },
  );
}
