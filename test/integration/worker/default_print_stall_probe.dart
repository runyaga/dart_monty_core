// A program whose sessions flood prints with no print callback while
// nothing reads this process's own stdout: the default sink's writes stall
// once the pipe is full. It checks that the event loop keeps running, that
// reading the worker's output pauses at the read-ahead limit and stays
// bounded, that requestTimeout and then a busy close each end the stalled
// call, and that each freed slot serves a new checkout. It reports on
// stderr, which the test reads.
//
// It ends with exit(): what is left unwritten on the full stdout would
// otherwise hold the exit, which is the stalled pipe's doing, not a session's.
//
// usage: dart default_print_stall_probe.dart <worker executable>
//
// DCM: this is a spawned entry point, not a test.
// ignore_for_file: prefer-correct-test-file-name

import 'dart:async';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/dart_monty_core.dart' show MontyInt;
import 'package:dart_monty_core/src/worker/monty.dart';
import 'package:dart_monty_core/src/worker/monty_channel.dart';
import 'package:dart_monty_core/src/worker/monty_error.dart'
    show MontyCrashedErrorInternal;
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/resource_limits.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';

const _flood = "line = 'x' * 1000\nwhile True:\n    print(line)";

const _limits = SessionConfig(
  limits: ResourceLimits(maxMemory: 64 * 1024 * 1024),
);

/// Timer ticks so far: they stop if a write blocks the isolate.
var _ticks = 0;

Future<void> main(List<String> args) async {
  final ticker = Timer.periodic(
    const Duration(milliseconds: 20),
    (_) => _ticks++,
  );
  try {
    await _stall(args.firstOrNull, byClose: false);
    await _stall(args.firstOrNull, byClose: true);
  } on Object catch (error, stack) {
    stderr.writeln('stall probe failed: $error\n$stack');
    await stderr.flush();
    exit(1);
  }
  ticker.cancel();
  stderr.writeln('stall probe ok');
  await stderr.flush();
  exit(0);
}

/// One flood on a pool of one worker, ended by requestTimeout or by close.
Future<void> _stall(String? worker, {required bool byClose}) async {
  final how = byClose ? 'close' : 'requestTimeout';
  await withMonty(
    (pool) async {
      final session = await pool.checkoutWith(_limits);
      final channel = ProcessChannel.live.singleOrNull;
      if (channel == null) throw StateError('$how: no single worker');
      final ticks = _ticks;
      final ended = _endOf(session.feedRun(_flood));
      // Backpressure engages: reading pauses at the limit. The stall here is
      // this process's own stdout pipe, which the platform may still drain
      // slowly (measured on Linux CI), so the queue can shrink and refill;
      // the bound is the peak below. A second under flood follows, still
      // within the turn. The requestTimeout leaves room for both waits.
      // The bound counts the deliveries the pause lands between, which the
      // VM makes up to about 4 MiB each on a loaded machine.
      await _filled(channel, how);
      await Future<void>.delayed(const Duration(seconds: 1));
      _check(channel.isAlive, '$how: the worker died within the turn');
      if (byClose) await session.close().timeout(const Duration(seconds: 5));
      final error = await ended.timeout(const Duration(seconds: 10));
      _check(
        error is MontyCrashedError && error.cause == CrashCause.killed,
        '$how: the call failed with $error',
      );
      _check(_ticks - ticks >= 10, '$how: ${_ticks - ticks} timer ticks');
      final (:peak, :bound, now: _, paused: _) = channel.readAhead;
      _check(peak < bound, '$how: read-ahead peak $peak, bound $bound');
      await session.close();
      final value = await pool.withSessionWith(
        (s) => s.feedRun('1 + 1'),
        _limits,
      );
      _check(value == const MontyInt(2), '$how: the next checkout ran $value');
    },
    PoolOptions(
      maxProcesses: 1,
      requestTimeout: byClose ? null : const Duration(seconds: 8),
      workerLocation: worker,
    ),
  );
}

/// [channel]'s read-ahead once reading has paused at the limit (the frame in
/// flight at the limit completed), polled for up to 4 s.
Future<int> _filled(ProcessChannel channel, String how) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!channel.readAhead.paused ||
      channel.readAhead.now < ProcessChannel.readAheadLimit) {
    _check(
      DateTime.now().isBefore(deadline),
      '$how: reading never paused at the limit: ${channel.readAhead.now}',
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }

  return channel.readAhead.now;
}

/// What [call] fails with; null if it succeeds.
Future<Object?> _endOf(Future<Object?> call) async {
  try {
    await call;

    return null;
  } on Object catch (error) {
    return error;
  }
}

void _check(bool ok, String what) {
  if (!ok) throw StateError(what);
}
