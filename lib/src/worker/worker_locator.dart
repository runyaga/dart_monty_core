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
import 'package:dart_monty_core/src/worker/self_relaunch_options.dart';
import 'package:dart_monty_core/src/worker/worker_cache.dart';
import 'package:dart_monty_core/src/worker/worker_cache_source.dart';
import 'package:dart_monty_core/src/worker/worker_fingerprint.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:dart_monty_core/src/worker/worker_manifest_data.dart';
import 'package:meta/meta.dart';

export 'package:dart_monty_core/src/worker/self_relaunch_options.dart';
export 'package:dart_monty_core/src/worker/worker_cache_source.dart';

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
///    first in `main` and the bundled worker library resolves. Package URIs
///    are not consulted there: an AOT executable resolves them against the
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
  @visibleForTesting
  SelfRelaunchOptions selfRelaunch = const SelfRelaunchOptions(),
  @visibleForTesting Future<Uri?> Function(Uri)? resolvePackageUri,
  @visibleForTesting bool Function()? canSelfRelaunch,
  @visibleForTesting WorkerCacheSource? cache,
}) async {
  if (explicit != null) return explicit;

  if (selfRelaunch.isAot) {
    final ready = canSelfRelaunch ?? selfRelaunchAvailable;
    final diagnose =
        selfRelaunch.diagnose ??
        (canSelfRelaunch == null ? diagnoseSelfRelaunch : null);

    return _selfRelaunch(
      ready,
      diagnose,
    );
  }

  final hostAbi = abi ?? Abi.current();
  final (cachedExecutable, cachePath) = await _cacheExecutable(hostAbi, cache);
  if (cachedExecutable != null) return cachedExecutable;

  return _packageExecutable(
    hostAbi,
    resolvePackageUri ?? _resolve,
    cachePath: cachePath,
  );
}

/// Returns a verified cache executable, if present, and the cache path tried.
Future<(WorkerExecutable?, String?)> _cacheExecutable(
  Abi abi,
  WorkerCacheSource? source,
) async {
  final location = _cacheLocation(abi, source);
  if (location == null) return (null, null);

  if (_cacheEntryIsAbsent(location.cachePath)) {
    return (null, location.cachePath);
  }

  await _verifiedCacheExecutable(
    File(location.cachePath),
    location.artifact,
    entry: workerEntryKey(location.artifact, version: location.version),
    operatingSystem: source?.operatingSystem,
    verify: source?.verify ?? verifyWorkerFile,
  );

  return (WorkerExecutable(location.cachePath), location.cachePath);
}

/// Whether [cachePath] is genuinely absent, rather than hidden by an error.
bool _cacheEntryIsAbsent(String cachePath) {
  if (FileSystemEntity.typeSync(cachePath, followLinks: false) !=
      FileSystemEntityType.notFound) {
    return false;
  }

  try {
    File(cachePath).openSync().closeSync();

    return false;
  } on FileSystemException catch (error) {
    if (_isNotFoundError(error)) return true;
    throw _cacheAccessError(cachePath, error);
  }
}

bool _isNotFoundError(FileSystemException error) {
  final code = error.osError?.errorCode;

  return code == 2 || code == 3 || code == 20;
}

({WorkerArtifact artifact, String cachePath, String? version})? _cacheLocation(
  Abi abi,
  WorkerCacheSource? source,
) {
  final manifest = source?.manifest ?? bundledWorkerManifest;
  final artifact = manifest.targetFor(workerHostKey(abi))?.worker;
  if (artifact == null) return null;

  final root = _cacheRoot(source);

  return (
    artifact: artifact,
    cachePath: workerCacheFile(root, artifact),
    version: manifest.version,
  );
}

String _cacheRoot(WorkerCacheSource? source) {
  try {
    return workerCacheRoot(
      environment: source?.environment,
      operatingSystem: source?.operatingSystem,
    );
  } on WorkerCacheError catch (error) {
    final variable = source?.operatingSystem == 'windows'
        ? 'LOCALAPPDATA'
        : 'HOME';
    throw spawnError(
      'Published dart_monty_core worker cache is unusable: ${error.message}; '
      'set $variable to an absolute directory, or pass a WorkerExecutable.',
    );
  }
}

/// Returns [SelfRelaunch] when [ready] says this process can serve it.
WorkerLaunch _selfRelaunch(
  bool Function() ready,
  SelfRelaunchStatus Function()? diagnose,
) {
  if (ready()) return const SelfRelaunch();

  if (diagnose != null) throw spawnError(selfRelaunchRemedy(diagnose()));

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
  required String entry,
  required String? operatingSystem,
  required FutureOr<void> Function(File, WorkerArtifact) verify,
}) async {
  final verificationKey = '${file.path}|$entry';
  if (_verifiedWorkers.contains(verificationKey)) return;
  final pending = _workerVerificationFutures[verificationKey];
  if (pending != null) {
    await pending;

    return;
  }
  final verification = _verifyCacheExecutable(
    file,
    artifact,
    entry: entry,
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
  required String entry,
  required String? operatingSystem,
  required FutureOr<void> Function(File, WorkerArtifact) verify,
}) async {
  try {
    final fingerprintCheck = _needsFingerprintVerification(
      file,
      entry,
      artifact.bytes,
    );
    if (fingerprintCheck.needsVerification) await verify(file, artifact);
    if ((operatingSystem ?? Platform.operatingSystem) != 'windows' &&
        !_isExecutable(file)) {
      throw WorkerVerifyError(
        path: file.path,
        reason: WorkerVerifyReason.notAFile,
        expected: 'an executable file',
        actual: 'a non-executable file',
      );
    }
    final observed = fingerprintCheck.observed;
    if (fingerprintCheck.needsVerification && observed != null) {
      try {
        writeWorkerFingerprint(file, observed);
      } on FileSystemException {
        // A verified worker remains usable when its cache is read-only.
      }
    }
  } on WorkerVerifyError catch (error) {
    throw _invalidCacheError(file.path, error);
  } on FileSystemException catch (error) {
    throw _cacheAccessError(file.path, error);
  }
}

({bool needsVerification, WorkerFingerprint? observed})
_needsFingerprintVerification(File file, String entry, int expectedSize) {
  final current = statWorkerFingerprint(file, entry);
  final stored = readWorkerFingerprint(file);

  return (
    needsVerification:
        current == null || current.size != expectedSize || stored != current,
    observed: current,
  );
}

Never _invalidCacheError(String path, WorkerVerifyError error) {
  final cacheDirectory = File(path).parent.path;
  throw spawnError(
    'Cached dart_monty_core worker at $path is invalid: '
    'expected ${error.expected}, actual ${error.actual}. To recover, '
    'delete $cacheDirectory and run `dart run` again so the build hook '
    'reinstalls it.',
  );
}

Never _cacheAccessError(String path, FileSystemException error) {
  final cacheDirectory = File(path).parent.path;
  throw spawnError(
    'Cached dart_monty_core worker at $path cannot be inspected: $error. '
    'To recover, delete $cacheDirectory and run `dart run` again so the '
    'build hook reinstalls it.',
  );
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
