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
import 'package:meta/meta.dart';
import 'package:path/path.dart' as path;

part 'self_relaunch_status.dart';

/// The worker loop in the bundled worker library; the code asset the build
/// hook emits for this library's URI. Runs on the calling thread, which it
/// blocks until the worker ends. It starts one thread of its own and never
/// spawns a process.
@Native<Int32 Function()>(symbol: 'dart_monty_worker_main')
external int _workerMain();

bool _armed = false;

/// The child exit status for a missing or unloadable bundled worker library.
const int workerLibraryExitCode = 78;

/// Diagnoses whether this executable can serve a self-relaunched worker.
///
/// The worker library lives beside an AOT executable in `../lib`. The optional
/// arguments replace host operations in tests.
SelfRelaunchStatus diagnoseSelfRelaunch({
  @visibleForTesting void Function()? resolveWorker,
  @visibleForTesting String? executablePath,
  @visibleForTesting bool Function(String)? fileExists,
  @visibleForTesting String? operatingSystem,
}) {
  if (!_armed) return const SelfRelaunchNotArmed();

  final host = operatingSystem ?? Platform.operatingSystem;
  final paths = _pathContext(host);
  final library = paths.normalize(
    paths.join(
      paths.dirname(executablePath ?? Platform.resolvedExecutable),
      '..',
      'lib',
      _workerLibraryName(host),
    ),
  );
  final exists = fileExists ?? (candidate) => File(candidate).existsSync();
  if (!exists(library)) return SelfRelaunchLibraryMissing(library);

  try {
    (resolveWorker ?? _resolveWorker)();

    return const SelfRelaunchReady();
    // An unresolvable @Native symbol throws ArgumentError. It is a worker
    // library diagnosis, not an application failure.
    // ignore: avoid_catching_errors
  } on ArgumentError catch (error) {
    return SelfRelaunchLibraryUnloadable(library, '$error');
  }
}

/// Describes how to make a failed self-relaunch diagnosis usable.
String selfRelaunchRemedy(SelfRelaunchStatus status) => switch (status) {
  SelfRelaunchReady() => '',
  SelfRelaunchNotArmed() =>
    'runMontyWorkerIfChild(args) was not called as the first statement of '
        'main: call runMontyWorkerIfChild(args) as the first statement of '
        'main. Or pass a WorkerExecutable.',
  SelfRelaunchLibraryMissing(:final path) =>
    "the worker library $path is missing from the bundle: ship the bundle's "
        'lib/ directory next to bin/ unchanged, or rebuild with dart build '
        'cli. If the bundle has no lib/ directory, enable the root pubspec '
        'opt-in (hooks: user_defines: dart_monty_core: build_worker: true). '
        'Or pass a WorkerExecutable.',
  SelfRelaunchLibraryUnloadable(:final path, :final error) =>
    'the worker library $path exists but cannot be loaded: $error: rebuild '
        'it for this platform (dart build cli) or replace the file. Or pass '
        'a WorkerExecutable.',
};

/// Formats the one-line diagnostic written by a failed worker child.
String selfRelaunchWorkerDiagnostic(SelfRelaunchStatus status) =>
    'dart_monty_core worker: dart_monty_worker_main: '
            '${selfRelaunchRemedy(status)}'
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

/// Serves as the worker and exits when this process was relaunched as one;
/// otherwise returns at once and enables [SelfRelaunch] for this process.
///
/// Call it as the first statement of `main`, with `main`'s arguments: the
/// child's stdout carries the protocol, so nothing may be written to it
/// before the worker starts.
void runMontyWorkerIfChild(List<String> args) {
  _armed = true;
  if (args.length == 1 && args.first == SelfRelaunch.flag) {
    final status = diagnoseSelfRelaunch();
    if (status
        case SelfRelaunchLibraryMissing() || SelfRelaunchLibraryUnloadable()) {
      stderr.writeln(selfRelaunchWorkerDiagnostic(status));
      exit(workerLibraryExitCode);
    }
    exit(_workerMain());
  }
}

/// Whether this process can relaunch itself as a worker: it called
/// [runMontyWorkerIfChild], and the worker library is bundled with it.
///
/// Resolving the library loads it into this process; its entry point is not
/// called.
/// [resolveWorker] replaces symbol resolution in tests, where other isolates
/// may already have loaded the library into the process.
bool selfRelaunchAvailable({
  @visibleForTesting void Function()? resolveWorker,
}) => diagnoseSelfRelaunch(resolveWorker: resolveWorker) is SelfRelaunchReady;

String _workerLibraryName(String operatingSystem) => switch (operatingSystem) {
  'windows' => 'dart_monty_worker.dll',
  'macos' => 'libdart_monty_worker.dylib',
  _ => 'libdart_monty_worker.so',
};

path.Context _pathContext(String operatingSystem) => path.Context(
  style: operatingSystem == 'windows' ? path.Style.windows : path.Style.posix,
);

void _resolveWorker() {
  Native.addressOf<NativeFunction<Int32 Function()>>(_workerMain);
}
