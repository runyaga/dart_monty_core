/// The turn transport between the driver and one worker.
///
/// The only backend-conditional part of the worker stack: a process pipe on
/// native, a Web Worker on the web. Both carry the same monty-proto messages,
/// one turn at a time, and both report a dead worker the same way.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';

import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;

// The crash every channel reports, and the factories that make it.
export 'package:dart_monty_core/src/worker/monty_error.dart'
    show CrashCause, MontyCrashedError, crashedError, repeatCrash;

/// Receives one `Print` during a turn. The turn awaits it before it reads
/// the next event, so prints are delivered one at a time, in order.
typedef PrintHandler = FutureOr<void> Function(pb.Print print);

/// One request in; zero or more `Print`s out, then exactly one turn-ending
/// event.
abstract interface class MontyChannel {
  /// Sends [request] and completes with the event that ends its turn.
  ///
  /// Each `Print` before it goes to [onPrint], whose future is awaited
  /// before the next event is read. A `FatalError`, the worker ending, or
  /// [kill] during the turn throws [MontyCrashedError], as does any later
  /// turn. One turn at a time: a second concurrent call, one from inside
  /// [onPrint] included, throws [StateError].
  Future<pb.ChildEvent> turn(pb.ParentRequest request, {PrintHandler? onPrint});

  /// Asks the worker to shut down, waits a grace period for it to exit, then
  /// kills it. Idempotent. During a turn it kills at once.
  Future<void> close();

  /// Kills the worker now: the deadline path. Idempotent. A turn in flight
  /// throws [MontyCrashedError] with [CrashCause.killed].
  void kill();

  /// Whether a turn can still be sent.
  bool get isAlive;
}
