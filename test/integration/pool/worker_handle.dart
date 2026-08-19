// Parent-side half of the M1 crash-isolation spike.
//
// Deliberately NOT in `lib/`. `lib/` has zero `dart:io` today
// (`grep -rn 'dart:io' lib --include='*.dart' | wc -l` → 0) and that property
// is what keeps the web compilers able to see the whole library. The spike must
// not spend it: the decision about where a `dart:io` arm eventually lands
// (`package:dart_monty_core/pool.dart`, behind a `dart.library.io` conditional,
// with a CI grep pinning the invariant) belongs to the milestone that ships the
// pool, not to the milestone that proves the pool is worth shipping.
//
// What this is: spawn a worker, hand it framed requests, hold a PARENT-SIDE
// deadline, and observe its death without dying. That last part is the entire
// point — see `docs/adr/0001-ffi-crash-isolation.md`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:dart_monty_core/src/ffi/native_bindings.dart'
    show expectedWireFormatVersion;
import 'package:dart_monty_core/src/pool/frame_codec.dart';
import 'package:dart_monty_core/src/pool/worker_protocol.dart';

/// A failure of the worker or the channel, as distinct from a failure of the
/// Python program the worker was asked to run.
///
/// Sealed, and typed per cause, because the parent's response differs by cause:
/// a crash means discard-and-respawn, a timeout means the worker was killed on
/// purpose, and a spawn failure means the deployment is wrong. Sniffing a
/// message string for the difference is how that distinction gets lost.
sealed class MontyWorkerException implements Exception {}

/// The worker process died.
final class MontyWorkerCrashed implements MontyWorkerException {
  /// Creates a [MontyWorkerCrashed] for a worker that exited with [exitCode].
  const MontyWorkerCrashed(this.exitCode, {this.stderrTail = ''});

  /// The child's exit code. Negative or >128 values encode a fatal signal.
  final int exitCode;

  /// Whatever the child wrote to stderr before dying, for diagnosis.
  final String stderrTail;

  @override
  String toString() =>
      'MontyWorkerCrashed(exitCode: $exitCode)'
      '${stderrTail.isEmpty ? '' : '\n--- worker stderr ---\n$stderrTail'}';
}

/// The parent's deadline fired and the worker was killed.
///
/// This is hard preemption from OUTSIDE the interpreter.
/// `MontyLimits.timeoutMs` is checked at interpreter checkpoints, so it cannot
/// stop code that never reaches one; `SIGKILL` needs no cooperation from the
/// target at all.
final class MontyWorkerTimedOut implements MontyWorkerException {
  /// Creates a [MontyWorkerTimedOut] for a request that exceeded [limit].
  const MontyWorkerTimedOut(this.limit);

  /// The deadline that was armed.
  final Duration limit;

  @override
  String toString() => 'MontyWorkerTimedOut(limit: $limit)';
}

/// The worker could not be started, or never completed its handshake.
final class MontyWorkerSpawnFailed implements MontyWorkerException {
  /// Creates a [MontyWorkerSpawnFailed] described by [detail].
  const MontyWorkerSpawnFailed(this.detail);

  /// What went wrong.
  final String detail;

  @override
  String toString() => 'MontyWorkerSpawnFailed: $detail';
}

/// The worker broke the framing contract.
///
/// An `Error`, not an `Exception`: a protocol violation is a bug in this
/// package, not a condition a caller can sensibly recover from.
final class MontyWorkerProtocolError extends Error {
  /// Creates a [MontyWorkerProtocolError] described by [detail].
  MontyWorkerProtocolError(this.detail);

  /// What was violated.
  final String detail;

  @override
  String toString() => 'MontyWorkerProtocolError: $detail';
}

/// The largest SDK preamble tolerated before the frame marker must appear.
const int _maxPreambleBytes = 64 * 1024;

/// A live worker process and the frame channel to it.
final class MontyWorkerHandle {
  MontyWorkerHandle._(
    this._process,
    this.pid,
    this.wireFormatVersion,
    this._stderrBuffer,
  );

  /// The child's OS process id, **as the child itself reported it**.
  ///
  /// Compared against [osPid] rather than assumed equal to it. If a launcher
  /// ever forked the real interpreter into a grandchild, the parent's
  /// `Process.kill` would land on the launcher while the interpreter kept
  /// running — and the hard-preemption claim in
  /// `docs/adr/0001-ffi-crash-isolation.md` would be false without anything
  /// looking wrong. The identity is asserted in `ffi_pool_spike_test.dart`.
  final int pid;

  /// The value-encoding version the child announced.
  ///
  /// Checked against the parent's own, so a parent and worker built from
  /// different trees fail at spawn instead of mis-decoding values later.
  final int wireFormatVersion;

  final Process _process;

  /// Shared with the subscription established during [spawn]. `Process.stderr`
  /// is single-subscription, so the buffer is handed over rather than re-read.
  final StringBuffer _stderrBuffer;

