/// Finds the worker executable for this host.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:dart_monty_core/src/worker/process_channel.dart';

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
/// In order: [explicit] if given; then the package-relative executable for
/// [abi] (default: this host's), resolved through `Isolate.resolvePackageUri`,
/// which works under `dart run` and `dart test` but not in AOT. Throws
/// [StateError] listing what was tried if neither yields a worker.
Future<WorkerLaunch> locateWorker({WorkerLaunch? explicit, Abi? abi}) async {
  if (explicit != null) return explicit;
  final packageUri = Uri.parse(
    'package:dart_monty_core/${workerPackagePath(abi ?? Abi.current())}',
  );
  final resolved = await _resolve(packageUri);
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
