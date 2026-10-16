/// Finds the worker executable for this host.
///
/// Internal to the package; nothing here is exported.
library;

import 'dart:async';
import 'dart:ffi' show Abi;
import 'dart:io';
import 'dart:isolate';

import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/process_channel.dart';
import 'package:dart_monty_core/src/worker/self_relaunch.dart';
import 'package:dart_monty_core/src/worker/worker_cache.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:dart_monty_core/src/worker/worker_manifest_data.dart';
import 'package:meta/meta.dart';

final _verifiedWorkers = <String>{};
final _workerVerificationFutures = <String, Future<void>>{};

/// The worker executable's path inside the package, for [abi]:
/// `src/bin/<os>-<arch>/dart_monty_worker`, with `.exe` on Windows.
///
/// `tool/build_worker.sh` writes the executable there.
String workerPackagePath(Abi abi) {
  final host = workerHostKey(abi);
  final exe = host.startsWith('windows-')
      ? 'dart_monty_worker.exe'
      : 'dart_monty_worker';

  return 'src/bin/$host/$exe';
}

/// Returns [abi]'s worker-manifest target key.
String workerHostKey(Abi abi) => abi.toString().replaceAll('_', '-');

/// Clears process-local cache verification state for a test.
@visibleForTesting
void resetVerifiedWorkersForTesting() {
  _verifiedWorkers.clear();
  _workerVerificationFutures.clear();
}

/// The [WorkerLaunch] to use on this host.
///
/// In order:
/// 1. [explicit], if given.
/// 2. Under the JIT (`dart run`, `dart test`): a verified per-user cache
///    entry for [abi] when the bundled manifest publishes one.
/// 3. In an AOT executable: [SelfRelaunch], if `runMontyWorkerIfChild` ran
///    first in `main` and the worker library is bundled. Package URIs are
///    not consulted there: an AOT executable resolves them against the
///    package config of the machine that built it, when that file still
///    exists, and to null otherwise, depending on the working directory.
/// 4. The package-relative executable for [abi], resolved through
///    `Isolate.resolvePackageUri`.
///
/// Otherwise throws a spawn failure ([spawnError]) naming what was tried.
/// Test parameters replace the runtime's answers.
Future<WorkerLaunch> locateWorker({
  WorkerLaunch? explicit,
  Abi? abi,
  @visibleForTesting bool isAot = const bool.fromEnvironment('dart.vm.product'),
  @visibleForTesting Future<Uri?> Function(Uri)? resolvePackageUri,
  @visibleForTesting bool Function()? canSelfRelaunch,
  @visibleForTesting Map<String, String>? environment,
  @visibleForTesting String? operatingSystem,
  @visibleForTesting WorkerManifest? manifest,
  @visibleForTesting Future<void> Function(File, WorkerArtifact)? verify,
}) async {
  if (explicit != null) return explicit;

  if (isAot) return _selfRelaunch(canSelfRelaunch ?? selfRelaunchAvailable);

  final hostAbi = abi ?? Abi.current();
  final artifact = (manifest ?? bundledWorkerManifest)
      .targetFor(workerHostKey(hostAbi))
      ?.worker;
  String? cachePath;
  if (artifact != null) {
    final root = workerCacheRoot(
      environment: environment,
      operatingSystem: operatingSystem,
    );
    cachePath = workerCacheFile(root, artifact);
    if (FileSystemEntity.typeSync(cachePath) != FileSystemEntityType.notFound) {
      final cacheFile = File(cachePath);
      await _verifiedCacheExecutable(
        cacheFile,
        artifact,
        operatingSystem: operatingSystem,
        verify: verify ?? verifyWorkerFile,
      );

      return WorkerExecutable(cachePath);
    }
  }

  return _packageExecutable(
    hostAbi,
    resolvePackageUri ?? _resolve,
    cachePath: cachePath,
  );
}

/// Step 3: [SelfRelaunch] if [ready] says this process can serve it.
WorkerLaunch _selfRelaunch(bool Function() ready) {
  if (ready()) return const SelfRelaunch();

  throw spawnError(
    'No dart_monty_core worker found. This AOT executable can only '
    'relaunch itself as one, which needs runMontyWorkerIfChild(args) as '
    'the first statement of main and the worker library bundled (root '
    'pubspec: hooks: user_defines: dart_monty_core: build_worker: true). '
    'Or pass a WorkerExecutable.',
  );
}

/// Verifies one cached worker once per process before launching it.
Future<void> _verifiedCacheExecutable(
  File file,
  WorkerArtifact artifact, {
  required String? operatingSystem,
  required Future<void> Function(File, WorkerArtifact) verify,
}) async {
  final verificationKey = '${file.path}|${artifact.sha256}';
  if (_verifiedWorkers.contains(verificationKey)) return;
  final pending = _workerVerificationFutures[verificationKey];
  if (pending != null) {
    await pending;

    return;
  }
  final verification = _verifyCacheExecutable(
    file,
    artifact,
    operatingSystem: operatingSystem,
    verify: verify,
  );
  _workerVerificationFutures[verificationKey] = verification;
  try {
    await verification;
    _verifiedWorkers.add(verificationKey);
  } finally {
    unawaited(_workerVerificationFutures.remove(verificationKey));
  }
}

Future<void> _verifyCacheExecutable(
  File file,
  WorkerArtifact artifact, {
  required String? operatingSystem,
  required Future<void> Function(File, WorkerArtifact) verify,
}) async {
  try {
    await verify(file, artifact);
    if ((operatingSystem ?? Platform.operatingSystem) != 'windows' &&
        !_isExecutable(file)) {
      throw WorkerVerifyError(
        path: file.path,
        reason: WorkerVerifyReason.notAFile,
        expected: 'an executable file',
        actual: 'a non-executable file',
      );
    }
  } on WorkerVerifyError catch (error) {
    final cacheDirectory = file.parent.path;
    throw spawnError(
      'Cached dart_monty_core worker at ${file.path} is invalid: '
      'expected ${error.expected}, actual ${error.actual}. To recover, '
      'delete $cacheDirectory and run `dart run` again so the build hook '
      'reinstalls it.',
    );
  }
}

bool _isExecutable(File file) => (file.statSync().mode & 0x49) != 0;

/// Step 4: the package-relative executable for [abi].
Future<WorkerLaunch> _packageExecutable(
  Abi abi,
  Future<Uri?> Function(Uri) resolve, {
  String? cachePath,
}) async {
  final packageUri = Uri.parse(
    'package:dart_monty_core/${workerPackagePath(abi)}',
  );
  final resolved = await resolve(packageUri);
  if (resolved != null) {
    final file = File.fromUri(resolved);
    if (file.existsSync()) return WorkerExecutable(file.path);
  }
  final packageTried = resolved == null
      ? '$packageUri (package URIs do not resolve in this runtime)'
      : File.fromUri(resolved).path;
  final tried = cachePath == null ? packageTried : '$cachePath, $packageTried';

  throw spawnError(
    'No dart_monty_core worker executable found. Tried: $tried. Build one '
    'with tool/build_worker.sh, run `dart run` again so the build hook can '
    'install a published worker, or pass a WorkerExecutable.',
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