  final _pending = <int, Completer<WorkerReply>>{};
  var _nextId = 1;
  var _isClosed = false;
  int? _exitCode;

  /// The pid the parent spawned, i.e. the one [kill] signals.
  int get osPid => _process.pid;

  /// The child's exit code, once it has exited.
  Future<int> get exitCode => _process.exitCode;

  /// Whether the channel has been closed by exit, timeout, or [kill].
  bool get isClosed => _isClosed;

  /// Whatever the child has written to stderr so far.
  String get stderrText => _stderrBuffer.toString();

  /// Resolves the repository's own worker entrypoint.
  ///
  /// Derived from the package's resolved `lib/` URI rather than
  /// `Directory.current`, so it is correct regardless of where the test runner
  /// happened to set the working directory.
  static Future<String> resolveWorkerScript() async {
    final libUri = await Isolate.resolvePackageUri(
      Uri.parse('package:dart_monty_core/dart_monty_core.dart'),
    );
    if (libUri == null) {
      throw const MontyWorkerSpawnFailed(
        'could not resolve package:dart_monty_core',
      );
    }
    final packageRoot = File.fromUri(libUri).parent.parent;

    return '${packageRoot.path}/bin/monty_worker.dart';
  }

  /// Spawns a worker and waits for its ready handshake.
  ///
  /// The expected wire version is READ from `native_bindings.dart`, never
  /// passed in. It used to be a parameter defaulting to a literal `4`, which
  /// went silently wrong the moment the value wire moved to 5 at the monty
  /// v0.0.21 pin: the worker announced v5 and the parent rejected it, two
  /// halves of the SAME build disagreeing. A handshake whose expected value is
  /// duplicated cannot detect drift — it manufactures it.
  ///
  /// [executable]/[arguments] default to running this repo's own
  /// `bin/monty_worker.dart` under the current Dart SDK — the dev/JIT path,
  /// which needs no build step. An AOT bundle is passed explicitly instead.
  static Future<MontyWorkerHandle> spawn({
    String? executable,
    List<String>? arguments,
    Duration readyTimeout = const Duration(seconds: 60),
  }) async {
    final exe = executable ?? Platform.resolvedExecutable;
    final args = arguments ?? ['run', await resolveWorkerScript()];

    final Process process;
    try {
      process = await Process.start(exe, args);
    } on ProcessException catch (e) {
      throw MontyWorkerSpawnFailed('$exe ${args.join(' ')}: ${e.message}');
    }

    final ready = Completer<Map<String, Object?>>();
    final frames = StreamController<Map<String, Object?>>();
    final stderrBuffer = StringBuffer();

    process.stderr.transform(utf8.decoder).listen(stderrBuffer.write);
    _pipeFrames(process, ready, frames);
    unawaited(_failHandshakeOnEarlyExit(process, ready, stderrBuffer));

    final Map<String, Object?> hello;
    try {
      hello = await ready.future.timeout(readyTimeout);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      throw MontyWorkerSpawnFailed(
        'no handshake within $readyTimeout'
        '${stderrBuffer.isEmpty ? '' : '\n$stderrBuffer'}',
      );
    }

    if (hello['type'] != 'ready') {
      process.kill(ProcessSignal.sigkill);
      throw MontyWorkerProtocolError('first frame was $hello, expected ready');
    }
    final version = hello['wireFormatVersion'];
    if (version != expectedWireFormatVersion) {
      process.kill(ProcessSignal.sigkill);
      throw MontyWorkerProtocolError(
        'worker announced wire format v$version, parent expects '
        'v$expectedWireFormatVersion',
      );
    }

    final handle = MontyWorkerHandle._(
      process,
      hello['pid']! as int,
      version! as int,
      stderrBuffer,
    );
    frames.stream.listen(handle._onFrame, onError: handle._failAll);
    unawaited(handle._watchForExit());

    return handle;
  }

  /// Sends one request and awaits its reply.
  ///
  /// [deadline] is armed on the PARENT. When it fires the worker is SIGKILLed
  /// and this throws [MontyWorkerTimedOut]. Nothing about that path asks the
  /// child to cooperate, which is why it also covers a hang the in-VM limits
  /// cannot see.
  Future<WorkerReply> request(
    WorkerRequest payload, {
    Duration? deadline,
  }) {
    if (_isClosed) {
      return Future.error(
        MontyWorkerCrashed(
          _exitCode ?? -1,
          stderrTail: _stderrBuffer.toString().trim(),
        ),
        StackTrace.current,
      );
    }
    final id = _nextId++;
    final completer = Completer<WorkerReply>();
    _pending[id] = completer;

    Timer? watchdog;
    if (deadline != null) {
      watchdog = Timer(deadline, () {
        if (completer.isCompleted) return;

        _pending.remove(id);
        _isClosed = true;
        _process.kill(ProcessSignal.sigkill);
        completer.completeError(
          MontyWorkerTimedOut(deadline),
          StackTrace.current,
        );
      });
    }

    _process.stdin.add(encodeFrame({...payload.toFrame(), 'id': id}));

    return completer.future.whenComplete(() => watchdog?.cancel());
  }

