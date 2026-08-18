@Tags(['integration', 'ffi'])
@TestOn('vm')
library;

// M1 crash-isolation spike — the gate for
// `docs/adr/0001-ffi-crash-isolation.md`.
//
// The file is ordered red-then-green on purpose. The first group asserts the
// DEFECT: run in the caller's own process, a deliberate stack overflow in
// sandboxed Python kills the Dart host outright. Everything after it asserts
// that the same Python, run in a worker process, does not. Neither half means
// much alone; together they are the measurement the design decision rests on.
//
// One file rather than two, deliberately: `dart test` runs FILES concurrently
// and TESTS within a file sequentially, and every test here spawns `dart run`,
// which stages native assets into the shared `.dart_tool/lib/`. Two concurrent
// spawns race there — measured, as `install_name_tool: cannot rename
// .dart_tool/lib/libdart_monty_core_native.dylib` and a worker that exits 1
// before its handshake. Keeping them in one file makes the spawns sequential.
// The shipping path (an AOT worker built with `dart build cli`) does not stage
// anything and is not exposed to this; see the ADR.
//
// THERE IS NO `wasm_` TWIN, and that is a statement, not an omission. Process
// isolation is what this file measures, and the web backend has no processes —
// it isolates with Workers, which the pool reaches through a different channel
// (M2). What the two backends genuinely SHARE is the framing and the protocol,
// and those are covered on the VM, dart2js and dart2wasm alike by
// `test/unit/frame_codec_test.dart`. Anything added here that is not
// process-specific belongs there instead, where all three compilers see it.
import 'dart:io';
import 'dart:isolate';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/pool/worker_protocol.dart';
import 'package:test/test.dart';

import 'pool/worker_handle.dart';

/// Python that overflows the native stack rather than raising RecursionError.
///
/// The default `stackDepth` is 1000 (`base_monty_platform.dart:81`), which the
/// interpreter checks and turns into a clean `RecursionError`. Raising the
/// limit to 100000 lets the guest recurse past the real OS stack, and THAT the
/// interpreter cannot check — the abort happens below it.
const _overflow = FeedRunRequest('''
def f(n):
    return f(n + 1)
f(0)
''');

/// A session whose recursion bound is far above what the OS stack can hold.
///
/// 100000 was chosen by measurement on macOS arm64, where it overflows an 8 MB
/// stack well before the interpreter's own counter is reached. **If this suite
/// ever fails on another platform with the worker exiting 0 or returning a
/// `RecursionError`, the bound is too LOW for that platform's stack — raise it.
/// Do not weaken `_isAbort`.** The two failures look nothing alike: a bound
/// that is too low produces a clean result, while a genuinely contained crash
/// produces a fatal signal. Only the first is a reason to touch this number.
const _overflowSession = CreateSessionRequest(
  limits: MontyLimits(stackDepth: 100000),
);

/// A default, unbounded session — the shape most of these tests want.
const _session = CreateSessionRequest();

/// Matches a run that completed with [value] as its rendered result.
Matcher _ranTo(Object value) =>
    isA<WorkerRunResult>().having((r) => r.value, 'value', value);

/// Matches a run that completed by raising, with [error] in the message.
Matcher _raised(Object error) =>
    isA<WorkerRunResult>().having((r) => r.pythonError, 'pythonError', error);

/// Matches a request that failed because the worker process died.
final Matcher _crashes = throwsA(isA<MontyWorkerCrashed>());

/// True when [exitCode] means "destroyed by a fatal signal we did not send".
///
/// Asserting one exact signal number would assert a platform detail rather than
/// the property under test. Measured on macOS arm64 as SIGILL — `-4` from a
/// direct child, `132` (128 + 4) when a launcher reports its child's status
/// shell-style. On Linux the same overflow is as likely to surface as SIGSEGV
/// from the guard page or SIGABRT from Rust's handler, depending which wins.
/// Those are all the same event: the process was destroyed rather than
/// returning.
///
/// SIGKILL is excluded deliberately — it is what the parent's own deadline
/// sends, so accepting it would let the timeout tests and the crash tests pass
/// for each other's reasons.
bool _isAbort(int exitCode) =>
    exitCode != 0 &&
    exitCode != -ProcessSignal.sigkill.signalNumber &&
    exitCode != 128 + 9 &&
    (exitCode < 0 || exitCode > 128);

