// Pipe cleanup ownership for ProcessChannel.close.
//
// A worker that dies with a fatal error leaves its stdout open (a child
// inherited the pipe) while its stderr has ended. The close must join that
// cleanup -- the cancelled stdout subscription and the reap that drains the
// pipe -- before it completes, and it must leave neither a drain timer nor
// an unobserved error behind. The process, its streams and the clock are
// injected, so the test never waits for wall-clock time.
@Tags(['worker'])
@TestOn('vm')
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart' show MontyCrashedError;
import 'package:dart_monty_core/src/worker/frame.dart' as wire;
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show CrashCause, MontyCrashedErrorInternal;
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:test/test.dart';

/// The request the worker answers with a fatal error.
final _feed = pb.ParentRequest(feed: pb.Feed(code: '1'));

/// The fatal error the worker reports before it exits.
const _fatalMessage = 'the worker cannot continue';

/// The message the failed cancellation reports.
const _cancellationFailure = 'the stdout subscription was cancelled';

void main() {
  test('close joins pipe cleanup across fatal exit and cancellation', () {
    final clock = _Clock();
    final uncaught = <Object>[];
    clock.run(
      () {
        _fatalExit(clock);
        _busyClose(clock);
        _failedSend(clock);
        _failedCancellation(clock);
      },
      onUncaught: uncaught.add,
    );
    // The deadlines the closures left behind expire harmlessly.
    clock
      ..elapse(ProcessChannel.pipeDrainGrace)
      ..flush();
    expect(
      uncaught,
      isEmpty,
      reason: 'the cleanup must leave no unobserved error behind',
    );
  });
}

/// The worker dies with a fatal error and exit 65: its stdout stays open and
/// its stderr has ended.
void _fatalExit(_Clock clock) {
  final process = _FakeProcess();
  final channel = processChannelForTesting(process);
  addTearDown(process.dispose);
  final turn = channel.turn(_feed);
  _dieWithFatalError(process);
  _expectCrash(clock, turn, cause: CrashCause.fatal);
  _expectJoinedClose(clock, channel, process);
}

/// The close runs while a turn is still in flight, so it kills the worker and
/// must join the same cleanup.
void _busyClose(_Clock clock) {
  final process = _FakeProcess();
  final channel = processChannelForTesting(process);
  addTearDown(process.dispose);
  final turn = channel.turn(_feed);
  _dieWithFatalError(process);
  // The turn has not read its answer yet, so the channel is busy.
  final closing = channel.close();
  _expectCrash(clock, turn, cause: CrashCause.killed);
  _expectJoinedClose(clock, channel, process, closing: closing);
}

/// The request cannot be written, so the worker never received it.
void _failedSend(_Clock clock) {
  final process = _FakeProcess(failSend: true);
  final channel = processChannelForTesting(process);
  addTearDown(process.dispose);
  final turn = channel.turn(_feed);
  _dieWithFatalError(process);
  _expectCrash(clock, turn, cause: CrashCause.fatal);
  expect(
    process.written,
    isEmpty,
    reason: 'the request must not reach a worker that is gone',
  );
  _expectJoinedClose(clock, channel, process);
}

/// The cancellation of the stdout subscription fails: the failure must be
/// observed through the close future, not left in the uncaught-error zone.
void _failedCancellation(_Clock clock) {
  final process = _FakeProcess();
  final channel = processChannelForTesting(process);
  addTearDown(process.dispose);
  final turn = channel.turn(_feed);
  _dieWithFatalError(process);
  _expectCrash(clock, turn, cause: CrashCause.fatal);

  final outcome = _Outcome(channel.close());
  clock.flush();
  expect(
    outcome.settled,
    isFalse,
    reason: 'close must join the cancelled pipe, not finish before it',
  );
  process.releaseWithFailure();
  clock.flush();
  expect(
    outcome.settled,
    isTrue,
    reason: 'close must settle once the cancellation has failed',
  );
  expect(
    outcome.failure,
    isNotNull,
    reason:
        'the cancellation failure must be observed through the close '
        'future, not left unobserved',
  );
  expect(
    '${outcome.failure}',
    contains(_cancellationFailure),
    reason: 'the close must report the failure of the cancellation',
  );
}

