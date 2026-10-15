/// The native channel: a worker process speaking framed monty-proto over its
/// stdin and stdout.
///
/// The process is spawned from plain Dart with `dart:io`, never from Rust
/// inside the VM, which would race the VM's own SIGCHLD handling.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/frame_scan.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:meta/meta.dart';

/// The worker's exit code when its allocator's hard limit is breached:
/// upstream's `OOM_EXIT_CODE`.
const int workerOomExitCode = 65;

/// A [MontyChannel] over a worker process's stdio.
///
/// Every channel is in [live] from spawn until its process has exited,
/// because Dart has no kill-on-drop: a channel that is never closed keeps
/// its worker running, and the worker's open pipes keep this process from
/// exiting.
final class ProcessChannel implements MontyChannel {
  ProcessChannel._(this._process)
    : _events = EventQueue(
        _process.stdout,
        limit: readAheadLimit,
        drainAllowance: drainAllowance,
        onDesync: () => _process.kill(ProcessSignal.sigkill),
      ),
      _stderr = _ByteTail(_process.stderr, 4096) {
    _live.add(this);
    unawaited(_reapOnExit());
    unawaited(_absorbFailure(_process.stdin.done));
  }

  /// How long a worker that ended its output may take to exit before it is
  /// killed: upstream's `FATAL_EXIT_GRACE`.
  ///
  /// Long enough that an exit code such as 65 is read, not overwritten by
  /// the kill's signal.
  static const Duration fatalExitGrace = Duration(milliseconds: 100);

  /// How long, after the worker exits, each of its pipes may take to end
  /// before this channel stops listening to it.
  ///
  /// The exit code can arrive before the last of the output, so the
  /// channel waits; a process that inherited a pipe can hold it open
  /// forever, so the wait is bounded.
  static const Duration pipeDrainGrace = Duration(seconds: 1);

  /// How long [close] waits for the worker to exit after `Shutdown`:
  /// upstream's `SHUTDOWN_EXIT_GRACE`.
  static const Duration shutdownGrace = Duration(milliseconds: 500);

  /// How many wire bytes of completed, undelivered frames the channel holds
  /// before it stops reading the worker's stdout.
  ///
  /// The bound holds whether or not a turn is reading: during a turn,
  /// between turns, and while the caller holds a snapshot. The pipe then
  /// fills and the worker blocks on its write, as upstream's pool, which
  /// reads on demand, makes it. The frame being received when the limit is
  /// passed still completes, whatever its size up to [Frame.maxLength]:
  /// pausing inside it would deadlock a valid large result.
  static const int readAheadLimit = 4 * 1024 * 1024;

  /// How far past [readAheadLimit] the channel reads once the worker has
  /// exited or a request could not be sent: room for what a pipe holds.
  ///
  /// Reading what is left lets the frames a dead worker wrote last (a
  /// `FatalError`, a turn's end) arrive; the allowance keeps a process that
  /// inherited stdout and keeps writing from growing the queue without
  /// bound.
  static const int drainAllowance = 1024 * 1024;

  static final Set<ProcessChannel> _live = {};

  /// Every channel whose worker process has not yet exited.
  static Set<ProcessChannel> get live => UnmodifiableSetView(_live);

  final Process _process;
  final EventQueue _events;
  final _ByteTail _stderr;
  MontyCrashedError? _crash;
  bool _killed = false;

  /// Whether the request in flight is not yet all written, or could not
  /// be: a worker found gone then was lost while sending it (upstream's
  /// context).
  bool _unsent = false;
  bool _closed = false;
  bool _busy = false;
  bool _exited = false;
  Future<void>? _closing;

  /// Starts a worker as [launch] describes.
  ///
  /// The worker gets an empty environment, plus `SystemRoot` on Windows (see
  /// [workerEnvironment]). Throws [ProcessException] if it cannot start.
  static Future<ProcessChannel> spawn(WorkerLaunch launch) async {
    final (path, args) = launchCommand(launch);
    final process = await Process.start(
      path,
      args,
      environment: workerEnvironment(
        isWindows: Platform.isWindows,
        parent: Platform.environment,
      ),
      includeParentEnvironment: false,
    );

    return ProcessChannel._(process);
  }

  /// The worker's process id.
  int get pid => _process.pid;

