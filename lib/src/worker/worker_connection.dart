/// The turn logic of the browser channel, independent of `dart:js_interop`.
///
/// A Web Worker streams Print frames, then sends a turn-ending frame and
/// dmw_last_outcome(). The terminal reply waits for all print callbacks.
/// A trap poisons the instance. `worker_channel.dart` binds the connection;
/// tests bind it to a fake [WorkerPort] on every compiler.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/frame_scan.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show MontyCrashedErrorInternal;
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;
import 'package:dart_monty_core/src/worker/telemetry_channel.dart';
import 'package:dart_monty_core/src/worker/telemetry_metrics.dart';
import 'package:dart_monty_core/src/worker/telemetry_recorder.dart';

/// The protocol version this driver speaks: upstream monty-proto's
/// `PROTOCOL_VERSION` at the pinned tag.
const int workerProtocolVersion = 5;

/// How long [WorkerConnection.close] waits for the `Shutdown` reply before it
/// terminates the Worker: upstream's `SHUTDOWN_EXIT_GRACE`, which its pool
/// gives an idle worker it closes.
const Duration workerCloseGrace = Duration(milliseconds: 500);

/// One message from the Worker, every field optional: the ready reply
/// (`ready`, `error`, `jspi`, `protocol`), streamed `print`, a turn reply
/// (`events`, `outcome`) or a trap (`trap`, `stderr`).
typedef WorkerMessage = ({
  bool? ready,
  String? error,
  bool? jspi,
  int? protocol,
  Uint8List? events,
  int? outcome,
  String? trap,
  String? stderr,
  Uint8List? print,
});

/// The first message of a Worker that failed to start, with [error].
WorkerMessage workerFailure(String error) => (
  ready: false,
  error: error,
  jspi: null,
  protocol: null,
  events: null,
  outcome: null,
  trap: null,
  stderr: null,
  print: null,
);

/// `dmw_last_outcome()` after a turn that leaves the instance usable.
const int outcomeContinue = 0;

/// `dmw_last_outcome()` after a turn that shut the instance down.
const int outcomeShutdown = 1;

/// [MontyChannel] over a [WorkerPort]: one turn at a time.
///
/// The binding feeds every Worker message to [onReply], [onTrap] or
/// [onWorkerError]. A trap, a worker error, a `FatalError` or a torn reply
/// kills the connection for good; a replacement is a new Worker.
final class WorkerConnection with RecordedChannel implements MontyChannel {
  WorkerConnection._(
    WorkerPort port, {
    required this.jspi,
    required this.protocol,
    required Duration closeGrace,
  }) : _port = port,
       _prints = _PrintQueue(port),
       _closeGrace = closeGrace;

  /// Accepts the Worker behind [port] from its first message, [hello].
  ///
  /// A Worker that did not start is terminated and this throws
  /// [MontyCrashedError] with [CrashCause.vanished]. A protocol other than
  /// [expectedProtocol] is refused before any `Configure`: the Worker is
  /// terminated and this throws [CrashCause.fatal].
  factory WorkerConnection.accept(
    WorkerPort port,
    WorkerMessage hello, {
    int expectedProtocol = workerProtocolVersion,
    Duration closeGrace = workerCloseGrace,
  }) {
    if (hello.ready != true) {
      port.terminate();
      throw crashedError(
        CrashCause.vanished,
        detail: hello.error ?? 'the Worker did not start',
      );
    }
    final protocol = hello.protocol;
    if (protocol != expectedProtocol) {
      port.terminate();
      throw crashedError(
        CrashCause.fatal,
        detail:
            'worker speaks protocol $protocol; this driver speaks '
            '$expectedProtocol',
      );
    }

    return WorkerConnection._(
      port,
      jspi: hello.jspi ?? false,
      protocol: expectedProtocol,
      closeGrace: closeGrace,
    );
  }

  /// Whether `dmw_dispatch` runs under JSPI (`WebAssembly.promising`).
  final bool jspi;

  /// The protocol version the module reported.
  final int protocol;

  final WorkerPort _port;
  final Duration _closeGrace;

  Completer<pb.ChildEvent>? _pending;
  final _PrintQueue _prints;
  PrintHandler? _onPrint;

  MontyCrashedError? _crash;
  bool _closed = false;
  bool _inTurn = false;
  Future<void>? _closing;

  /// Bytes received but not yet acknowledged, for the transport window tests.
  int get pendingPrintBytes => _prints.pendingBytes;

  @override
  bool get isAlive => _crash == null && !_closed && _closing == null;

  @override
  Future<pb.ChildEvent> turn(
    pb.ParentRequest request, {
    PrintHandler? onPrint,
  }) async {
    _checkUsable();
    // Callbacks remain inside this turn, including while the terminal reply
    // waits for their completion; a callback must not start another turn.
    if (_inTurn) throw StateError('one turn at a time');
    final frame = Frame.encode(request);
    _inTurn = true;
    try {
      _onPrint = onPrint;
      final pending = _pending = Completer<pb.ChildEvent>();
      _port.post(frame);
      TelemetryMetrics.frame.attribute(frame.length, 'direction', 'sent');
      recorder?.beginTurn(request);

      return await pending.future;
    } finally {
      _pending = null;
      _inTurn = false;
      _onPrint = null;
    }
  }

