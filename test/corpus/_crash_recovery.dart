// Crash recovery through ONE pool: a session
// whose worker dies fails with MontyCrashedError, and the same capacity-1 pool
// then serves a new checkout with a new worker that answers `1 + 1`.
//
// The parity crash tests start an independent replacement worker after the
// crash, so they do not show that the POOL recovers. This does, and its two
// controls show it can fail: a pool that never gets the slot back, and a pool
// that hands the crashed worker out again.
import 'dart:async';

import 'package:dart_monty_core/dart_monty_core.dart'
    hide MontyError, MontySyntaxError, MontyTypingError;
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_pool.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/spawn_handle.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';
import 'package:test/test.dart';

/// Two checkouts' worth of patience for a worker to start.
const Duration _acquisition = Duration(seconds: 20);

/// One way to kill a worker.
final class CrashCase {
  /// Creates a [CrashCase].
  const CrashCase({
    required this.name,
    required this.code,
    required this.config,
    required this.check,
    this.requestTimeout,
  });

  /// What the case is called.
  final String name;

  /// Python that kills the worker.
  final String code;

  /// The session's settings.
  final SessionConfig config;

  /// The pool's request deadline, for a case the deadline kills.
  final Duration? requestTimeout;

  /// Asserts the crash is the kind the case means.
  final void Function(MontyCrashedError crash) check;
}

/// A [SpawnHandle] that records the channel it delivers.
final class _Recording implements SpawnHandle {
  _Recording(SpawnHandle inner, List<MontyChannel> seen)
    : _inner = inner,
      ready = _record(inner, seen);

  @override
  final Future<MontyChannel> ready;

  final SpawnHandle _inner;

  @override
  void cancel() => _inner.cancel();

  static Future<MontyChannel> _record(
    SpawnHandle inner,
    List<MontyChannel> seen,
  ) async {
    final channel = await inner.ready;
    seen.add(channel);

    return channel;
  }
}

/// A worker that never becomes ready.
final class _Never implements SpawnHandle {
  final _never = Completer<MontyChannel>();

  @override
  Future<MontyChannel> get ready => _never.future;

  @override
  void cancel() => _never.future.ignore();
}

/// A "worker" that is the channel that already died.
final class _Dead implements SpawnHandle {
  _Dead(MontyChannel channel) : ready = Future.value(channel);

  @override
  final Future<MontyChannel> ready;

  @override
  void cancel() => ready.ignore();
}

/// The pool did not recover from the crash.
final class RecoveryFailure implements Exception {
  /// Creates a [RecoveryFailure].
  const RecoveryFailure(this.message);

  /// What the pool did wrong.
  final String message;

  @override
  String toString() => 'RecoveryFailure: $message';
}

/// How the pool under test gets its second worker.
enum PoolBug {
  /// A correct pool.
  none,

  /// The crashed slot is never given back: no second worker ever arrives.
  slotNeverFreed,

  /// The crashed worker is handed out again.
  reusesCrashedWorker,
}

/// Crashes a worker of a capacity-1 pool as [crash] says, then checks the
/// same pool serves a new checkout with a new worker. With [bug] the pool's
/// second worker is wrong, and this must throw.
Future<void> crashThenReuse(
  CrashCase crash,
  OpenChannel open, {
  PoolBug bug = PoolBug.none,
}) async {
  final seen = <MontyChannel>[];
  var opened = 0;
  SpawnHandle second() {
    switch (bug) {
      case PoolBug.none:
        return _Recording(open(), seen);
      case PoolBug.slotNeverFreed:
        return _Never();
      case PoolBug.reusesCrashedWorker:
        final [crashed, ...] = seen;

        return _Dead(crashed);
    }
  }

  final pool = await startMonty(
    PoolOptions(
      maxProcesses: 1,
      requestTimeout: crash.requestTimeout,
      checkoutTimeout: _acquisition,
    ),
    open: () => ++opened == 1 ? _Recording(open(), seen) : second(),
    startupTimeout: const Duration(seconds: 3),
  );
  try {
    final session = await pool.checkoutWith(crash.config);
    expect(pool.liveWorkers, 1);
    Object? failure;
    try {
      await session.feedRun(crash.code, printCallback: _ignore);
    } on Object catch (e) {
      failure = e;
    }
    expect(failure, isA<MontyCrashedError>(), reason: 'the crash');
    if (failure is MontyCrashedError) crash.check(failure);
    final [crashedWorker, ...] = seen;
    expect(
      crashedWorker.isAlive,
      isFalse,
      reason: 'the crashed worker is dead',
    );
    expect(pool.liveWorkers, 0, reason: 'the crashed slot was freed');
    await session.close();

    // The same pool, a new checkout, within the acquisition timeout.
    final MontyValue value;
    try {
      value = await pool.withSessionWith(
        (s) => s.feedRun('1 + 1', printCallback: _ignore),
        const SessionConfig(
          limits: ResourceLimits(maxMemory: 64 * 1024 * 1024),
        ),
      );
    } on Object catch (e) {
      throw RecoveryFailure('the second checkout failed: $e');
    }
    if (value != const MontyInt(2)) {
      throw RecoveryFailure('the second checkout answered $value, not 2');
    }
    final reused = switch (seen) {
      [final a, final b] => identical(a, b),
      _ => true,
    };
    if (reused) {
      throw const RecoveryFailure('the crashed worker was reused');
    }
    expect(pool.liveWorkers, 1);
  } finally {
    await pool.close();
    for (final channel in seen) {
      channel.kill();
    }
  }
}

/// Where the crashing code's output goes: nobody reads it.
final _printed = <String>[];

void _ignore(String stream, String text) => _printed.add(text);

/// The crash-recovery tests: each of [cases] on the real [open], and the
/// two controls on the first case.
void crashRecoveryTests(
  String backend,
  List<CrashCase> cases,
  OpenChannel Function(CrashCase) open,
) {
  group('crash recovery through the same pool ($backend)', () {
    for (final c in cases) {
      test(c.name, () => crashThenReuse(c, open(c)));
    }
    final [first, ...] = cases;
    test(
      'control: a pool that never frees the crashed slot fails the '
      'second checkout',
      () => expectLater(
        crashThenReuse(first, open(first), bug: PoolBug.slotNeverFreed),
        throwsA(isA<RecoveryFailure>()),
      ),
    );
    test(
      'control: a pool that reuses the crashed worker fails the run',
      () => expectLater(
        crashThenReuse(first, open(first), bug: PoolBug.reusesCrashedWorker),
        throwsA(isA<RecoveryFailure>()),
      ),
    );
  });
}
