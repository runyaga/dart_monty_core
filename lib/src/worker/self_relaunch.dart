/// Self-relaunch: an AOT app (`dart build cli`) runs a copy of itself as its
/// worker process, so it ships no separate worker executable.
///
/// The parent spawns its own executable with [SelfRelaunch.flag] (see
/// [SelfRelaunch]). In that child, [runMontyWorkerIfChild] hands the
/// process to `dart_monty_worker_main` in the worker library, which serves
/// monty-proto on stdin and stdout until EOF or `Shutdown`, then exits with
/// its code.
///
/// The worker library is bundled only when the root package opts in, in its
/// pubspec:
///
/// ```yaml
/// hooks:
///   user_defines:
///     dart_monty_core:
///       build_worker: true
/// ```
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:ffi';
import 'dart:io';

import 'package:dart_monty_core/src/worker/process_channel.dart';

/// The worker loop in the bundled worker library; the code asset the build
/// hook emits for this library's URI. Runs on the calling thread, which it
/// blocks until the worker ends. It starts one thread of its own and never
/// spawns a process.
@Native<Int32 Function()>(symbol: 'dart_monty_worker_main')
external int _workerMain();

bool _armed = false;

/// Serves as the worker and exits when this process was relaunched as one;
/// otherwise returns at once and enables [SelfRelaunch] for this process.
///
/// Call it as the first statement of `main`, with `main`'s arguments: the
/// child's stdout carries the protocol, so nothing may be written to it
/// before the worker starts.
void runMontyWorkerIfChild(List<String> args) {
  if (args.length == 1 && args.first == SelfRelaunch.flag) {
    exit(_workerMain());
  }
  _armed = true;
}

/// Whether this process can relaunch itself as a worker: it called
/// [runMontyWorkerIfChild], and the worker library is bundled with it.
///
/// Resolving the library loads it into this process; its entry point is not
/// called.
bool selfRelaunchAvailable() {
  if (!_armed) return false;
  try {
    Native.addressOf<NativeFunction<Int32 Function()>>(_workerMain);

    return true;
    // An unresolvable @Native symbol throws ArgumentError: the library is not
    // bundled, which is the answer, not a bug.
    // ignore: avoid_catching_errors
  } on ArgumentError {
    return false;
  }
}
