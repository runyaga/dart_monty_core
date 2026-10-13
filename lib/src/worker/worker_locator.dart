/// Finds the worker executable for this host.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/self_relaunch.dart';
import 'package:meta/meta.dart';

/// The worker executable's path inside the package, for [abi]:
/// `src/bin/<os>-<arch>/dart_monty_worker`, with `.exe` on Windows.
///
/// `tool/build_worker.sh` writes the executable there.
String workerPackagePath(Abi abi) {
  final host = abi.toString().replaceAll('_', '-');
  final exe = host.startsWith('windows-')
      ? 'dart_monty_worker.exe'
      : 'dart_monty_worker';

  return 'src/bin/$host/$exe';
}

/// The [WorkerLaunch] to use on this host.
///
/// In order:
/// 1. [explicit], if given.
/// 2. Under the JIT (`dart run`, `dart test`): the package-relative
///    executable for [abi] (default: this host's), resolved through
///    `Isolate.resolvePackageUri`.
/// 3. In an AOT executable: [SelfRelaunch], if `runMontyWorkerIfChild` ran
///    first in `main` and the worker library is bundled. Package URIs are
///    not consulted there: an AOT executable resolves them against the
///    package config of the machine that built it, when that file still
///    exists, and to null otherwise, depending on the working directory.
///
/// Otherwise throws [StateError] naming what was tried. [isAot],
/// [resolvePackageUri] and [canSelfRelaunch] replace the runtime's answers
/// in tests.
Future<WorkerLaunch> locateWorker({
  WorkerLaunch? explicit,
  Abi? abi,
  @visibleForTesting bool isAot = const bool.fromEnvironment('dart.vm.product'),
  @visibleForTesting Future<Uri?> Function(Uri)? resolvePackageUri,
  @visibleForTesting bool Function()? canSelfRelaunch,
}) async {
  if (explicit != null) return explicit;

  return isAot
      ? _selfRelaunch(canSelfRelaunch ?? selfRelaunchAvailable)
      : _packageExecutable(abi ?? Abi.current(), resolvePackageUri ?? _resolve);
}

/// Step 3: [SelfRelaunch] if [ready] says this process can serve it.
WorkerLaunch _selfRelaunch(bool Function() ready) {
  if (ready()) return const SelfRelaunch();

  throw StateError(
    'No dart_monty_core worker found. This AOT executable can only '
    'relaunch itself as one, which needs runMontyWorkerIfChild(args) as '
    'the first statement of main and the worker library bundled (root '
    'pubspec: hooks: user_defines: dart_monty_core: build_worker: true). '
    'Or pass a WorkerExecutable.',
  );
}

/// Step 2: the package-relative executable for [abi].
Future<WorkerLaunch> _packageExecutable(
  Abi abi,
  Future<Uri?> Function(Uri) resolve,
) async {
  final packageUri = Uri.parse(
    'package:dart_monty_core/${workerPackagePath(abi)}',
  );
  final resolved = await resolve(packageUri);
  if (resolved != null) {
    final file = File.fromUri(resolved);
    if (file.existsSync()) return WorkerExecutable(file.path);
  }
  final tried = resolved == null
      ? '$packageUri (package URIs do not resolve in this runtime)'
      : File.fromUri(resolved).path;

  throw StateError(
    'No dart_monty_core worker executable found. Tried: $tried. '
    'Build one with tool/build_worker.sh, or pass a WorkerExecutable.',
  );
}

/// [packageUri] as a file URI, or null where package URIs do not resolve.
Future<Uri?> _resolve(Uri packageUri) async {
  try {
    return await Isolate.resolvePackageUri(packageUri);
    // An AOT runtime may throw rather than return null; both mean "no
    // package config here", which the caller reports.
    // ignore: avoid_catching_errors
  } on UnsupportedError {
    return null;
  }
}
