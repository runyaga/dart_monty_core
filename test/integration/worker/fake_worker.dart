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

/// How many `Print` frames the `flood` scenario sends.
const floodPrints = 512;

/// The text length of each of them: 64 KiB, so 32 MiB in all.
const int floodPrintLength = 64 * 1024;

/// The `exit-leaving-writer` descendant has written this many Prints before
/// its worker exits: fewer than the channel's read-ahead limit holds (64), so
/// writing them cannot block on a parent that has paused reading.
const descendantReadyPrints = 48;

/// The text length of the one `Print` the `big-frame` scenario sends in
/// many chunks: 8 MiB.
const int bigPrintLength = 8 * 1024 * 1024;

/// The 64 KiB `Print`s the `big-frame` scenario sends before its big one:
/// 3 MiB, under the channel's read-ahead limit.
const bigFramePrefixPrints = 48;

/// The 64 KiB `Print`s it sends after the big one: 2 MiB, which must wait.
const bigFrameSuffixPrints = 32;

Future<void> main(List<String> args) async {
  var scenario = args.firstOrNull ?? 'serve';
  if (args case ['writer', final path, ...]) {
    return _writeAfterParentExits(path);
  }
  if (scenario == 'complete-before-send') return _completeBeforeSend();
  final decoder = FrameDecoder();
  await for (final chunk in stdin) {
    for (final body in decoder.add(chunk)) {
      scenario = await _handle(scenario, pb.ParentRequest.fromBuffer(body));
    }
  }
  if (scenario != 'ignore-shutdown') exit(0);
  // Keeps running after stdin closes, as a wedged worker would. A pending
  // timer, not a bare Completer: an isolate with nothing scheduled exits.
  Timer(const Duration(hours: 1), () => exit(0));
}

/// Reads exactly the first request, without an async stdin subscription that
/// could read ahead. The next request must remain in the parent's pipe.
Future<void> _completeBeforeSend() async {
  final decoder = FrameDecoder();
  for (;;) {
    final byte = stdin.readByteSync();
    if (byte < 0) exit(2);
    if (decoder.add([byte]).isNotEmpty) break;
  }
  await _send(pb.ChildEvent(ok: pb.Ok()));
  await _send(pb.ChildEvent(complete: pb.Complete()));
  // Let the next request fill the pipe before closing its read end. On
  // Linux the write error and process-exit notification race each other.
  await Future<void>.delayed(const Duration(milliseconds: 500));
  exit(0);
}

