/// The native default print sink: the parent's own stdout and stderr, as
/// upstream's `PrintTarget::Stdout` writes them.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';
import 'dart:io';

Future<void> _stdoutTail = Future.value();
Future<void> _stderrTail = Future.value();

/// Writes [text] to stdout, or to stderr when [stream] is `stderr`, adding
/// nothing, and completes once it is flushed.
///
/// Writes go through `nonBlocking`: a synchronous write to a full pipe
/// would block the whole isolate, timers and other sessions included. They
/// are serialized per stream, so each delivery's flush finishes before the
/// next write starts, whichever session prints.
Future<void> defaultPrint(String stream, String text) {
  final toStderr = stream == 'stderr';
  final done = _write(
    toStderr ? _stderrTail : _stdoutTail,
    toStderr ? stderr.nonBlocking : stdout.nonBlocking,
    text,
  );
  if (toStderr) {
    _stderrTail = _settled(done);
  } else {
    _stdoutTail = _settled(done);
  }

  return done;
}

/// Writes [text] to [sink] once [previous] has settled, and flushes it.
Future<void> _write(Future<void> previous, IOSink sink, String text) async {
  await previous;
  sink.write(text);
  await sink.flush();
}

/// Completes when [delivery] does, failed or not.
Future<void> _settled(Future<void> delivery) async {
  try {
    await delivery;
  } on Object catch (_) {
    // A failed write fails its own delivery only; the next one still runs.
  }
}