  /// Routes any Worker message after the first: a trap, or a turn reply.
  void onMessage(WorkerMessage message) {
    final trap = message.trap;
    if (trap != null) {
      onTrap(trap, stderr: message.stderr);
    } else if (message.print case final batch?) {
      final pending = _pending;
      if (pending == null) return;
      final delivery = _PrintDelivery(() => _crash, _die);
      _prints.add(
        batch,
        pending,
        (print) {
          recorder?.event(pb.ChildEvent(print: print));

          return delivery.deliver(print, _onPrint);
        },
        delivery.failed,
      );
    } else if (message.events case final events?) {
      onReply(events, message.outcome ?? -1);
    } else {
      onWorkerError('unrecognised Worker message');
    }
  }

  /// Delivers a turn reply: framed events and `dmw_last_outcome()`.
  void onReply(Uint8List events, int outcome) {
    final pending = _pending;
    if (pending == null) return;
    if (_closing != null && !_inTurn) {
      _pending = null;
      pending.complete(pb.ChildEvent());

      return;
    }
    unawaited(
      _prints.reply(
        pending,
        () => _finishTurn(events, outcome, _onPrint),
      ),
    );
  }

  /// Only the allocator's final stderr line identifies an out-of-memory trap.
  void onTrap(String message, {String? stderr}) {
    final last = stderr
        ?.split('\n')
        .where((line) => line.isNotEmpty)
        .lastOrNull;
    final oom =
        last != null &&
        RegExp(
          r'^monty worker: allocation of \d+ bytes (exceeds the memory limit|failed)$',
        ).hasMatch(last);
    _die(
      oom ? CrashCause.outOfMemory : CrashCause.vanished,
      message,
      stderr: stderr,
    );
  }

  /// The Worker raised an error outside a turn reply.
  void onWorkerError(String message) => _die(CrashCause.vanished, message);

  @override
  Future<void> close() {
    final closing = _closing;
    if (closing != null) return closing;
    if (!isAlive) return Future.value();
    if (_inTurn) {
      kill();

      return Future.value();
    }

    return _closing = _shutdown();
  }

  @override
  void kill() {
    recorder?.close();
    if (_crash != null || _closed) return;
    _die(CrashCause.killed, null);
  }

  Future<void> _shutdown() async {
    recorder?.close();
    final reply = _pending = Completer<pb.ChildEvent>();
    final frame = Frame.encode(pb.ParentRequest(shutdown: pb.Shutdown()));
    _port.post(frame);
    TelemetryMetrics.frame.attribute(frame.length, 'direction', 'sent');
    try {
      await reply.future.timeout(_closeGrace);
    } on Object {
      // No reply within the grace, or the Worker died: terminate regardless.
    }
    _pending = null;
    if (_crash == null) {
      _closed = true;
      _port.terminate();
    }
  }

  void _checkUsable() {
    final crash = _crash;
    if (crash != null) {
      throw repeatCrash(crash);
    }
    if (_closed || _closing != null) throw StateError('channel is closed');
  }

  Future<pb.ChildEvent> _finishTurn(
    Uint8List events,
    int outcome,
    PrintHandler? onPrint,
  ) async {
    final List<Uint8List> bodies;
    try {
      bodies = Frame.split(events);
    } on FrameException catch (e) {
      throw _die(CrashCause.vanished, 'unreadable turn reply: $e');
    }
    for (final body in bodies) {
      final (event, unreadable) = _decode(body);
      if (event == null) {
        // The frame arrived whole: the Worker misbehaved, it did not die
        // (upstream's `FrameError::Decode` arm).
        throw _die(
          CrashCause.protocol,
          'invalid payload from worker: ${unreadable?.reason}',
        );
      }
      TelemetryMetrics.frame.attribute(
        Frame.prefixLength + body.length,
        'direction',
        'received',
      );
      recorder?.event(event);
      switch (event.whichKind()) {
        case pb.ChildEvent_Kind.print:
          await _PrintDelivery(
            () => _crash,
            _die,
          ).deliver(event.print, onPrint);
        case pb.ChildEvent_Kind.fatalError:
          throw _die(CrashCause.fatal, event.fatalError.message);
        case _:
          if (outcome == outcomeShutdown) {
            _closed = true;
            _port.terminate();
          } else if (outcome != outcomeContinue) {
            throw _die(CrashCause.fatal, 'turn ended with outcome $outcome');
          }

          return event;
      }
    }
    throw _die(CrashCause.vanished, 'turn reply without a turn-ending event');
  }

  /// Marks the connection dead, terminates the Worker and fails any turn in
  /// flight. Returns the error for the caller to throw.
  MontyCrashedError _die(
    CrashCause cause,
    String? message, {
    String? stderr,
    Object? failure,
  }) {
    recorder?.close();
    final crash = _crash ??= crashedError(
      cause,
      detail: message,
      stderrTail: stderr,
    );
    _prints.clear();
    _port.terminate();
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(failure ?? crash, StackTrace.current);
    }