/// Answers [request] as [scenario] says, and returns the scenario for the
/// next request: `flood` and `big-frame` switch to `idle` once they have
/// sent everything.
Future<String> _handle(String scenario, pb.ParentRequest request) async {
  switch (scenario) {
    case 'serve':
    case 'ignore-shutdown':
      await _serve(request, ignoreShutdown: scenario == 'ignore-shutdown');
    case 'oom':
      exit(65);
    case 'oom-on-feed':
      // Configure is accepted; the first Feed exits as a refused
      // allocation does.
      if (request.whichKind() == pb.ParentRequest_Kind.feed) exit(65);
      await _send(pb.ChildEvent(ok: pb.Ok()));
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
    case 'upstream-rejects':
      // Complete { values { nodes: [ { str: "\xc3\x28" } ] } }: invalid
      // UTF-8, which package:protobuf alone parses and upstream rejects.
      await _write(
        Frame.wrap([0x32, 8, 0x12, 6, 0x12, 4, 0x42, 2, 0xc3, 0x28]),
      );
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
      // Exits at once, leaving a child that holds stderr open for 20 s.
      // Long against the test's bound: that bound also covers two JIT
      // start-ups (the probe and this program), which a loaded runner slows.
      await Process.start('/bin/sh', [
        '-c',
        'exec >/dev/null; sleep 20',
      ], mode: ProcessStartMode.inheritStdio);
      exit(0);
    case 'hold-stdout':
      // Exits without answering, leaving a child that holds stdout open
      // for 6 s: no EOF arrives until it ends.
      await Process.start('/bin/sh', [
        '-c',
        'exec 2>/dev/null; sleep 6',
      ], mode: ProcessStartMode.inheritStdio);
      exit(0);
    case 'env':
      stderr.writeln((Platform.environment.keys.toList()..sort()).join(','));
      await stderr.flush();
      exit(0);
    case 'hang':
      break;
    case 'flood':
      // Ok, then 32 MiB of Prints and a Complete that no turn asked for yet:
      // they stay queued for the next turn.
      await _send(pb.ChildEvent(ok: pb.Ok()));
      for (var i = 0; i < floodPrints; i++) {
        await _send(_numbered(i, floodPrintLength));
      }
      await _send(_completeNone);

      return 'idle';
    case 'big-frame':
      // Ok, 3 MiB of Prints, one 8 MiB Print written in 64 KiB pieces,
      // 2 MiB more Prints, then a Complete: a frame larger than the
      // read-ahead limit completes, and the frames after it wait.
      await _send(pb.ChildEvent(ok: pb.Ok()));
      for (var i = 0; i < bigFramePrefixPrints; i++) {
        await _send(_numbered(i, floodPrintLength));
      }
      final big = Frame.encode(_numbered(bigFramePrefixPrints, bigPrintLength));
      for (var at = 0; at < big.length; at += 64 * 1024) {
        await _write(big.sublist(at, (at + 64 * 1024).clamp(0, big.length)));
      }
      for (var i = 0; i < bigFrameSuffixPrints; i++) {
        await _send(_numbered(bigFramePrefixPrints + 1 + i, floodPrintLength));
      }
      await _send(_completeNone);

      return 'idle';
    case 'exit-leaving-writer':
      // Ok, then exit, leaving a descendant that inherited stdout and keeps
      // writing valid Prints after this process is gone.
      await _send(pb.ChildEvent(ok: pb.Ok()));
      final dir = Directory.systemTemp.createTempSync('writer');
      final marker = File('${dir.path}/ready');
      var code = 0;
      try {
        await Process.start(Platform.resolvedExecutable, [
          Platform.script.toFilePath(),
          'writer',
          marker.path,
        ], mode: ProcessStartMode.inheritStdio);
        // Exits only once the descendant has written, however long it took
        // to start: a fixed wait
        // loses that race on a loaded machine, and the
        // drain then has nothing to read.
        final deadline = DateTime.now().add(const Duration(seconds: 25));
        while (!marker.existsSync()) {
          if (DateTime.now().isAfter(deadline)) {
            stderr.writeln('fake_worker: the descendant never wrote enough');
            code = 3;
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      } finally {
        dir.deleteSync(recursive: true);
      }
      exit(code);
    case 'idle':
      // Everything was sent up front; only Shutdown is answered.
      if (request.whichKind() == pb.ParentRequest_Kind.shutdown) exit(0);
    default:
      stderr.writeln('fake_worker: unknown scenario $scenario');
      exit(2);
  }

  return scenario;
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
      await _send(_completeNone);
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

/// The `writer` descendant: 32 MiB of Prints on the inherited stdout,
/// reading nothing, and gone after 20 s whatever happened.
Future<void> _writeAfterParentExits(String marker) async {
  Timer(const Duration(seconds: 20), () => exit(0));
  // Starts late, as a descendant does on a loaded machine: longer than the
  // parent's drain grace, so the worker must wait for the first frame.
  await Future<void>.delayed(const Duration(seconds: 4));
  for (var i = 0; i < floodPrints; i++) {
    await _send(_numbered(i, floodPrintLength));
    // Enough is in the pipe: the worker may exit now.
    if (i == descendantReadyPrints - 1) File(marker).createSync();
  }
  exit(0);
}

final pb.ChildEvent _completeNone = pb.ChildEvent(
  complete: pb.Complete(
    values: pb.Arena(nodeCount: 1, nodes: [pb.MontyNode(none: pb.Unit())]),
  ),
);

/// A stdout `Print` of [length] characters that starts with `#<n>:`.
pb.ChildEvent _numbered(int n, int length) {
  final head = '#$n:';

  return _print(
    pb.PrintStream.PRINT_STREAM_STDOUT,
    head + 'x' * (length - head.length),
  );
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
