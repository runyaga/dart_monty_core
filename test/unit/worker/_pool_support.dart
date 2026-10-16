// Shared protocol fixtures and controlled deadlines for the pool spec tests.
// Timer callbacks are fired explicitly: no wall-clock timing assertions.
import 'dart:async';
import 'dart:collection';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/telemetry_channel.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../_accessors.dart';
import '_scripted_channel.dart';

final Reply configurePool = expecting(pb.ParentRequest_Kind.configure, [ok()]);
final Reply resetPool = expecting(pb.ParentRequest_Kind.reset, [ok()]);
final Matcher spentPool = throwsA(
  isA<StateError>().having(
    (e) => e.message,
    'message',
    'snapshot has already been resumed',
  ),
);
final Matcher finishedPool = throwsA(
  isA<StateError>().having(
    (e) => e.message,
    'message',
    'the session is finished',
  ),
);

Matcher runtimePool(String type, String message) => isA<MontyRuntimeError>()
    .having((e) => e.exception.excType, 'exception type', type)
    .having((e) => e.exception.message, 'message', message);

pb.ChildEvent poolCall() => pb.ChildEvent(
  functionCall: pb.FunctionCall(functionName: 'f', callId: 1),
);

pb.ChildEvent poolOs() => pb.ChildEvent(
  osCall: pb.OsCall(callId: 1, readText: '/sample'),
);

Future<Monty> poolWith(
  List<MontyChannel> channels, {
  PoolOptions options = const PoolOptions(minProcesses: 0, maxProcesses: 1),
}) async {
  final next = Queue.of(channels);
  final pool = await startMonty(
    options,
    open: () => PendingSpawn((_) async => next.removeFirst()),
  );
  addTearDown(pool.close);

  return pool;
}

/// A turn whose completion remains under the test's control after kill.
/// This models transport work stuck in user print delivery.
final class HeldPoolChannel with RecordedChannel implements MontyChannel {
  HeldPoolChannel({this.holdConfigure = false});

  final bool holdConfigure;
  final Completer<void> entered = Completer();
  final Completer<pb.ChildEvent> reply = Completer();
  final List<pb.ParentRequest_Kind> requests = [];
  int kills = 0;
  int closes = 0;

  @override
  bool get isAlive => kills == 0 && closes == 0;

  @override
  Future<pb.ChildEvent> turn(
    pb.ParentRequest request, {
    PrintHandler? onPrint,
  }) async {
    final kind = request.whichKind();
    requests.add(kind);
    if ((kind == pb.ParentRequest_Kind.configure && !holdConfigure) ||
        kind == pb.ParentRequest_Kind.reset) {
      return ok();
    }
    entered.complete();

    return reply.future;
  }

  @override
  void kill() => kills++;

  @override
  Future<void> close() async => closes++;
}

/// Captures positive one-shot timers without scheduling wall-clock work.
final class PoolTimers {
  final List<PoolTimer> timers = [];

  List<Duration> get active => [
    for (final timer in timers)
      if (timer.isActive) timer.duration,
  ];

  Future<void> run(Future<void> Function() body) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      createTimer: (self, parent, zone, duration, callback) {
        if (duration <= Duration.zero) {
          return parent.createTimer(zone, duration, callback);
        }
        final timer = PoolTimer(duration, zone.bindCallback(callback));
        timers.add(timer);

        return timer;
      },
    ),
  );

  void fire() {
    final pending = timers.where((timer) => timer.isActive).toList();
    expect(pending, hasLength(1), reason: 'exactly one enabled deadline');
    onlyItem(pending).fire();
  }
}

final class PoolTimer implements Timer {
  PoolTimer(this.duration, this._callback);

  final Duration duration;
  final void Function() _callback;
  bool _isActive = true;
  int _tick = 0;

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _tick;

  @override
  void cancel() => _isActive = false;

  void fire() {
    if (!_isActive) throw StateError('timer is inactive');
    _isActive = false;
    _tick++;
    _callback();
  }
}
