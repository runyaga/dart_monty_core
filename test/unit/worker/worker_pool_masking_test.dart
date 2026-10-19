import 'dart:async';

import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show MontyCrashedErrorInternal;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/suppressed_failures.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

final class _FakeChannel implements MontyChannel {
  _FakeChannel({this.onClose, this.onKill});

  final FutureOr<void> Function()? onClose;
  final void Function()? onKill;
  int closeCalls = 0;
  int killCalls = 0;

  @override
  bool get isAlive => true;

  @override
  Future<pb.ChildEvent> turn(
    pb.ParentRequest request, {
    PrintHandler? onPrint,
  }) => Completer<pb.ChildEvent>().future;

  @override
  Future<void> close() async {
    closeCalls++;
    await onClose?.call();
  }

  @override
  void kill() {
    killCalls++;
    onKill?.call();
  }
}

final class _FakeHandle implements SpawnHandle {
  _FakeHandle(this.ready, {this.onCancel});

  @override
  final Future<MontyChannel> ready;

  final void Function()? onCancel;
  int cancelCalls = 0;

  @override
  void cancel() {
    cancelCalls++;
    onCancel?.call();
  }
}

Matcher _isStateError(String message) =>
    isA<StateError>().having((err) => err.message, 'message', message);

/// A suppressed-failure entry at [stage] holding a StateError with [message],
/// and, when [withStack], a non-empty stack.
Matcher _suppressed(String stage, String message, {bool withStack = false}) {
  final entry = isA<SuppressedFailure>()
      .having((failure) => failure.stage, 'stage', stage)
      .having((failure) => failure.error, 'error', _isStateError(message));

  return withStack
      ? entry.having(
          (failure) => failure.stack.toString(),
          'stack',
          isNotEmpty,
        )
      : entry;
}

Matcher _isKilledCrash() => isA<MontyCrashedError>().having(
  (err) => err.cause,
  'cause',
  CrashCause.killed,
);

