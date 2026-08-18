// The out-of-process interpreter worker (M1 spike).
//
// Why this exists — measured, not argued: with the interpreter in the caller's
// own process, this Python
//
//     def f(n):
//         return f(n + 1)
//     f(0)
//
// run with `MontyLimits(stackDepth: 100000)` kills the *Dart host* with exit
// 132 (SIGILL from Rust's `abort`). No Dart exception, no `MontyResult.error`,
// no `catch_ffi_panic` — `native/src/lib.rs` guards Rust *panics*, and a stack
// overflow is an abort, not a panic. Every session in the process dies with it.
//
// So the interpreter runs here instead, in a child process the parent can lose.
// This binary is the "worker" half of that arrangement: it speaks
// length-prefixed JSON frames (`lib/src/pool/frame_codec.dart`) on stdin/stdout
// and holds exactly one `MontyRepl`.
//
// SCOPE: this is the M1 spike, not the finished pool. It proxies three
// operations (`create`, `feedRun`, `dispose`) plus a `ping` for latency
// measurement — enough to carry a real interpreter session, and therefore
// enough to carry a real crash. The full `ReplBindings` proxy (15 methods,
// `lib/src/repl/repl_bindings.dart`) is M2 work; see
// `docs/adr/0001-ffi-crash-isolation.md`.
//
// Invariant: stdout carries frames and NOTHING else. Python `print()` is
// captured by the REPL and returned inside a frame; anything that writes to
// stdout out of band corrupts the stream for the parent. Diagnostics go to
// stderr, which the parent passes through.
import 'dart:async';
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/native_bindings.dart'
    show expectedWireFormatVersion;
import 'package:dart_monty_core/src/pool/frame_codec.dart';

import 'package:dart_monty_core/src/pool/worker_protocol.dart';

Future<void> main() async {
  final worker = _MontyWorker();
  await worker.serve();
}

final class _MontyWorker {
  MontyRepl? _repl;

  Future<void> serve() async {
    // Everything the SDK wrote to our stdout before `main()` ran precedes this
    // marker; the parent discards up to it. See `frameStreamMagic` for the
    // measurement that makes it necessary.
    //
    // The handshake that follows mirrors the web bridge's
    // `{type:'ready', wireFormatVersion}` (`js/src/worker_src.js:41-48`) so
    // both channels announce themselves the same way. `pid` is here because
    // the parent's watchdog needs a target it can report even after
    // `Process.kill` has made the handle uninformative.
    stdout
      ..add(frameStreamMagic)
      ..add(
        encodeFrame({
          'type': 'ready',
          'wireFormatVersion': expectedWireFormatVersion,
          'pid': pid,
        }),
      );
    await stdout.flush();

    final reader = FrameReader();
    // One request in flight at a time: a checkout owns its worker exclusively,
    // so there is no multiplexing to design, and `await`ing inside the stream
    // loop is what enforces it — the subscription stays paused until the
    // current request has answered.
    await for (final chunk in stdin) {
      reader.add(chunk);
      while (true) {
        final Map<String, Object?>? frame;
        try {
          frame = reader.next();
        } on FrameFormatException catch (e) {
          stderr.writeln('monty_worker: $e');
          exit(70);
        }
        if (frame == null) break;

        final done = await _serveFrame(frame);
        await stdout.flush();
        if (done) return;
      }
    }
  }

  /// Serves one frame. Returns `true` when the worker should stop serving.
  Future<bool> _serveFrame(Map<String, Object?> frame) async {
    final id = frame['id'];
    final request = parseWorkerRequest(frame);
    if (request == null) {
      _send(id, WorkerUnsupported('unknown op: ${frame['op']}'));

      return false;
    }

    try {
      switch (request) {
        case PingRequest():
          // The empty round trip. Its whole purpose is to be measurable: it
          // isolates framing + pipe + scheduling from anything the interpreter
          // does, which is the number that decides whether this design is
          // affordable at all.
          _send(id, const WorkerAck());

        case CreateSessionRequest(:final scriptName, :final limits):
          _repl = MontyRepl(scriptName: scriptName, limits: limits);
          _send(id, const WorkerAck());

        case FeedRunRequest(:final code):
          final repl = _repl;
          if (repl == null) {
            _send(id, const WorkerUnsupported('feedRun before create'));
            break;
          }
          final result = await repl.feedRun(code);
          _send(
            id,
            WorkerRunResult(
              value: result.value.toString(),
              pythonError: result.error?.toString(),
              printOutput: result.printOutput,
            ),
          );

        case DisposeSessionRequest():
          await _repl?.dispose();
          _repl = null;
          _send(id, const WorkerAck());

        case ShutdownRequest():
          await _repl?.dispose();
          _repl = null;
          _send(id, const WorkerAck());

          return true;
      }
    } on Object catch (e) {
      // Anything Dart can still catch is reported as a failed request, not as
      // a dead worker — the parent decides what to do with it. What this
      // handler CANNOT catch is the case this whole binary exists for: an
      // abort takes the process out from under it, and the parent learns about
      // that from the exit code, not from a frame.
      _send(id, WorkerFailure(e.toString()));
    }

    return false;
  }

  void _send(Object? id, WorkerReply reply) {
    stdout.add(encodeFrame({...reply.toFrame(), 'id': id}));
  }
}