/// The close must not complete before the cancelled subscription settles, and
/// it must leave no drain timer behind.
void _expectJoinedClose(
  _Clock clock,
  ProcessChannel channel,
  _FakeProcess process, {
  Future<void>? closing,
}) {
  final outcome = _Outcome(closing ?? channel.close());
  clock.flush();
  expect(
    process.cancelRequested,
    isTrue,
    reason: 'the close must have cancelled the stdout subscription',
  );
  expect(
    outcome.settled,
    isFalse,
    reason: 'close must join the cancelled pipe, not finish before it',
  );
  process.release();
  clock.flush();
  expect(
    outcome.settled,
    isTrue,
    reason: 'close must complete once the pipe is clean',
  );
  expect(outcome.failure, isNull, reason: 'close must not fail');
  expect(
    clock.pending,
    isEmpty,
    reason: 'no drain timer may survive the closed channel',
  );
  expect(
    ProcessChannel.live,
    isNot(contains(channel)),
    reason: 'the closed channel must not stay live',
  );
}

/// The turn must fail with the crash the worker earned.
void _expectCrash(
  _Clock clock,
  Future<pb.ChildEvent> turn, {
  required CrashCause cause,
}) {
  final fatal = expectLater(
    turn,
    throwsA(
      isA<MontyCrashedError>()
          .having((error) => error.cause, 'cause', cause)
          .having((error) => error.exitStatus, 'exitStatus', 65),
    ),
  );
  final outcome = _Outcome(fatal);
  clock.flush();
  expect(outcome.settled, isTrue, reason: 'the fatal assertion must settle');
  expect(
    outcome.failure,
    isNull,
    reason:
        'the worker must fail with the crash it earned: '
        '${outcome.failure}',
  );
}

/// The worker reports a fatal error and exits with 65: its stdout stays open
/// and its stderr has ended.
void _dieWithFatalError(_FakeProcess process) {
  process.output.add(
    wire.Frame.encode(
      pb.ChildEvent(fatalError: pb.FatalError(message: _fatalMessage)),
    ),
  );
  process.exited.complete(65);
  unawaited(process.errors.close());
}

/// The outcome of a future: whether it settled, and how it failed.
final class _Outcome {
  _Outcome(Future<void> future) {
    unawaited(_watch(future));
  }

  /// Whether the future has settled.
  bool settled = false;

  /// The error the future failed with, if it failed.
  Object? failure;

  Future<void> _watch(Future<void> future) async {
    try {
      await future;
      settled = true;
    } on Object catch (error) {
      failure = error;
      settled = true;
    }
  }
}

/// A worker process whose pipes are injected.
final class _FakeProcess implements Process {
  _FakeProcess({this.failSend = false}) {
    _stdin = _FakeSink(failSend: failSend);
  }

  /// Whether every write to stdin fails, as it does for a worker that is
  /// gone.
  final bool failSend;

  /// The worker's stdout: it stays open, as it does when a child inherited
  /// the pipe.
  late final StreamController<List<int>> output = StreamController<List<int>>(
    sync: true,
    onCancel: _onCancel,
  );

  /// The worker's stderr. Its cancellation finishes at once, in the zone of
  /// the test, so the clock owns it.
  late final StreamController<List<int>> errors = StreamController<List<int>>(
    sync: true,
    onCancel: _cancelAtOnce,
  );

  /// The worker's exit code.
  final exited = Completer<int>();

  late final _FakeSink _stdin;
  final _cancellation = Completer<void>();
  final _cancelRequested = Completer<void>();

  /// Whether the channel asked for the stdout subscription to be cancelled.
  bool get cancelRequested => _cancelRequested.isCompleted;

  /// The frames the channel wrote to stdin.
  List<List<int>> get written => _stdin.written;

  /// Let the cancelled subscription finish.
  void release() {
    if (!_cancellation.isCompleted) _cancellation.complete();
  }

  /// Let the cancelled subscription finish with a failure.
  void releaseWithFailure() {
    if (_cancellation.isCompleted) return;
    _cancellation.completeError(
      StateError(_cancellationFailure),
      StackTrace.current,
    );
  }

  /// Close the pipes.
  Future<void> dispose() async {
    release();
    await output.close();
    await errors.close();
    await _stdin.close();
  }

  @override
  int get pid => 4242;

  @override
  Stream<List<int>> get stdout => output.stream;