void main() {
  group('the defect this exists to contain', () {
    test(
      'in-process, a sandboxed stack overflow kills the Dart host',
      () async {
        // Not written as a normal assertion because it cannot be: the process
        // does not fail, it dies, and a dead process reports nothing to a test
        // runner. So the subject is a separate program and its EXIT CODE is the
        // observation — the only channel an abort leaves open.
        //
        // Measured on macOS arm64, 2026-08-16: exit 132, i.e. SIGILL from
        // Rust's `abort`. No Dart exception, no `MontyResult.error`, and
        // `catch_ffi_panic` (`native/src/lib.rs:34`) does not fire — it guards
        // Rust *panics*, and an abort is not a panic.
        final libUri = await Isolate.resolvePackageUri(
          Uri.parse('package:dart_monty_core/dart_monty_core.dart'),
        );
        final packageRoot = File.fromUri(libUri!).parent.parent;
        final result = await Process.run(Platform.resolvedExecutable, [
          'run',
          '${packageRoot.path}/test/integration/pool/inprocess_overflow.dart',
        ]);

        expect(
          result.stdout.toString(),
          isNot(contains('SURVIVED')),
          reason:
              'the in-process host returned from the overflow. If this is now '
              'true, upstream or the shim gained a stack guard, and '
              'docs/adr/0001-ffi-crash-isolation.md must be re-derived rather '
              'than relaxed.',
        );
        expect(
          _isAbort(result.exitCode),
          isTrue,
          reason:
              'expected a fatal abort; got exit ${result.exitCode}\n'
              'stdout: ${result.stdout}\nstderr: ${result.stderr}',
        );
      },
      timeout: const Timeout(Duration(minutes: 2)),
    );
  });

  group('worker channel', () {
    test('completes a round trip and reports the value', () async {
      final worker = await MontyWorkerHandle.spawn();
      addTearDown(worker.kill);

      expect(worker.wireFormatVersion, 4);
      expect(worker.pid, greaterThan(0));

      // The process the parent can signal IS the process running the
      // interpreter. Were `dart run` a launcher that forked the real program,
      // `Process.kill` would land on the launcher and the interpreter would
      // keep running — hard preemption would be a claim with nothing behind
      // it, and every timeout test below would still pass.
      expect(
        worker.pid,
        worker.osPid,
        reason:
            'the spawned pid and the interpreter pid diverged; the pool must '
            'kill the process GROUP, not the process',
      );

      await worker.request(_session);
      final reply = await worker.request(const FeedRunRequest('2 + 2'));

      expect(reply, _ranTo('MontyInt(4)'));
      expect(reply, _raised(isNull));
      expect(await worker.shutdown(), 0);
    });

    test('a Python exception is a result, not a worker failure', () async {
      // The distinction the pool contract depends on: the session survives a
      // Python error, so the parent must not recycle the worker for one. If
      // this regresses into a crash, the pool starts discarding healthy
      // workers over ordinary user mistakes.
      final worker = await MontyWorkerHandle.spawn();
      addTearDown(worker.kill);

      await worker.request(_session);
      final bad = await worker.request(const FeedRunRequest('1 / 0'));
      expect(bad, _raised(contains('ZeroDivisionError')));

      final good = await worker.request(const FeedRunRequest('"alive"'));
      expect(good, _ranTo(contains('alive')));
      expect(worker.isClosed, isFalse);
    });

    test('an unserviceable request is answered, not fatal', () async {
      // Version skew must not take the worker down: asking for something this
      // build cannot serve is a REPLY, and the session stays usable after it.
      //
      // `feedRun` before `create` is the reachable case. A genuinely unknown
      // op cannot be constructed at all through the sealed request type —
      // which is the point of typing the protocol, and is why the worker-side
      // `parseWorkerRequest` fallback is covered by the codec tests instead.
      final worker = await MontyWorkerHandle.spawn();
      addTearDown(worker.kill);

      final reply = await worker.request(const FeedRunRequest('1'));
      expect(reply, isA<WorkerUnsupported>());
      expect(worker.isClosed, isFalse);

      // And the session still works once it is actually created.
      await worker.request(_session);
      expect(
        await worker.request(const FeedRunRequest('7 * 6')),
        _ranTo('MontyInt(42)'),
      );
    });
  });

  group('crash containment', () {
    test('a stack overflow kills the worker and the parent survives', () async {
      final worker = await MontyWorkerHandle.spawn();
      addTearDown(worker.kill);
      final workerPid = worker.pid;

      await worker.request(_overflowSession);

      await expectLater(
        worker.request(_overflow),
        _crashes,
      );

      // The child died the way the in-process baseline died — that is what
      // makes this an isolation result and not a "the worker handled it"
      // result. Nothing handled it; the blast was contained.
      final code = await worker.exitCode;
      expect(
        _isAbort(code),
        isTrue,
        reason: 'expected an abort, got exit code $code',
      );

      // The reason this test exists: the two lines below run at all.
      expect(pid, isNot(workerPid));
      expect(2 + 2, 4);
    });

    test('the pool can respawn after a crash', () async {
      // Containment is only half of the property. A parent that survives but
      // cannot serve the next request has traded a crash for an outage.
      final crashed = await MontyWorkerHandle.spawn();
      await crashed.request(_overflowSession);
      await expectLater(
        crashed.request(_overflow),
        _crashes,
      );

      final replacement = await MontyWorkerHandle.spawn();
      addTearDown(replacement.kill);
      await replacement.request(_session);
      final reply = await replacement.request(const FeedRunRequest('40 + 2'));

      expect(reply, _ranTo('MontyInt(42)'));
      expect(replacement.pid, isNot(crashed.pid));
    });

    test('a request after the crash fails typed, not by hanging', () async {
      final worker = await MontyWorkerHandle.spawn();
      addTearDown(worker.kill);
      await worker.request(_overflowSession);
      await expectLater(
        worker.request(_overflow),
        _crashes,
      );

      await expectLater(
        worker.request(const FeedRunRequest('1')),
        _crashes,
      );
    });
  });

  group('parent-side deadline', () {
    test(
      'SIGKILLs a hang that in-VM limits cannot see',
      () async {
        // `MontyLimits.timeoutMs` is polled at interpreter checkpoints. The
        // parent-side deadline needs no cooperation at all, which is why it is
        // the only hard preemption available and why the chosen option had to
        // keep it (upstream's `request_timeout` / `PoolError::Timeout`).
        final worker = await MontyWorkerHandle.spawn();
        addTearDown(worker.kill);
        await worker.request(_session);

        await expectLater(
          worker.request(
            const FeedRunRequest('while True:\n    pass\n'),
            deadline: const Duration(seconds: 2),
          ),
          // `MontyWorkerTimedOut` has exactly one source — the parent's
          // watchdog — so its type IS the evidence that the deadline fired.
          // Deliberately NOT asserted by wall clock: an earlier version
          // checked `elapsed < 20s` and failed once at 381 s in a run where
          // the test framework's own 90 s timeout also did not fire, i.e. the
          // runner's event loop was starved, not the mechanism broken. The
          // same case measured 2 722 ms standalone. Gating a correctness claim
          // on a shared runner's scheduling latency tests the runner, not the
          // design; the latency number belongs in `tool/pool_bench.dart`,
          // which reports rather than gates.
          throwsA(isA<MontyWorkerTimedOut>()),
        );

        final code = await worker.exitCode.timeout(const Duration(seconds: 30));
        expect(
          code,
          -ProcessSignal.sigkill.signalNumber,
          reason: 'the hang was ended by SIGKILL, not by cooperating',
        );
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  });

  group('SIGCHLD', () {
    test(
      'a Dart parent reaping its own children does not disturb the worker, '
      'and vice versa',
      () async {
        // The standing rule this settles: Dart FFI host code must not spawn
        // subprocesses, because a Rust-side reaper races Dart's own SIGCHLD
        // handling. Option A moves the spawning to Dart, so there is exactly
        // one reaper — Dart's. This test is the empirical half of that claim:
        // run both kinds of child concurrently in one parent and show neither
        // loses an exit status.
        final worker = await MontyWorkerHandle.spawn();
        addTearDown(worker.kill);
        await worker.request(_session);

        const rounds = 30;
        final noise = <Future<ProcessResult>>[
          for (var i = 0; i < rounds; i++)
            Process.run('/bin/sh', ['-c', 'exit $i']),
        ];

        // Interleave interpreter work with the reaping rather than running one
        // phase after the other: a race that only appears under overlap would
        // survive a sequential test.
        final replies = <WorkerReply>[];
        for (var i = 0; i < rounds; i++) {
          replies.add(await worker.request(FeedRunRequest('$i + 1')));
        }

        final results = await Future.wait(noise);
        for (final (i, result) in results.indexed) {
          expect(
            result.exitCode,
            i,
            reason: 'unrelated child $i lost or corrupted its exit status',
          );
        }
        for (final (i, reply) in replies.indexed) {
          expect(reply, _ranTo('MontyInt(${i + 1})'));
        }

        // And the worker is still the worker: its own exit status is intact
        // and was not consumed by the reaping above.
        expect(worker.isClosed, isFalse);
        expect(await worker.shutdown(), 0);
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );

    test(
      'a crashing worker still reports its exit code while other children '
      'are being reaped',
      () async {
        // The sharper version: the exit status that matters is the one
        // produced WHILE `Process.run` calls are in flight. If anything else
        // could reap it, the crash would surface as a hang instead of a typed
        // error.
        final worker = await MontyWorkerHandle.spawn();
        addTearDown(worker.kill);
        await worker.request(_overflowSession);

        final noise = <Future<ProcessResult>>[
          for (var i = 0; i < 20; i++)
            Process.run('/bin/sh', ['-c', 'sleep 0.1; exit 7']),
        ];

        await expectLater(
          worker.request(_overflow),
          throwsA(isA<MontyWorkerCrashed>()),
        );
        final code = await worker.exitCode.timeout(const Duration(seconds: 30));
        expect(_isAbort(code), isTrue, reason: 'got exit code $code');

        for (final result in await Future.wait(noise)) {
          expect(result.exitCode, 7);
        }
      },
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });
}