  /// Kills the worker immediately.
  void kill() {
    _isClosed = true;
    _process.kill(ProcessSignal.sigkill);
  }

  /// Asks the worker to exit cleanly, then waits for it.
  Future<int> shutdown() async {
    if (!_isClosed) {
      try {
        await request(
          const ShutdownRequest(),
        ).timeout(const Duration(seconds: 10));
      } on Object catch (_) {
        // A worker that will not answer a shutdown is killed below; reporting
        // the failure to exit cleanly is not useful to a caller that is
        // discarding it either way.
        _isClosed = true;
      }
      _isClosed = true;
    }
    try {
      await _process.stdin.close();
    } on Object catch (e) {
      // Usually means the child is already gone, so its pipe is already shut.
      // Not fatal — the caller wants an exit code and that still arrives — but
      // recorded rather than swallowed, so a genuinely odd close is visible.
      _stderrBuffer.write('\n[handle] closing worker stdin failed: $e');
    }

    return _process.exitCode.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _process.kill(ProcessSignal.sigkill);

        return _process.exitCode;
      },
    );
  }

  /// Reassembles the child's stdout into frames, skipping the SDK preamble.
  static void _pipeFrames(
    Process process,
    Completer<Map<String, Object?>> ready,
    StreamController<Map<String, Object?>> frames,
  ) {
    final reader = FrameReader();
    // Everything before `frameStreamMagic` is SDK noise on the child's stdout
    // (`dart run` announces its build hooks there, before the child's `main`).
    // Skipped once, at handshake — never again.
    final preamble = <int>[];
    var synced = false;

    process.stdout.listen(
      (chunk) {
        if (synced) {
          reader.add(chunk);
        } else {
          preamble.addAll(chunk);
          final at = indexOfFrameMagic(preamble);
          if (at < 0) {
            if (preamble.length > _maxPreambleBytes) {
              frames.addError(
                MontyWorkerProtocolError(
                  'no frame marker in the first ${preamble.length} bytes of '
                  'worker stdout; it is not speaking this protocol',
                ),
              );
            }

            return;
          }
          synced = true;
          final tail = preamble.sublist(at + frameStreamMagic.length);
          preamble.clear();
          reader.add(tail);
        }
        while (true) {
          final Map<String, Object?>? frame;
          try {
            frame = reader.next();
          } on FrameFormatException catch (e) {
            frames.addError(MontyWorkerProtocolError(e.message));

            return;
          }
          if (frame == null) break;

          if (ready.isCompleted) {
            frames.add(frame);
          } else {
            ready.complete(frame);
          }
        }
      },
      onDone: () => unawaited(frames.close()),
    );
  }

  /// Turns a death during startup into a spawn failure rather than a timeout.
  ///
  /// Without this, a worker that dies before its handshake leaves the caller
  /// waiting out `readyTimeout` and then reporting a slow spawn for what was
  /// actually a crash — the wrong diagnosis, arrived at slowly.
  static Future<void> _failHandshakeOnEarlyExit(
    Process process,
    Completer<Map<String, Object?>> ready,
    StringBuffer stderrBuffer,
  ) async {
    final code = await process.exitCode;
    if (ready.isCompleted) return;

    ready.completeError(
      MontyWorkerSpawnFailed(
        'worker exited with $code before handshake'
        '${stderrBuffer.isEmpty ? '' : '\n$stderrBuffer'}',
      ),
      StackTrace.current,
    );
  }

  Future<void> _watchForExit() async {
    final code = await _process.exitCode;
    _exitCode = code;
    _isClosed = true;
    _failAll(
      MontyWorkerCrashed(code, stderrTail: _stderrBuffer.toString().trim()),
    );
  }

  void _onFrame(Map<String, Object?> frame) {
    final id = frame['id'];
    if (id is! int) {
      _failAll(MontyWorkerProtocolError('frame without an int id: $frame'));

      return;
    }
    final reply = parseWorkerReply(frame);
    if (reply == null) {
      // An unintelligible reply means the ends disagree about the wire. Unlike
      // an unknown *request*, there is nothing safe to do with the session
      // afterwards, so this fails everything rather than dropping one frame.
      _failAll(MontyWorkerProtocolError('unreadable reply frame: $frame'));

      return;
    }
    _pending.remove(id)?.complete(reply);
  }

  void _failAll(Object error) {
    final waiting = _pending.values.toList();
    _pending.clear();
    for (final completer in waiting) {
      if (!completer.isCompleted) {
        completer.completeError(error, StackTrace.current);
      }
    }
  }
}
