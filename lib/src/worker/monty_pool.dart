/// The pool of workers behind sessions: upstream's `AsyncMonty`.
///
/// Becomes the public `Monty` at the cutover; until then it is internal and
/// takes its settings as internal records.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';

import 'package:dart_monty_core/src/worker/pool_session.dart';
import 'package:dart_monty_core/src/worker/proto_session.dart';
import 'package:dart_monty_core/src/worker/worker_pool.dart';

/// A pool of Python workers, each dedicated to one session at a time.
///
/// [withPool] and [withSession] are the way to use it: they close what they
/// open on every exit path. A live worker keeps the Dart process from
/// exiting, so a pool from [start] and a session from [checkout] must each
/// be closed. (A session collected unclosed has its worker killed by a
/// finalizer, but only if the collector runs it, which nothing guarantees.)
///
/// With [start]'s default `checkoutTimeout` of null a [checkout] waits for
/// a free worker forever, as upstream's does: a pool whose every worker is
/// held by a session that waits on another checkout hangs. Code that nests
/// checkouts sets a `checkoutTimeout` or sizes `maxProcesses` for them.
///
/// A busy native worker outlives a parent that dies without closing it,
/// until the worker's own duration limit ends the run; an idle one exits
/// when its stdin reaches end-of-file.
final class MontyPool {
  const MontyPool._(this._pool);

  final WorkerPool _pool;

  /// Starts a pool as [options] say, with `minProcesses` workers ready,
  /// failing if any of them cannot start (upstream `AsyncMonty`).
  ///
  /// [PoolOptions] carries upstream's settings: the pool's size, the
  /// checkout and request timeouts, recycling, the two duration-backstop
  /// graces and the worker's location. An internal record until the
  /// cutover decides the public signature.
  static Future<MontyPool> start({
    PoolOptions options = const PoolOptions(),
  }) => startWith(options);

  /// [start] with [options], and [open] in place of the platform's channel
  /// factory: for tests, and for harnesses that must see each worker.
  static Future<MontyPool> startWith(
    PoolOptions options, {
    OpenChannel? open,
    Duration startupTimeout = WorkerPool.defaultStartupTimeout,
  }) async =>
      MontyPool._(await WorkerPool.start(options, open, startupTimeout));

  /// Runs [body] with a pool started as [start] does with [options], and
  /// closes the pool however [body] ends: the form of upstream's
  /// `async with AsyncMonty()`.
  static Future<T> withPool<T>(
    Future<T> Function(MontyPool pool) body, {
    PoolOptions options = const PoolOptions(),
  }) async {
    final pool = await start(options: options);
    try {
      return await body(pool);
    } finally {
      await pool.close();
    }
  }

  /// Dedicates a worker to a new session configured as [options] say: its
  /// script name, limits, type check, assert annotations, print flush
  /// interval and OS policy ([SessionConfig], an internal record until the
  /// cutover).
  ///
  /// Throws [ArgumentError] for a setting upstream refuses, with upstream's
  /// message, before any worker is taken; and for an IANA zone name the
  /// worker does not know, once it has tried it. Waits for a free worker up
  /// to the pool's `checkoutTimeout`, then throws [TimeoutException].
  /// Throws [StateError] once the pool is closed.
  Future<PoolSession> checkout({
    SessionConfig options = const SessionConfig(),
  }) async {
    options.validate();

    return openPoolSession(await _pool.acquire(), _pool.options, options);
  }

  /// Runs [body] with a session from [checkout] with [options], and closes
  /// the session however [body] ends: the form of upstream's
  /// `async with pool.checkout()`.
  Future<T> withSession<T>(
    Future<T> Function(PoolSession session) body, {
    SessionConfig options = const SessionConfig(),
  }) async {
    final session = await checkout(options: options);
    try {
      return await body(session);
    } finally {
      await session.close();
    }
  }

  /// Refuses new checkouts and ends the idle workers. Sessions still open
  /// run on; each one's close then kills its worker. Idempotent.
  Future<void> close() => _pool.close();

  /// Idle workers now (upstream `idle_workers`). Diagnostics and tests:
  /// stale once returned.
  int get idleWorkers => _pool.idleWorkers;

  /// Slots taken now: idle, checked-out and starting workers. Diagnostics
  /// and tests: stale once returned.
  int get liveWorkers => _pool.liveWorkers;
}
