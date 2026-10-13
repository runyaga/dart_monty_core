/// A worker that is starting, and the one way to abandon it.
///
/// Pure Dart: the pool holds these on every backend.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';

import 'package:dart_monty_core/src/worker/monty_channel.dart';

/// A worker being started.
abstract interface class SpawnHandle {
  /// Completes with the worker's channel once it can take a turn.
  ///
  /// Fails if the worker cannot start, and with [MontyCrashedError]
  /// ([CrashCause.killed]) if [cancel] ran first.
  Future<MontyChannel> get ready;

  /// Abandons the worker: one not yet ready is stopped and [ready] fails;
  /// one already ready is killed. Idempotent.
  void cancel();
}

/// Starts a channel; [cancelled] completes when [SpawnHandle.cancel] runs,
/// so a start that can be interrupted (a Web Worker's greeting) stops early.
typedef ChannelStart = Future<MontyChannel> Function(Future<void> cancelled);

/// The [SpawnHandle] for a [ChannelStart].
///
/// A channel that becomes ready after [cancel] is killed as it arrives, so a
/// cancelled start never leaves a worker running, whether or not the start
/// itself could be interrupted.
final class PendingSpawn implements SpawnHandle {
  /// Runs [start] now.
  PendingSpawn(ChannelStart start) {
    // A cancelled start's failure is reported through [ready]'s own error;
    // nothing else may surface it.
    _ready.future.ignore();
    unawaited(_run(start));
  }

  final _cancelled = Completer<void>();
  final _ready = Completer<MontyChannel>();
  MontyChannel? _channel;

  @override
  Future<MontyChannel> get ready => _ready.future;

  @override
  void cancel() {
    if (_cancelled.isCompleted) return;
    _cancelled.complete();
    if (_ready.isCompleted) {
      _channel?.kill();

      return;
    }
    _ready.completeError(
      MontyCrashedError(
        CrashCause.killed,
        message: 'the worker start was cancelled',
      ),
      StackTrace.current,
    );
  }

  Future<void> _run(ChannelStart start) async {
    final MontyChannel channel;
    try {
      channel = await start(_cancelled.future);
    } on Object catch (error, stack) {
      if (!_ready.isCompleted) _ready.completeError(error, stack);

      return;
    }
    if (_cancelled.isCompleted) {
      channel.kill();

      return;
    }
    _channel = channel;
    _ready.complete(channel);
  }
}