  /// Completes with the worker's exit code.
  Future<int> get exitCode => _process.exitCode;

  /// Wire bytes of the frames received and not yet read by a turn: `now`,
  /// and the most it has been, `peak`; and whether reading the worker's
  /// stdout is `paused` at the limit.
  @visibleForTesting
  ({int now, int peak, bool paused}) get readAhead => (
    now: _events.readAhead,
    peak: _events.peakReadAhead,
    paused: _events._subscription?.isPaused ?? false,
  );

  @override
  bool get isAlive =>
      _crash == null && !_closed && !_killed && !_exited && _events.isOpen;

  @override
  Future<pb.ChildEvent> turn(
    pb.ParentRequest request, {
    PrintHandler? onPrint,
  }) async {
    if (_busy) {
      throw StateError('ProcessChannel.turn: a turn is already in flight');
    }
    final crash = _crash;
    if (crash != null) throw crash;
    if (_closed) throw StateError('ProcessChannel.turn: channel is closed');
    final frame = Frame.encode(request);
    _busy = true;
    try {
      final stdin = _process.stdin;
      // The add is synchronous, so the frame is queued at once. Until it
      // is all written the request counts as unsent, as upstream sends a
      // request whole before it reads: a worker lost meanwhile was lost
      // while sending it.
      _unsent = true;
      final written = () async {
        final sent = await _written(isAlive, stdin, frame);
        _unsent = !sent;

        return sent;
      }();
      unawaited(_endOutputIfUnsent(written, _events));
      // Read while the request is still being written: a worker paused on
      // a full stdout reads no stdin until the parent reads again, so a
      // request larger than the pipe would otherwise never be sent. A
      // request that was not sent ends the turn as a crash, whatever was
      // read.
      final event = await _readTurn(onPrint);

      // _flushed catches every failure, so nothing can go uncaught here.
      // ignore: avoid-uncaught-future-errors
      return await written ? event : throw await _crashed();
    } finally {
      _busy = false;
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  @override
  void kill() {
    if (_killed) return;
    _killed = true;
    _process.kill(ProcessSignal.sigkill);
    _events.cancel();
  }

  /// Reads events up to the turn's end, handing each `Print` to [onPrint]
  /// and awaiting it before reading on: while it waits, the read-ahead
  /// fills to [readAheadLimit] and the worker then blocks on its write.
  ///
  /// An [onPrint] that throws does not desynchronise the stream: the rest
  /// of the turn is still read, then its first error is rethrown.
  Future<pb.ChildEvent> _readTurn(PrintHandler? onPrint) async {
    (Object, StackTrace)? printFailure;
    for (;;) {
      final event = await _nextEvent(this);
      if (event == null) throw await _crashed();
      final kind = event.whichKind();
      if (kind == pb.ChildEvent_Kind.fatalError) {
        throw await _crashed(fatal: event.fatalError.message);
      }
      if (kind != pb.ChildEvent_Kind.print) {
        if (printFailure case (final error, final stack)) {
          Error.throwWithStackTrace(error, stack);
        }

        return event;
      }
      if (onPrint == null) continue;
      try {
        await onPrint(event.print);
      } on Object catch (error, stack) {
        printFailure ??= (error, stack);
      }
    }
  }

  /// The channel's crash, recorded once: the first cause seen wins.
  ///
  /// [fatal] is a `FatalError`'s message. Otherwise the worker's exit code
  /// decides, read within [fatalExitGrace] before the worker is killed.
  Future<MontyCrashedError> _crashed({String? fatal}) async {
    final recorded = _crash;
    if (recorded != null) return recorded;
    final code = await _exitWithin(fatalExitGrace);
    final cause = switch ((fatal, code)) {
      _ when _killed => CrashCause.killed,
      (String _, _) => CrashCause.fatal,
      (_, workerOomExitCode) => CrashCause.outOfMemory,
      _ => CrashCause.vanished,
    };
    await _stderr.drain(pipeDrainGrace);
    final tail = _stderr.text;

    return _crash ??= crashedError(
      cause,
      exitCode: code,
      detail:
          fatal ?? (_killed ? 'killed by the parent' : _events.describeEnd()),
      stderrTail: tail.isEmpty ? null : tail,
      context: _unsent ? sendingRequest : null,
    );
  }

  /// The exit code, waiting at most [grace] before killing the worker.
  Future<int> _exitWithin(Duration grace) => _process.exitCode.timeout(
    grace,
    onTimeout: () {
      _process.kill(ProcessSignal.sigkill);

      return _process.exitCode;
    },
  );

  Future<void> _close() async {
    if (_busy) {
      kill();
      await _process.exitCode;

      return;
    }
    final wasAlive = isAlive;
    _closed = true;
    if (wasAlive) {
      final stdin = _process.stdin;
      try {
        stdin.add(Frame.encode(pb.ParentRequest(shutdown: pb.Shutdown())));
        await stdin.close();
      } on Object catch (_) {
        // The worker is already gone; the exit below is all that is left.
      }
    }
    await _exitWithin(shutdownGrace);
    _events.cancel();
    await _stderr.drain(pipeDrainGrace);
  }

  Future<void> _reapOnExit() async {
    await _process.exitCode;
    _exited = true;
    _live.remove(this);
    await _events.endWithin(pipeDrainGrace);
  }
}

/// [channel]'s next event, or null once none can arrive. A whole frame
/// that does not decode means the worker misbehaved, not that it died
/// (upstream's `FrameError::Decode` arm): a protocol violation, and the
/// worker is discarded.
Future<pb.ChildEvent?> _nextEvent(ProcessChannel channel) async {
  try {
    return await channel._events.next();
  } on FrameDecodeException catch (error) {
    final crash = channel._crash ??= crashedError(
      CrashCause.protocol,
      detail: 'invalid payload from worker: ${error.reason}',
    );
    channel.kill();
    throw crash;
  }
}

/// The environment a worker starts with: empty, except `SystemRoot` on
/// Windows, without which Windows' own DLLs fail to initialise.
///
/// Upstream's pool does the same.
@visibleForTesting
Map<String, String> workerEnvironment({
  required bool isWindows,
  required Map<String, String> parent,
}) {
  final systemRoot = parent['SystemRoot'];

  return {
    if (isWindows && systemRoot != null) 'SystemRoot': systemRoot,
  };
}

/// Ends [events] (after the usual drain grace) if [sending] fails: a worker
/// that cannot read its request may still hold stdout open, and the turn
/// reading it would otherwise wait forever.
Future<void> _endOutputIfUnsent(Future<bool> sending, EventQueue events) async {
  if (!await sending) await events.endWithin(ProcessChannel.pipeDrainGrace);
}

/// Whether [frame] was all written to [stdin] of a worker that was [alive].
Future<bool> _written(bool alive, IOSink stdin, List<int> frame) async =>
    alive && _added(stdin, frame) && await _flushed(stdin);

/// Whether [frame] could be added to [stdin]; false once it is closed.
bool _added(IOSink stdin, List<int> frame) {
  try {
    stdin.add(frame);

    return true;
  } on Object catch (_) {
    return false;
  }
}

/// Whether everything added to [stdin] was written.
Future<bool> _flushed(IOSink stdin) async {
  try {
    await stdin.flush();

    return true;
  } on Object catch (_) {
    return false;
  }
}

/// Awaits [done], a stdin's completion, discarding its failure.
///
/// A write to a dead worker fails at `stdin.done` as well as at the flush.
/// The turn that wrote reports it as a [MontyCrashedError], so this copy
/// must not escape as an unhandled error.
Future<void> _absorbFailure(Future<void> done) async {
  try {
    await done;
  } on Object catch (_) {
    // Reported by the turn that wrote.
  }
}

/// How a worker process is started.
sealed class WorkerLaunch {
  /// Base constructor for the launch kinds.
  const WorkerLaunch();
}

/// A worker executable at [path]: a contributor build, a test double, or a
/// bundled helper.
final class WorkerExecutable extends WorkerLaunch {
  /// Launches [path] with [args].
  const WorkerExecutable(this.path, {this.args = const []});

  /// The executable.
  final String path;

  /// Its arguments. The worker itself takes none.
  final List<String> args;

  @override
  String toString() => 'WorkerExecutable($path)';
}

/// This AOT executable, run again with [flag] so that
/// `runMontyWorkerIfChild` (lib/src/worker/self_relaunch.dart) serves the
/// protocol in the copy.
///
/// For `dart build cli` apps that bundle the worker library. Under `dart run`
/// the executable is the Dart VM, which does not know the flag.
final class SelfRelaunch extends WorkerLaunch {
  /// The relaunch of this executable.
  const SelfRelaunch();

  /// The child's only argument; it selects the worker in
  /// `runMontyWorkerIfChild`.
  static const String flag = '--dart-monty-core-worker';

  @override
  String toString() => 'SelfRelaunch()';
}

/// The executable and arguments [launch] runs.
@visibleForTesting
(String, List<String>) launchCommand(WorkerLaunch launch) => switch (launch) {
  WorkerExecutable(:final path, :final args) => (path, args),
  SelfRelaunch() => (Platform.resolvedExecutable, const [SelfRelaunch.flag]),
};

/// The worker's stdout as decoded events, buffered until a turn reads them.
///
/// Visible for its own tests, which drive it with chosen chunk boundaries.
///
/// Holds at most [limit] wire bytes of completed events, plus the frame in
/// flight when the limit was passed: past it, the subscription pauses at the
/// next frame end and resumes once a reader takes the queue back under it.
@visibleForTesting
final class EventQueue {
  /// Reads [bytes] as frames, pausing past [limit] (past [limit] plus
  /// [drainAllowance] once draining); [onDesync] runs once if they stop
  /// being frames.
  EventQueue(
    Stream<List<int>> bytes, {
    required this.limit,
    required this.onDesync,
    this.drainAllowance = 0,
  }) : _bound = limit {
    _subscription = bytes.listen(_add, onDone: _end, onError: _fail);
  }

  /// The read-ahead, in wire bytes, past which reading pauses.
  final int limit;

  /// Extra read-ahead allowed while draining (see [endWithin]).
  final int drainAllowance;

  /// Called once if the stream stops being readable as frames.
  final void Function() onDesync;

  final _decoder = FrameDecoder();
  final _queue = Queue<(pb.ChildEvent, int)>();
  StreamSubscription<List<int>>? _subscription;
  final _closed = Completer<void>();
  Completer<void>? _wake;
  Object? _error;

  /// The frame that arrived whole but did not decode, if one did.
  FrameDecodeException? _invalid;
  bool _ended = false;
  bool _cancelled = false;
  int _readAhead = 0;
  int _peakReadAhead = 0;

  /// Over [limit] with a frame part-received: pause once a frame ends.
  bool _finishingFrame = false;

  /// The read-ahead at which reading pauses: [limit] until [endWithin]
  /// first runs, then what was queued then (at least [limit]) plus
  /// [drainAllowance].
  int _bound;

  bool _draining = false;

  /// Wire bytes of the queued events.
  int get readAhead => _readAhead;

  /// The most [readAhead] has been.
  int get peakReadAhead => _peakReadAhead;

  /// Whether another event can still arrive.
  bool get isOpen => !_ended && !_cancelled && _error == null;

  /// The next event, or null once none can arrive.
  ///
  /// Events decoded before the output ended are still returned; after
  /// [cancel], none are. A whole frame that did not decode is thrown as its
  /// [FrameDecodeException] once the events before it are taken; nothing
  /// after it is read.
  Future<pb.ChildEvent?> next() async {
    for (;;) {
      if (_cancelled) return null;
      if (_queue.isNotEmpty) {
        final (event, size) = _queue.removeFirst();
        _readAhead -= size;
        if (_readAhead < _bound) _resume();

        return event;
      }
      final invalid = _invalid;
      if (invalid != null) throw invalid;
      if (_ended || _error != null) return null;
      final wake = Completer<void>();
      _wake = wake;
      await wake.future;
    }
  }

  /// Drops buffered events, ends any wait in [next] and stops listening, so
  /// a pipe some other process holds open cannot keep this one alive.
  void cancel() {
    _cancelled = true;
    _queue.clear();
    _readAhead = 0;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _wakeUp();
  }

  /// Waits up to [grace] for the output to end, then ends it: frames
  /// already received are still returned, and nothing more is read.
  ///
  /// Called once the worker has exited or a request could not be sent.
  /// Reading resumes up to [limit] plus [drainAllowance], room for what the
  /// pipe held, but stays bounded: a process that inherited the pipe may
  /// keep writing.
  Future<void> endWithin(Duration grace) async {
    if (!_draining) {
      _draining = true;
      // Relative to the queue, and to the frame in flight, which completes
      // whatever the bound: either can hold the queue past the limit, and
      // the frames behind them in the pipe must still arrive.
      _bound =
          math.max(_bound, _readAhead + _decoder.inFlightLength) +
          drainAllowance;
    }
    if (_readAhead < _bound) _resume();
    await _closed.future.timeout(grace, onTimeout: () => null);
    if (_ended) return;
    _ended = true;
    unawaited(_subscription?.cancel());
    _subscription = null;
    _wakeUp();
  }

  /// Why the stream ended, for a crash report.
  String describeEnd() {
    final error = _error;

    return error == null
        ? 'worker exited without ending the turn'
        : 'worker output unreadable: $error';
  }

  void _add(List<int> chunk) {
    if (_error != null) return;
    try {
      final bodies = _decoder.add(chunk);
      for (final body in bodies) {
        final size = Frame.prefixLength + body.length;
        _queue.add((FrameScan.decodeChildEvent(body), size));
        _readAhead += size;
      }
      _peakReadAhead = math.max(_peakReadAhead, _readAhead);
      _pauseIfFull(completedFrame: bodies.isNotEmpty);
    } on FrameDecodeException catch (error) {
      // The stream itself is intact; the worker is not trusted further.
      _invalid = error;
      _desync(error);
    } on FrameException catch (error) {
      _desync(error);
    }
    _wakeUp();
  }

  /// Pauses reading once the read-ahead is at [limit], but never inside the
  /// frame that was in flight when it got there: that frame completes
  /// first, and only the frames after it wait.
  void _pauseIfFull({required bool completedFrame}) {
    final subscription = _subscription;
    if (_readAhead < _bound || subscription == null || subscription.isPaused) {
      return;
    }
    if (_decoder.pendingBytes == 0 || (_finishingFrame && completedFrame)) {
      _finishingFrame = false;
      subscription.pause();
    } else {
      _finishingFrame = true;
    }
  }

  /// Reads again after a pause.
  void _resume() {
    _finishingFrame = false;
    final subscription = _subscription;
    if (subscription != null && subscription.isPaused) subscription.resume();
  }

  /// The next byte can no longer be trusted to start a frame.
  void _desync(Object error) {
    _error = error;
    onDesync();
  }

  void _end() {
    _ended = true;
    if (!_closed.isCompleted) _closed.complete();
    if (_error == null) {
      try {
        _decoder.close();
      } on FrameException catch (error) {
        _error = error;
      }
    }
    _wakeUp();
  }

  void _fail(Object error) {
    _error ??= error;
    _end();
  }

  void _wakeUp() {
    _wake?.complete();
    _wake = null;
  }
}

/// The last [capacity] bytes of a byte stream, which it always drains: a
/// worker blocks once its stderr pipe fills.
final class _ByteTail {
  _ByteTail(Stream<List<int>> bytes, this.capacity) {
    _subscription = bytes.listen(
      _add,
      onDone: _end,
      onError: (Object _) => _end(),
    );
  }

  final int capacity;
  final _chunks = ListQueue<List<int>>();
  final _ended = Completer<void>();
  StreamSubscription<List<int>>? _subscription;
  int _length = 0;

  /// Waits up to [grace] for the stream to end, then stops listening.
  ///
  /// The exit code can arrive before the last of the output, so a reader
  /// waits; a process that inherited the pipe can hold it open forever, so
  /// the wait is bounded, and the subscription is cancelled so it cannot
  /// keep this process alive.
  Future<void> drain(Duration grace) async {
    await _ended.future.timeout(grace, onTimeout: () => null);
    await _subscription?.cancel();
    _subscription = null;
  }

  /// The tail as text, trimmed; a cut multi-byte character becomes U+FFFD.
  String get text {
    final bytes = [for (final chunk in _chunks) ...chunk];
    final start = math.max(0, bytes.length - capacity);

    return utf8.decode(bytes.sublist(start), allowMalformed: true).trim();
  }

  void _add(List<int> chunk) {
    _chunks.add(chunk);
    _length += chunk.length;
    for (;;) {
      final head = _chunks.firstOrNull;
      if (head == null || _length - head.length < capacity) break;
      _length -= _chunks.removeFirst().length;
    }
  }

  void _end() {
    if (!_ended.isCompleted) _ended.complete();
  }
}
