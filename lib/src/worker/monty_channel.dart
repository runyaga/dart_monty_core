/// The turn transport between the driver and one worker.
///
/// The only backend-conditional part of the worker stack: a process pipe on
/// native, a Web Worker on the web. Both carry the same monty-proto messages,
/// one turn at a time, and both report a dead worker the same way.
///
/// Internal to the package; nothing here is exported.
library;

import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;

/// One request in; zero or more `Print`s out, then exactly one turn-ending
/// event.
abstract interface class MontyChannel {
  /// Sends [request] and completes with the event that ends its turn.
  ///
  /// Each `Print` before it goes to [onPrint]. A `FatalError`, the worker
  /// ending, or [kill] during the turn throws [MontyCrashedError], as does
  /// any later turn. One turn at a time: a second concurrent call throws
  /// [StateError].
  Future<pb.ChildEvent> turn(
    pb.ParentRequest request, {
    void Function(pb.Print print)? onPrint,
  });

  /// Asks the worker to shut down, waits a grace period for it to exit, then
  /// kills it. Idempotent. During a turn it kills at once.
  Future<void> close();

  /// Kills the worker now: the deadline path. Idempotent. A turn in flight
  /// throws [MontyCrashedError] with [CrashCause.killed].
  void kill();

  /// Whether a turn can still be sent.
  bool get isAlive;
}

/// Why a worker stopped answering.
enum CrashCause {
  /// The worker's allocator refused an allocation over its hard limit and
  /// the worker exited with upstream's `OOM_EXIT_CODE` (65).
  outOfMemory,

  /// The worker sent a `FatalError` and exited: protocol version skew, a
  /// desynchronised request stream, or a panic.
  fatal,

  /// The worker ended without a `FatalError`: EOF, a torn frame, a signal
  /// such as a native stack overflow's abort, or a wasm trap.
  vanished,

  /// The parent killed it: a deadline, or a close during a turn.
  killed,
}

/// The worker died. The parent process survives, and the channel that
/// reported this is never usable again; recovery is a new channel.
final class MontyCrashedError extends Error {
  /// Creates the error for a worker that stopped because of [cause].
  MontyCrashedError(
    this.cause, {
    this.exitCode,
    this.message,
    this.stderrTail,
  });

  /// Why the worker stopped.
  final CrashCause cause;

  /// The worker process's exit code, on native; negative for a signal.
  final int? exitCode;

  /// The `FatalError` text, a trap's text, or what the channel saw last.
  final String? message;

  /// On native, the last 4 KiB or less of the worker's stderr.
  final String? stderrTail;

  @override
  String toString() {
    final parts = [
      'MontyCrashedError(${cause.name}',
      if (exitCode != null) 'exit code $exitCode',
      if (message != null) '$message',
      if (stderrTail != null) 'stderr: $stderrTail',
    ];

    return '${parts.join(', ')})';
  }
}