    return repeatCrash(crash);
  }
}

/// Delivers both streamed and terminal-frame prints with the same failure
/// handling. A callback that throws or kills the channel abandons the turn.
final class _PrintDelivery {
  const _PrintDelivery(this._readCrash, this._fail);

  final MontyCrashedError? Function() _readCrash;
  final void Function(CrashCause, String?, {Object? failure}) _fail;

  Future<void> deliver(pb.Print print, PrintHandler? onPrint) async {
    try {
      await onPrint?.call(print);
    } on Object catch (error) {
      _fail(CrashCause.killed, 'onPrint threw; turn abandoned', failure: error);
      rethrow;
    }
    final crash = _readCrash();
    if (crash != null) {
      throw repeatCrash(crash);
    }
  }

  void failed(Object error) => _fail(
    error is MontyCrashedError ? error.cause : CrashCause.killed,
    'print delivery failed',
    failure: error,
  );
}

/// Serializes batches without blocking the connection's crash/kill path.
/// Queued buffers can be released even if the current callback never settles.
final class _PrintQueue {
  _PrintQueue(this._port);

  int pendingBytes = 0;

  final WorkerPort _port;
  final _batches = Queue<Uint8List>();
  Completer<void>? _drained;

  Future<void> get settled => _drained?.future ?? Future.value();

  /// Releases queued buffers; an active callback still settles on its own.
  void clear() {
    _batches.clear();
    pendingBytes = 0;
  }

  void add(
    Uint8List batch,
    Completer<pb.ChildEvent> pending,
    Future<void> Function(pb.Print) deliver,
    void Function(Object) failed,
  ) {
    if (pending.isCompleted) return;
    _batches.add(batch);
    pendingBytes += batch.length;
    if (_drained != null) return;
    final drained = _drained = Completer<void>();
    unawaited(_drain(pending, deliver, failed, drained));
  }

  Future<void> reply(
    Completer<pb.ChildEvent> pending,
    Future<pb.ChildEvent> Function() finish,
  ) async {
    try {
      await settled;
      if (pending.isCompleted) return;
      final event = await finish();
      if (pending.isCompleted) return;
      pending.complete(event);
    } on Object catch (error, stack) {
      if (!pending.isCompleted) pending.completeError(error, stack);
    }
  }

  Future<void> _drain(
    Completer<pb.ChildEvent> pending,
    Future<void> Function(pb.Print) deliver,
    void Function(Object) failed,
    Completer<void> drained,
  ) async {
    try {
      while (_batches.isNotEmpty && !pending.isCompleted) {
        final batch = _batches.removeFirst();
        final List<Uint8List> bodies;
        try {
          bodies = Frame.split(batch);
        } on FrameException catch (e) {
          throw crashedError(
            CrashCause.vanished,
            detail: 'unreadable streamed Print batch: $e',
          );
        }
        for (final body in bodies) {
          final printed = _streamedPrint(body);
          await deliver(printed);
        }
        if (!pending.isCompleted) {
          pendingBytes -= batch.length;
          _port.acknowledge(batch.length);
        }
      }
    } on Object catch (error) {
      if (!pending.isCompleted) failed(error);
    } finally {
      clear();
      _drained = null;
      drained.complete();
    }
  }
}

/// The page's handle on one Worker.
abstract interface class WorkerPort {
  /// Posts one request frame to the Worker.
  void post(Uint8List frame);

  /// Acknowledges bytes only after their print callbacks have settled.
  void acknowledge(int bytes);

  /// Stops the Worker immediately, mid-turn or not.
  void terminate();
}

/// A value produced once, on first use, and shared; a failure is not kept,
/// so the next use tries again. Holds the page's compiled wasm module.
final class OnceAsync<T> {
  /// Creates a holder that runs [_produce] on first use.
  OnceAsync(this._produce);

  final Future<T> Function() _produce;
  Future<T>? _value;
  int _runs = 0;

  /// The value: the first call starts [_produce], later calls share it.
  Future<T> get value => _value ??= _run();

  /// How many times [_produce] has been started.
  int get runs => _runs;

  Future<T> _run() async {
    _runs++;
    try {
      return await _produce();
    } on Object {
      _value = null;
      rethrow;
    }
  }
}

/// One event decoded as upstream decodes it, or why it cannot be.
(pb.ChildEvent?, FrameDecodeException?) _decode(Uint8List body) {
  try {
    return (FrameScan.decodeChildEvent(body), null);
  } on FrameDecodeException catch (e) {
    return (null, e);
  }
}

/// Decode and charge each complete streamed frame before callback delivery.
pb.Print _streamedPrint(Uint8List body) {
  final (event, _) = _decode(body);
  if (event == null || event.whichKind() != pb.ChildEvent_Kind.print) {
    throw crashedError(
      CrashCause.protocol,
      detail: 'invalid streamed Print frame',
    );
  }
  TelemetryMetrics.frame.attribute(
    Frame.prefixLength + body.length,
    'direction',
    'received',
  );

  return event.print;
}
