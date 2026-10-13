/// The turn logic of the browser channel, independent of `dart:js_interop`.
///
/// A Web Worker running the wasm module answers each request frame with the
/// whole turn at once: every `Print` and the turn-ending event, buffered by
/// upstream's `dispatch_frame`, plus `dmw_last_outcome()`. Or it traps, which
/// poisons the instance. [WorkerConnection] turns those replies into
/// [MontyChannel] semantics. `worker_channel.dart` binds it to a real Worker;
/// tests bind it to a fake [WorkerPort] on every compiler.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/frame_scan.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;

/// The protocol version this driver speaks: upstream monty-proto's
/// `PROTOCOL_VERSION` at the pinned tag.
const int workerProtocolVersion = 5;

/// How long [WorkerConnection.close] waits for the `Shutdown` reply before it
/// terminates the Worker. Upstream's pool uses the same 100 ms
/// (`FATAL_EXIT_GRACE`).
const Duration workerCloseGrace = Duration(milliseconds: 100);

/// One message from the Worker, every field optional: the ready reply
/// (`ready`, `error`, `jspi`, `protocol`), a turn reply (`events`, `outcome`)
/// or a trap (`trap`). See the protocol in the Worker script.
typedef WorkerMessage = ({
  bool? ready,
  String? error,
  bool? jspi,
  int? protocol,
  Uint8List? events,
  int? outcome,
  String? trap,
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
final class WorkerConnection implements MontyChannel {
  WorkerConnection._(
    this._port, {
    required this.jspi,
    required this.protocol,
    required Duration closeGrace,
  }) : _closeGrace = closeGrace;

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
      throw MontyCrashedError(
        CrashCause.vanished,
        message: hello.error ?? 'the Worker did not start',
      );
    }
    final protocol = hello.protocol;
    if (protocol != expectedProtocol) {
      port.terminate();
      throw MontyCrashedError(
        CrashCause.fatal,
        message:
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

  Completer<(Uint8List, int)>? _pending;
  MontyCrashedError? _crash;
  bool _closed = false;
  bool _inTurn = false;
  Future<void>? _closing;

  @override
  bool get isAlive => _crash == null && !_closed && _closing == null;

  @override
  Future<pb.ChildEvent> turn(
    pb.ParentRequest request, {
    PrintHandler? onPrint,
  }) async {
    _checkUsable();
    // `_inTurn`, not `_pending`, is the guard: the reply clears `_pending`
    // before its Prints are delivered, and a callback must not start a turn.
    if (_inTurn) throw StateError('one turn at a time');
    final frame = Frame.encode(request);
    _inTurn = true;
    try {
      final pending = _pending = Completer<(Uint8List, int)>();
      _port.post(frame);
      final (events, outcome) = await pending.future;

      return await _finishTurn(events, outcome, onPrint);
    } finally {
      _inTurn = false;
    }
  }

  /// Routes any Worker message after the first: a trap, or a turn reply.
  void onMessage(WorkerMessage message) {
    final trap = message.trap;
    final events = message.events;
    if (trap != null) {
      onTrap(trap);
    } else if (events != null) {
      onReply(events, message.outcome ?? -1);
    } else {
      onWorkerError('unrecognised Worker message');
    }
  }

  /// Delivers a turn reply: framed events and `dmw_last_outcome()`.
  void onReply(Uint8List events, int outcome) {
    final pending = _pending;
    _pending = null;
    pending?.complete((events, outcome));
  }

  /// The Worker caught a trap: the instance is poisoned.
  void onTrap(String message) => _die(CrashCause.vanished, message);

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
    if (_crash != null || _closed) return;
    _die(CrashCause.killed, null);
  }

  Future<void> _shutdown() async {
    final reply = _pending = Completer<(Uint8List, int)>();
    _port.post(Frame.encode(pb.ParentRequest(shutdown: pb.Shutdown())));
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
      throw MontyCrashedError(crash.cause, message: crash.message);
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
        throw _die(CrashCause.vanished, 'unreadable turn reply: $unreadable');
      }
      switch (event.whichKind()) {
        case pb.ChildEvent_Kind.print:
          await _deliver(event.print, onPrint);
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

  /// Hands [print] to [onPrint] and awaits it. A callback that throws, or
  /// that kills the channel, abandons the turn: the events after the Print
  /// are never delivered, so a Worker waiting on one of them must not be
  /// reused.
  Future<void> _deliver(pb.Print print, PrintHandler? onPrint) async {
    try {
      await onPrint?.call(print);
    } on Object {
      _die(CrashCause.killed, 'onPrint threw; turn abandoned');
      rethrow;
    }
    final crash = _crash;
    if (crash != null) {
      throw MontyCrashedError(crash.cause, message: crash.message);
    }
  }

  /// Marks the connection dead, terminates the Worker and fails any turn in
  /// flight. Returns the error for the caller to throw.
  MontyCrashedError _die(CrashCause cause, String? message) {
    final crash = _crash ??= MontyCrashedError(cause, message: message);
    _port.terminate();
    final pending = _pending;
    _pending = null;
    pending?.completeError(crash, StackTrace.current);

    return MontyCrashedError(crash.cause, message: crash.message);
  }
}

/// The page's handle on one Worker.
abstract interface class WorkerPort {
  /// Posts one request frame to the Worker.
  void post(Uint8List frame);

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
(pb.ChildEvent?, FrameException?) _decode(Uint8List body) {
  try {
    return (FrameScan.decodeChildEvent(body), null);
  } on FrameException catch (e) {
    return (null, e);
  }
}