  @override
  Stream<List<int>> get stderr => errors.stream;

  @override
  IOSink get stdin => _stdin;

  @override
  Future<int> get exitCode => exited.future;

  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    if (!exited.isCompleted) exited.complete(-9);

    return true;
  }

  /// The cancellation of the stderr subscription finishes at once.
  Future<void> _cancelAtOnce() => Future.value();

  /// The cancellation of the stdout subscription waits for the test.
  Future<void>? _onCancel() {
    if (!_cancelRequested.isCompleted) _cancelRequested.complete();

    return _cancellation.future;
  }
}

/// The worker's stdin: it records the frames, and every write fails when
/// [failSend] is set.
final class _FakeSink implements IOSink {
  _FakeSink({this.failSend = false});

  /// Whether every write fails, as it does for a worker that is gone.
  final bool failSend;

  /// The frames the channel wrote.
  final written = <List<int>>[];

  /// The errors the channel reported.
  final reported = <Object>[];

  final _done = Completer<void>();
  Encoding _encoding = utf8;

  @override
  Encoding get encoding => _encoding;

  @override
  set encoding(Encoding value) => _encoding = value;

  @override
  Future<void> get done => _done.future;

  @override
  void add(List<int> data) {
    if (failSend) throw const SocketException('Broken pipe');
    written.add(data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    reported.add(error);
  }

  @override
  Future<void> addStream(Stream<List<int>> stream) => stream.forEach(add);

  @override
  Future<void> flush() async {
    if (failSend) throw const SocketException('Broken pipe');
  }

  @override
  Future<void> close() async {
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void write(Object? object) {
    add(utf8.encode('$object'));
  }

  @override
  void writeAll(Iterable<Object?> objects, [String separator = '']) {
    objects.forEach(write);
  }

  @override
  void writeln([Object? object = '']) {
    write(object);
  }

  @override
  void writeCharCode(int charCode) {
    add([charCode]);
  }
}

/// A clock for the channel's grace periods: it owns the zone's timers and
/// microtasks, so the test decides when a deadline passes.
final class _Clock {
  final _microtasks = Queue<void Function()>();
  final _timers = <_Timer>[];
  Duration _now = Duration.zero;

  /// Run [body] with time advanced only by [elapse]. An error that nothing
  /// observed is reported to [onUncaught], which the test inspects.
  void run(
    void Function() body, {
    required void Function(Object error) onUncaught,
  }) => runZoned(
    body,
    zoneSpecification: ZoneSpecification(
      scheduleMicrotask: (self, parent, zone, callback) {
        _microtasks.add(zone.bindCallback(callback));
      },
      createTimer: (self, parent, zone, duration, callback) {
        final timer = _Timer(_now + duration, zone.bindCallback(callback));
        _timers.add(timer);

        return timer;
      },
      handleUncaughtError: (self, parent, zone, error, stack) {
        onUncaught(error);
      },
    ),
  );

  /// The deadlines that have not passed yet.
  List<Duration> get pending => [
    for (final timer in _timers)
      if (timer.isActive) timer.at - _now,
  ];

  /// Complete all the work already queued, without advancing time.
  void flush() {
    while (_microtasks.isNotEmpty) {
      _microtasks.removeFirst()();
    }
  }

  /// Advance the clock, firing the deadlines that pass in order.
  void elapse(Duration duration) {
    final end = _now + duration;
    flush();
    for (;;) {
      final due =
          _timers.where((timer) => timer.isActive && timer.at <= end).toList()
            ..sort((first, second) => first.at.compareTo(second.at));
      final timer = due.firstOrNull;
      if (timer == null) break;
      _now = timer.at;
      timer.fire();
      flush();
    }
    _now = end;
  }
}

/// A timer of the controlled clock.
final class _Timer implements Timer {
  _Timer(this.at, this._callback);

  /// When the timer is due.
  final Duration at;

  final void Function() _callback;
  bool _isActive = true;
  int _tick = 0;

  /// Fire the timer, unless it was cancelled.
  void fire() {
    if (!_isActive) return;
    _isActive = false;
    _tick++;
    _callback();
  }

  @override
  bool get isActive => _isActive;

  @override
  int get tick => _tick;

  @override
  void cancel() => _isActive = false;
}
