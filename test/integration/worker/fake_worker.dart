// A scripted stand-in for the worker executable, for ProcessChannel's tests.
//
// Run as `dart fake_worker.dart <scenario>`. It reads framed requests on stdin
// like the real worker and misbehaves the one way its scenario names, so each
// failure the channel must classify can be produced on demand and without a
// Rust build.
//
// DCM: this is a spawned entry point, not a test.
// ignore_for_file: prefer-correct-test-file-name

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/worker/frame.dart';
import 'package:dart_monty_core/src/worker/proto/monty/v1/monty.pb.dart' as pb;

/// The last line the `stderr` scenario writes, after 10 KiB of filler.
const stderrLastLine = "thread 'monty-worker' has overflowed its stack";

/// The message the `fatal` scenario sends.
const fatalMessage = 'protocol version 999 is not supported';

Future<void> main(List<String> args) async {
  final scenario = args.firstOrNull ?? 'serve';
  final decoder = FrameDecoder();
  await for (final chunk in stdin) {
    for (final body in decoder.add(chunk)) {
      await _handle(scenario, pb.ParentRequest.fromBuffer(body));
    }
  }
  if (scenario != 'ignore-shutdown') exit(0);
  // Keeps running after stdin closes, as a wedged worker would. A pending
  // timer, not a bare Completer: an isolate with nothing scheduled exits.
  Timer(const Duration(hours: 1), () => exit(0));
}

Future<void> _handle(String scenario, pb.ParentRequest request) async {
  switch (scenario) {
    case 'serve':
    case 'ignore-shutdown':
      await _serve(request, ignoreShutdown: scenario == 'ignore-shutdown');
    case 'oom':
      exit(65);
    case 'eof':
      exit(0);
    case 'torn':
      // A prefix promising 100 bytes, then 10 of them, then the end.
      await _write(Frame.wrap(Uint8List(100)).sublist(0, 14));
      exit(0);
    case 'fatal':
      await _send(
        pb.ChildEvent(fatalError: pb.FatalError(message: fatalMessage)),
      );
      exit(4);
    case 'fatal-hang':
      // A FatalError, then no exit: the channel must kill after its grace.
      await _send(
        pb.ChildEvent(fatalError: pb.FatalError(message: fatalMessage)),
      );
    case 'oversize':
      await _write([0xff, 0xff, 0xff, 0xff]);
    case 'garbage':
      await _write(Frame.wrap([0xff, 0xff, 0xff, 0xff, 0xff]));
    case 'stderr':
      stderr
        ..write('x' * 10240)
        ..writeln()
        ..writeln(stderrLastLine);
      await stderr.flush();
      exit(134);
    case 'late-stderr':
      // Exits at once, while a child holding only stderr writes the last
      // line 200 ms later: stderr is still arriving after the exit code.
      await Process.start('/bin/sh', [
        '-c',
        'exec >/dev/null; sleep 0.2; echo "$stderrLastLine" >&2',
      ], mode: ProcessStartMode.inheritStdio);
      exit(0);
    case 'hold-stderr':
      // Exits at once, leaving a child that holds stderr open for 6 s.
      await Process.start('/bin/sh', [
        '-c',
        'exec >/dev/null; sleep 6',
      ], mode: ProcessStartMode.inheritStdio);
      exit(0);
    case 'env':
      stderr.writeln((Platform.environment.keys.toList()..sort()).join(','));
      await stderr.flush();
      exit(0);
    case 'hang':
      break;
    default:
      stderr.writeln('fake_worker: unknown scenario $scenario');
      exit(2);
  }
}

/// Feed → two Prints (stdout, then stderr) and Complete;
/// Shutdown → Ok and exit 0; anything else (Configure) → Ok.
Future<void> _serve(
  pb.ParentRequest request, {
  required bool ignoreShutdown,
}) async {
  switch (request.whichKind()) {
    case pb.ParentRequest_Kind.feed:
      final code = request.feed.code;
      await _send(_print(pb.PrintStream.PRINT_STREAM_STDOUT, 'out:$code'));
      await _send(_print(pb.PrintStream.PRINT_STREAM_STDERR, 'err:$code'));
      await _send(
        pb.ChildEvent(
          complete: pb.Complete(
            values: pb.Arena(
              nodeCount: 1,
              nodes: [pb.MontyNode(none: pb.Unit())],
            ),
          ),
        ),
      );
    case pb.ParentRequest_Kind.shutdown:
      if (ignoreShutdown) return;
      await _send(pb.ChildEvent(ok: pb.Ok()));
      exit(0);
    // Configure, and anything else: Ok.
    // ignore: no_default_cases, the fake answers only what the tests send.
    default:
      await _send(pb.ChildEvent(ok: pb.Ok()));
  }
}

pb.ChildEvent _print(pb.PrintStream stream, String text) => pb.ChildEvent(
  print: pb.Print(
    segments: [pb.PrintSegment(stream: stream, text: text)],
  ),
);

Future<void> _send(pb.ChildEvent event) => _write(Frame.encode(event));

Future<void> _write(List<int> bytes) async {
  stdout.add(bytes);
  await stdout.flush();
}
