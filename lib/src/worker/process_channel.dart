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
    : _events = _EventStream(
        _process.stdout,
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

  /// How long [close] waits for the worker to exit after `Shutdown`.
  static const Duration shutdownGrace = Duration(seconds: 2);

  static final Set<ProcessChannel> _live = {};

  /// Every channel whose worker process has not yet exited.
  static Set<ProcessChannel> get live => UnmodifiableSetView(_live);

  final Process _process;
  final _EventStream _events;
  final _ByteTail _stderr;
  MontyCrashedError? _crash;
  bool _killed = false;
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

  @override
  bool get isAlive =>
      _crash == null && !_closed && !_killed && !_exited && _events.isOpen;

  @override
  Future<pb.ChildEvent> turn(
    pb.ParentRequest request, {
    void Function(pb.Print print)? onPrint,
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
      var sent = isAlive;
      if (sent) {
        final stdin = _process.stdin;
        try {
          stdin.add(frame);
          await stdin.flush();
        } on Object catch (_) {
          sent = false;
        }
      }
      if (!sent) throw await _crashed();

      return await _readTurn(onPrint);
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

  /// Reads events up to the turn's end, handing each `Print` to [onPrint].
  ///
  /// An [onPrint] that throws does not desynchronise the stream: the rest
  /// of the turn is still read, then its first error is rethrown.
  Future<pb.ChildEvent> _readTurn(
    void Function(pb.Print print)? onPrint,
  ) async {
    (Object, StackTrace)? printFailure;
    for (;;) {
      final event = await _events.next();
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
      try {
        onPrint?.call(event.print);
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

    return _crash ??= MontyCrashedError(
      cause,
      exitCode: code,
      message:
          fatal ?? (_killed ? 'killed by the parent' : _events.describeEnd()),
      stderrTail: tail.isEmpty ? null : tail,
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
final class _EventStream {
  _EventStream(Stream<List<int>> bytes, {required this.onDesync}) {
    _subscription = bytes.listen(_add, onDone: _end, onError: _fail);
  }

  /// Called once if the stream stops being readable as frames.
  final void Function() onDesync;

  final _decoder = FrameDecoder();
  final _queue = Queue<pb.ChildEvent>();
  StreamSubscription<List<int>>? _subscription;
  final _closed = Completer<void>();
  Completer<void>? _wake;
  Object? _error;
  bool _ended = false;
  bool _cancelled = false;

  /// Whether another event can still arrive.
  bool get isOpen => !_ended && !_cancelled && _error == null;

  /// The next event, or null once none can arrive.
  ///
  /// Events decoded before the output ended are still returned; after
  /// [cancel], none are.
  Future<pb.ChildEvent?> next() async {
    for (;;) {
      if (_cancelled) return null;
      final event = _queue.firstOrNull;
      if (event != null) return _queue.removeFirst();
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
    unawaited(_subscription?.cancel());
    _subscription = null;
    _wakeUp();
  }

  /// Waits up to [grace] for the output to end, then ends it: frames
  /// already received are still returned, and nothing more is read.
  Future<void> endWithin(Duration grace) async {
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
      for (final body in _decoder.add(chunk)) {
        _queue.add(FrameScan.decodeChildEvent(body));
      }
    } on FrameException catch (error) {
      _desync(error);
    }
    _wakeUp();
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