void main() {
  setUp(SuppressedFailures.clear);
  tearDown(SuppressedFailures.clear);

  group('Unit 2a.5 cleanup masking fixes', () {
    test(
      'throwing cancel during factory rollback keeps primary error and cancels '
      'every handle',
      () async {
        final uncaught = <Object>[];
        final done = Completer<void>();
        late _FakeHandle handle0;
        late _FakeHandle handle1;
        Object? primaryError;

        unawaited(
          runZonedGuarded(
            () async {
              try {
                final pending0 = Completer<MontyChannel>();
                final pending1 = Completer<MontyChannel>();
                handle0 = _FakeHandle(
                  pending0.future,
                  onCancel: () => throw StateError('cancel handle0 boom'),
                );
                handle1 = _FakeHandle(pending1.future);
                var calls = 0;

                await WorkerPool.start(
                  const PoolOptions(minProcesses: 3, maxProcesses: 3),
                  () => switch (calls++) {
                    0 => handle0,
                    1 => handle1,
                    _ => throw StateError('primary open failure'),
                  },
                );
              } on Object catch (error) {
                primaryError = error;
              } finally {
                done.complete();
              }
            },
            (error, _) => uncaught.add(error),
          ),
        );
        await done.future;

        expect(primaryError, _isStateError('primary open failure'));
        expect(handle0.cancelCalls, 1);
        expect(handle1.cancelCalls, 1);
        expect(uncaught, isEmpty);

        final [entry] = SuppressedFailures.entries;
        expect(entry.error, _isStateError('cancel handle0 boom'));
        expect(entry.stage, 'worker_pool.open_rollback.cancel');
      },
    );

    test(
      'throwing close and throwing cancel during startup keep primary error '
      'and record suppressed failures',
      () async {
        final uncaught = <Object>[];
        final done = Completer<void>();
        late _FakeChannel channel0;
        late _FakeChannel channel1;
        late _FakeHandle handle3;
        late _FakeHandle handle4;
        Object? primaryError;

        unawaited(
          runZonedGuarded(
            () async {
              try {
                channel0 = _FakeChannel(
                  onClose: () => Future<void>.error(
                    StateError('close channel0 boom'),
                    StackTrace.current,
                  ),
                );
                channel1 = _FakeChannel();
                final primaryFailure = Completer<MontyChannel>();
                final pending3 = Completer<MontyChannel>();
                final pending4 = Completer<MontyChannel>();

                final handle0 = _FakeHandle(
                  Future<MontyChannel>.value(channel0),
                );
                final handle1 = _FakeHandle(
                  Future<MontyChannel>.value(channel1),
                );
                final handle2 = _FakeHandle(primaryFailure.future);
                handle3 = _FakeHandle(
                  pending3.future,
                  onCancel: () {
                    pending3.completeError(
                      StateError('losing sibling 3'),
                      StackTrace.current,
                    );
                    throw StateError('cancel handle3 boom');
                  },
                );
                handle4 = _FakeHandle(
                  pending4.future,
                  onCancel: () {
                    pending4.completeError(
                      StateError('losing sibling 4'),
                      StackTrace.current,
                    );
                  },
                );
                var index = 0;

                Timer.run(
                  () => primaryFailure.completeError(
                    StateError('primary start failure'),
                    StackTrace.current,
                  ),
                );
                primaryError = await _errorOf(
                  WorkerPool.start(
                    const PoolOptions(minProcesses: 5, maxProcesses: 5),
                    () => switch (index++) {
                      0 => handle0,
                      1 => handle1,
                      2 => handle2,
                      3 => handle3,
                      _ => handle4,
                    },
                  ),
                );
              } finally {
                done.complete();
              }
            },
            (error, _) => uncaught.add(error),
          ),
        );
        await done.future;

        expect(primaryError, _isStateError('primary start failure'));
        expect(channel0.closeCalls, 1);
        expect(channel1.closeCalls, 1);
        expect(handle3.cancelCalls, 1);
        expect(handle4.cancelCalls, 1);
        expect(uncaught, isEmpty);

        final entries = SuppressedFailures.entries;
        expect(entries, hasLength(4));
        expect(
          entries,
          unorderedMatches(<Matcher>[
            _suppressed(
              'worker_pool.start_cleanup.cancel',
              'cancel handle3 boom',
              withStack: true,
            ),
            _suppressed(
              'worker_pool.start_cleanup.close',
              'close channel0 boom',
              withStack: true,
            ),
            _suppressed(
              'worker_pool.start_cleanup.sibling_start',
              'losing sibling 3',
            ),
            _suppressed(
              'worker_pool.start_cleanup.sibling_start',
              'losing sibling 4',
            ),
          ]),
        );
      },
    );

    test(
      'throwing cancel on startup timeout keeps primary crashedError',
      () async {
        final uncaught = <Object>[];
        final done = Completer<void>();
        late _FakeHandle handle;
        Object? primaryError;

        unawaited(
          runZonedGuarded(
            () async {
              try {
                final neverReady = Completer<MontyChannel>();
                handle = _FakeHandle(
                  neverReady.future,
                  onCancel: () => throw StateError('timeout cancel boom'),
                );

                await WorkerPool.start(
                  const PoolOptions(maxProcesses: 1),
                  () => handle,
                  const Duration(milliseconds: 20),
                );
              } on Object catch (error) {
                primaryError = error;
              } finally {
                done.complete();
              }
            },
            (error, _) => uncaught.add(error),
          ),
        );
        await done.future;

        expect(primaryError, _isKilledCrash());
        expect(handle.cancelCalls, 1);
        expect(uncaught, isEmpty);

        final [entry] = SuppressedFailures.entries;
        expect(entry.error, _isStateError('timeout cancel boom'));
        expect(entry.stage, 'worker_pool.startup_timeout.cancel');
      },
    );

    test(
      'a late start failure after cancel is recorded without unhandled zone '
      'error',
      () async {
        final uncaught = <Object>[];
        final done = Completer<void>();
        Object? readyError;

        unawaited(
          runZonedGuarded(
            () async {
              final startCompleter = Completer<MontyChannel>();
              final handle = PendingSpawn((_) => startCompleter.future)
                ..cancel();
              try {
                await handle.ready;
              } on Object catch (error) {
                readyError = error;
              } finally {
                startCompleter.completeError(
                  StateError('late start boom'),
                  StackTrace.current,
                );
                await Future<void>.delayed(Duration.zero);
                done.complete();
              }
            },
            (error, _) => uncaught.add(error),
          ),
        );
        await done.future;

        expect(readyError, _isKilledCrash());
        expect(uncaught, isEmpty);

        final [entry] = SuppressedFailures.entries;
        expect(entry.error, _isStateError('late start boom'));
        expect(entry.stage, 'pending_spawn.late_start');
      },
    );

    test(
      'a late throwing kill after cancel is recorded without unhandled zone '
      'error',
      () async {
        final uncaught = <Object>[];
        final done = Completer<void>();
        late _FakeChannel lateChannel;
        Object? readyError;

        unawaited(
          runZonedGuarded(
            () async {
              final startCompleter = Completer<MontyChannel>();
              lateChannel = _FakeChannel(
                onKill: () => throw StateError('late kill boom'),
              );
              final handle = PendingSpawn((_) => startCompleter.future)
                ..cancel();
              try {
                await handle.ready;
              } on Object catch (error) {
                readyError = error;
              } finally {
                startCompleter.complete(lateChannel);
                await Future<void>.delayed(Duration.zero);
                done.complete();
              }
            },
            (error, _) => uncaught.add(error),
          ),
        );
        await done.future;

        expect(readyError, _isKilledCrash());
        expect(lateChannel.killCalls, 1);
        expect(uncaught, isEmpty);

        final [entry] = SuppressedFailures.entries;
        expect(entry.error, _isStateError('late kill boom'));
        expect(entry.stage, 'pending_spawn.late_kill');
      },
    );

    test(
      'a throwing kill on cancel after ready is recorded without unhandled '
      'zone error',
      () async {
        final uncaught = <Object>[];
        final done = Completer<void>();
        late _FakeChannel readyChannel;
        Object? cancelError;

        unawaited(
          runZonedGuarded(
            () async {
              readyChannel = _FakeChannel(
                onKill: () => throw StateError('cancel kill boom'),
              );
              final handle = PendingSpawn(
                (_) => Future<MontyChannel>.value(readyChannel),
              );
              try {
                await handle.ready;
                handle.cancel();
              } on Object catch (error) {
                cancelError = error;
              } finally {
                done.complete();
              }
            },
            (error, _) => uncaught.add(error),
          ),
        );
        await done.future;

        expect(cancelError, isNull);
        expect(readyChannel.killCalls, 1);
        expect(uncaught, isEmpty);

        final [entry] = SuppressedFailures.entries;
        expect(entry.error, _isStateError('cancel kill boom'));
        expect(entry.stage, 'pending_spawn.cancel.kill');
      },
    );

    test('SuppressedFailures bounds capacity at 256 and counts drops', () {
      for (var i = 0; i < 260; i++) {
        SuppressedFailures.record(
          StateError('err $i'),
          StackTrace.empty,
          'stage.$i',
        );
      }

      final entries = SuppressedFailures.entries;
      expect(entries, hasLength(SuppressedFailures.capacity));
      expect(SuppressedFailures.droppedCount, 4);
      final [first, ..., last] = entries;
      expect(first.stage, 'stage.4');
      expect(last.stage, 'stage.259');

      SuppressedFailures.clear();
      expect(SuppressedFailures.entries, isEmpty);
      expect(SuppressedFailures.droppedCount, 0);
    });
  });
}

/// The error [future] completes with, or null when it succeeds.
Future<Object?> _errorOf(Future<Object?> future) async {
  try {
    await future;
  } on Object catch (error) {
    return error;
  }

  return null;
}
