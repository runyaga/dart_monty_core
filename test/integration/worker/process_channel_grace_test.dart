// Exact native timing contracts, with controlled process pipes and Zone time.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/worker/frame.dart' as wire;
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show CrashCause, MontyCrashedErrorInternal;
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

import '../../unit/worker/_channel_clock.dart';
import '../../unit/worker/_scripted_channel.dart';

final _feed = pb.ParentRequest(feed: pb.Feed(code: '1'));
const _millisecond = Duration(milliseconds: 1);

void main() {
  for (final run in [1, 2]) {
    for (final fatal in [true, false]) {
      test('${fatal ? 'fatal' : 'EOF'} allows exactly 100 ms (run $run)', () {
        final clock = ChannelClock();
        clock.run(() {
          final process = _Process();
          final channel = processChannelForTesting(process);
          final checked = expectLater(
            channel.turn(_feed),
            throwsA(
              isA<MontyCrashedError>().having(
                (error) => error.cause,
                'cause',
                fatal ? CrashCause.fatal : CrashCause.vanished,
              ),
            ),
          );
          unawaited(checked);
          clock.flush();
          if (fatal) {
            process.output.add(
              wire.Frame.encode(
                pb.ChildEvent(fatalError: pb.FatalError(message: 'fatal')),
              ),
            );
          } else {
            unawaited(process.output.close());
          }
          clock
            ..flush()
            ..elapse(const Duration(milliseconds: 99));
          expect(process.kills, 0);
          clock.elapse(_millisecond);
          expect(process.kills, 1);
          _finish(clock, process, channel);
        });
      });
    }
  }
  _drainTests();
  _resetTests();
  _oversizeTests();
  _exitStatusTests();
  _deadlineTests();
}

void _drainTests() {
  for (final failedSend in [false, true]) {
    test('${failedSend ? 'failed send' : 'exit'} '
        'drains for one second', () {
      final clock = ChannelClock();
      clock.run(() {
        final process = _Process()..stdin.failSend = failedSend;
        final channel = processChannelForTesting(process);
        final checked = expectLater(
          channel.turn(_feed),
          throwsA(
            isA<MontyCrashedError>(),
          ),
        );
        unawaited(checked);
        clock.flush();
        if (!failedSend) process.exited.complete(0);
        clock.flush();
        _expectListening(process, true);
        clock.elapse(const Duration(milliseconds: 999));
        _expectListening(process, true);
        clock.elapse(_millisecond);
        _expectListening(process, false);
        _finish(clock, process, channel);
      });
    });
  }
}

void _resetTests() {
  for (final run in [1, 2]) {
    test('Reset retains the already queued next reply (run $run)', () {
      final clock = ChannelClock();
      clock.run(() {
        final process = _Process();
        final channel = processChannelForTesting(process);
        process.output.add([
          ...wire.Frame.encode(ok()),
          ...wire.Frame.encode(
            printed([
              (pb.PrintStream.PRINT_STREAM_STDOUT, 'retained after Reset'),
            ]),
          ),
          ...wire.Frame.encode(completeNone()),
        ]);
        unawaited(
          expectLater(
            channel.turn(pb.ParentRequest(reset: pb.Reset())),
            completion(ok()),
          ),
        );
        clock.flush();
        final prints = <String>[];
        unawaited(
          expectLater(
            channel.turn(
              _feed,
              onPrint: (event) {
                prints.addAll(event.segments.map((segment) => segment.text));
              },
            ),
            completion(completeNone()),
          ),
        );
        clock.flush();
        expect(prints, ['retained after Reset']);
        _finish(clock, process, channel);
      });
    });
  }
}

void _oversizeTests() {
  for (final status in [17, 65]) {
    test(
      'oversized inbound frame with exit $status',
      () async {
        final process = _Process()..killStatus = status;
        final channel = processChannelForTesting(process);
        addTearDown(() async {
          channel.kill();
          await channel.close();
          await process.dispose();
        });
        await _oversizeSession(process, channel, status);
      },
    );
  }
}

Future<void> _oversizeSession(
  _Process process,
  ProcessChannel channel,
  int status,
) async {
  final pool = await startMonty(
    const PoolOptions(minProcesses: 0, maxProcesses: 1),
    open: () => PendingSpawn((_) async => channel),
  );
  process.stdin.answer = (_) => process.output.add(wire.Frame.encode(ok()));
  final session = await pool.checkout();
  process.stdin.answer = (_) => process.output.add([1, 0, 0, 16]);
  final Matcher error = status == 65
      ? isA<MontyRuntimeError>().having(
          (e) => e.exception.excType,
          'excType',
          'MemoryError',
        )
      : isA<MontyCrashedError>()
            .having((e) => e.exitStatus, 'exitStatus', 17)
            .having((e) => e.timedOut, 'timedOut', isFalse);
  await expectLater(session.feedRun('1'), throwsA(error));
  expect(process.kills, greaterThanOrEqualTo(1));
  expect(pool.liveWorkers, 0);
  await expectLater(session.feedRun('2'), throwsStateError);
  await session.close();
  await pool.close();
}

