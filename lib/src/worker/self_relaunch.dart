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
/// The package exports [runMontyWorkerIfChild]; the rest of this library is
/// internal.
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

/// Whether [runMontyWorkerIfChild] ran in this isolate. Arming is
/// isolate-local, so a worker located in a secondary isolate — a pool
/// started under `Isolate.run` — finds it unarmed unless that isolate
/// armed it too.
bool _armed = false;

/// The child exit status for a missing or unloadable bundled worker library.
const int workerLibraryExitCode = 78;

/// A test seam for the self-relaunch library diagnosis.
typedef SelfRelaunchDiagnosis =
    SelfRelaunchStatus Function({
      void Function()? resolveWorker,
    });

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

  try {
    (resolveWorker ?? _resolveWorker)();

    return const SelfRelaunchReady();
    // An unresolvable @Native symbol throws ArgumentError. It is a worker
    // library diagnosis, not an application failure.
    // ignore: avoid_catching_errors
  } on ArgumentError catch (error) {
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

    return SelfRelaunchLibraryUnloadable(library, '$error');
  }
}

/// Describes how to make a failed self-relaunch diagnosis usable.
String selfRelaunchRemedy(SelfRelaunchStatus status) => switch (status) {
  SelfRelaunchReady() => '',
  SelfRelaunchNotArmed() =>
    'runMontyWorkerIfChild(args) was not called as the first statement of '
        'main: call runMontyWorkerIfChild(args) as the first statement of '
        'main. Or set workerLocation to the path of a worker executable.',
  SelfRelaunchLibraryMissing(:final path) =>
    "the worker library $path is missing from the bundle: ship the bundle's "
        'lib/ directory next to bin/ unchanged, or rebuild with dart build '
        'cli. If the bundle has no lib/ directory, enable the root pubspec '
        'opt-in (hooks: user_defines: dart_monty_core: build_worker: true). '
        'Or set workerLocation to the path of a worker executable.',
  SelfRelaunchLibraryUnloadable(:final path, :final error) =>
    'the worker library $path exists but cannot be loaded: $error: rebuild '
        'it for this platform (dart build cli) or replace the file. Or set '
        'workerLocation to the path of a worker executable.',
};

/// Formats the one-line diagnostic written by a failed worker child.
String selfRelaunchWorkerDiagnostic(SelfRelaunchStatus status) =>
    'dart_monty_core worker: dart_monty_worker_main: '
            '${selfRelaunchRemedy(status)}'
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();

/// Returns the worker child's one-line failure diagnostic, if it has one.
String? workerChildFailureLine(SelfRelaunchStatus status) => switch (status) {
  SelfRelaunchLibraryMissing() ||
  SelfRelaunchLibraryUnloadable() => selfRelaunchWorkerDiagnostic(status),
  SelfRelaunchReady() || SelfRelaunchNotArmed() => null,
};

/// Serves as the worker and exits when this process was relaunched as one;
/// otherwise returns at once and enables [SelfRelaunch] for this process.
///
/// Call it as the first statement of `main`, with `main`'s arguments: the
/// child's stdout carries the protocol, so nothing may be written to it
/// before the worker starts.
///
/// Arming is isolate-local: a pool started in another isolate, under
/// `Isolate.run`, finds this isolate unarmed and cannot relaunch. Call it
/// in every isolate that will locate a worker, before the pool starts.
void runMontyWorkerIfChild(List<String> args) {
  _runMontyWorkerIfChild(
    args,
    exitProcess: exit,
    writeStderr: stderr.writeln,
    resolveWorker: _resolveWorker,
    diagnose: diagnoseSelfRelaunch,
    workerMain: _workerMain,
  );
}

/// Runs the child handoff with host operations supplied by a test.
@visibleForTesting
void runMontyWorkerIfChildWithSeams(
  List<String> args, {
  @visibleForTesting required void Function(int) exitProcess,
  @visibleForTesting required void Function(String) writeStderr,
  @visibleForTesting required void Function() resolveWorker,
  @visibleForTesting required SelfRelaunchDiagnosis diagnose,
  @visibleForTesting required int Function() workerMain,
}) => _runMontyWorkerIfChild(
  args,
  exitProcess: exitProcess,
  writeStderr: writeStderr,
  resolveWorker: resolveWorker,
  diagnose: diagnose,
  workerMain: workerMain,
);

void _runMontyWorkerIfChild(
  List<String> args, {
  required void Function(int) exitProcess,
  required void Function(String) writeStderr,
  required void Function() resolveWorker,
  required SelfRelaunchDiagnosis diagnose,
  required int Function() workerMain,
}) {
  _armed = true;
  if (args case [SelfRelaunch.flag]) {
    final status = diagnose(resolveWorker: resolveWorker);
    final failureLine = workerChildFailureLine(status);
    if (failureLine != null) {
      writeStderr(failureLine);
      exitProcess(workerLibraryExitCode);

      return;
    }
    exitProcess(workerMain());
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