void _exitStatusTests() {
  test('an exit status during fatal grace is preserved', () {
    final clock = ChannelClock();
    clock.run(() {
      final process = _Process();
      final channel = processChannelForTesting(process);
      final checked = expectLater(
        channel.turn(_feed),
        throwsA(
          isA<MontyCrashedError>()
              .having((error) => error.cause, 'cause', CrashCause.fatal)
              .having((error) => error.exitStatus, 'exitStatus', 65),
        ),
      );
      unawaited(checked);
      clock.flush();
      process.output.add(
        wire.Frame.encode(
          pb.ChildEvent(fatalError: pb.FatalError(message: 'fatal')),
        ),
      );
      clock
        ..flush()
        ..elapse(const Duration(milliseconds: 99));
      process.exited.complete(65);
      clock.flush();
      expect(process.kills, 0);
      _finish(clock, process, channel);
    });
  });
}

void _deadlineTests() {
  for (final run in [1, 2, 3]) {
    test('deadline kills directly and wins over exit 65 (run $run)', () async {
      final clock = ChannelClock();
      final process = _Process()..killStatus = 65;
      final channel = processChannelForTesting(process);
      addTearDown(() async {
        channel.kill();
        await channel.close();
        await process.dispose();
      });
      final entered = Completer<void>();
      final finished = clock.runAsync(
        () => _deadlineSession(process, channel, entered),
      );
      await entered.future;
      clock.elapse(const Duration(milliseconds: 9));
      expect(process.kills, 0);
      clock.elapse(_millisecond);
      expect(process.kills, 1);
      await finished;
    });
  }
}

Future<void> _deadlineSession(
  _Process process,
  ProcessChannel channel,
  Completer<void> entered,
) async {
  final pool = await startMonty(
    const PoolOptions(
      minProcesses: 0,
      maxProcesses: 1,
      requestTimeout: Duration(milliseconds: 10),
    ),
    open: () => PendingSpawn((_) async => channel),
  );
  process.stdin.answer = (_) => process.output.add(wire.Frame.encode(ok()));
  final session = await pool.checkout();
  process.stdin.answer = (_) => entered.complete();
  await expectLater(
    session.feedRun('while True: pass'),
    throwsA(
      isA<MontyCrashedError>()
          .having((e) => e.timedOut, 'timedOut', isTrue)
          .having((e) => e.exitStatus, 'exitStatus', isNull)
          .having((e) => e.cause, 'cause', CrashCause.killed),
    ),
  );
  expect(pool.liveWorkers, 0);
  await session.close();
  await pool.close();
}

void _finish(ChannelClock clock, _Process process, ProcessChannel channel) {
  channel.kill();
  unawaited(channel.close());
  unawaited(process.dispose());
  clock
    ..flush()
    ..elapse(const Duration(seconds: 2));
  expect(ProcessChannel.live, isNot(contains(channel)));
}

final class _Sink implements IOSink {
  bool failSend = false;
  void Function(List<int>)? answer;
  final _closed = Completer<void>();

  @override
  Future<void> get done => _closed.future;

  @override
  void add(List<int> data) {
    if (failSend) throw const SocketException('Broken pipe');
    answer?.call(data);
  }

  @override
  Future<void> flush() async => answer;

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete();
  }

  @override
  Never noSuchMethod(Invocation invocation) => throw UnsupportedError(
    'Unexpected sink call ${invocation.memberName}',
  );
}

final class _Process implements Process {
  final output = StreamController<List<int>>(sync: true);
  final exited = Completer<int>();
  @override
  final _Sink stdin = _Sink();
  int kills = 0;
  int killStatus = -9;

  Future<void> dispose() async {
    await stdin.close();
    await output.close();
  }

  @override
  Stream<List<int>> get stdout => output.stream;

  @override
  Stream<List<int>> get stderr => const Stream.empty();

  @override
  int get pid => 4242;

  @override
  Future<int> get exitCode => exited.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    kills++;
    if (!exited.isCompleted) exited.complete(killStatus);
    scheduleMicrotask(() => unawaited(output.close()));

    return true;
  }
}

void _expectListening(_Process process, bool expected) {
  expect(process.output.hasListener, expected);
}
