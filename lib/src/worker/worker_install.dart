/// Installs verified published worker artifacts into the per-user cache.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:dart_monty_core/src/worker/worker_cache.dart';
import 'package:dart_monty_core/src/worker/worker_install_error.dart';
import 'package:dart_monty_core/src/worker/worker_install_request.dart';
import 'package:dart_monty_core/src/worker/worker_install_result.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:path/path.dart' as path;

export 'package:dart_monty_core/src/worker/worker_install_error.dart';
export 'package:dart_monty_core/src/worker/worker_install_fetcher.dart';
export 'package:dart_monty_core/src/worker/worker_install_request.dart';
export 'package:dart_monty_core/src/worker/worker_install_result.dart';

/// Backwards-compatible name for an installation result.
typedef WorkerInstall = WorkerInstallResult;

/// Installs [request]'s worker archive into its cache.
Future<WorkerInstall> installWorker(WorkerInstallRequest request) async {
  final archive = _requiredArchive(request.artifact);
  await _createCacheRoot(request.cacheRoot);
  final installedPath = workerCacheFile(request.cacheRoot, request.artifact);
  final existing = await _existingInstall(installedPath, request.artifact);
  if (existing != null) return existing;
  await _sweepStaging(request.cacheRoot, request.staleAfter);
  final lock = await _acquireLock(
    request,
    request.artifact.sha256,
    installedPath,
  );
  if (lock == null) return _alreadyInstalled(installedPath);

  return _installWithLock(request, archive, installedPath, lock);
}

Future<WorkerInstall> _installWithLock(
  WorkerInstallRequest request,
  WorkerArchive archive,
  String installedPath,
  _HeldLock lock,
) async {
  Directory? staging;
  try {
    await request.onStage?.call('afterLock');
    final existing = await _existingInstall(installedPath, request.artifact);
    if (existing != null) return existing;
    staging = await _createStaging(request);
    await _stageWorker(request, archive, staging);
    await request.onStage?.call('beforePublish');
    final published = await _publishStaging(
      staging,
      request.cacheRoot,
      request.artifact,
      request.onStage,
    );
    if (!published) {
      return WorkerInstall(
        path: installedPath,
        alreadyInstalled: true,
        downloaded: true,
      );
    }
    await _verifyInstalledFile(File(installedPath), request.artifact);

    return WorkerInstall(
      path: installedPath,
      alreadyInstalled: false,
      downloaded: true,
    );
  } on WorkerInstallError {
    rethrow;
  } on Object catch (error) {
    throw WorkerInstallError(
      'cache ${request.cacheRoot} could not install ${request.archiveUrl} '
      '($error); check the archive and grant write access or set HOME.',
    );
  } finally {
    if (staging != null) await _deleteBestEffort(staging);
    await _releaseLock(lock);
  }
}

WorkerArchive _requiredArchive(WorkerArtifact artifact) {
  final archive = artifact.archive;
  if (archive != null) return archive;
  throw WorkerInstallError(
    'artifact ${artifact.file} has no archive; publish a gzip archive in the '
    'worker manifest.',
  );
}

Future<WorkerInstall?> _existingInstall(
  String installedPath,
  WorkerArtifact artifact,
) async {
  if (!await _validFile(installedPath, artifact)) return null;

  return _alreadyInstalled(installedPath);
}

WorkerInstall _alreadyInstalled(String installedPath) => WorkerInstall(
  path: installedPath,
  alreadyInstalled: true,
  downloaded: false,
);

Future<void> _stageWorker(
  WorkerInstallRequest request,
  WorkerArchive archive,
  Directory staging,
) async {
  final artifact = request.artifact;
  final archiveBytes = await _downloadArchive(request, archive);
  await request.onStage?.call('afterDownload');
  final workerBytes = await _unpackArchive(
    request.archiveUrl,
    archiveBytes,
    artifact.bytes,
  );
  _verifyBytes(
    workerBytes,
    artifact.bytes,
    artifact.sha256,
    request.archiveUrl,
    'unpacked worker',
  );
  final stagedFile = File(path.join(staging.path, artifact.file));
  await stagedFile.writeAsBytes(workerBytes, flush: true);
  await request.onStage?.call('beforeChmod');
  await _makeExecutable(stagedFile);
  await _verifyInstalledFile(stagedFile, artifact);
}

/// Resolves an artifact archive URL from manifest and mirror settings.
Uri workerArchiveUrl({
  required WorkerManifest manifest,
  required String target,
  required WorkerArtifact artifact,
  String? mirrorOverride,
}) {
  final archive = artifact.archive;
  if (archive == null) {
    throw WorkerInstallError(
      'artifact ${artifact.file} has no archive; publish an archive first.',
    );
  }
  final mirror = mirrorOverride ?? manifest.mirror ?? _defaultWorkerMirror;
  final tag = manifest.version;
  if (mirror.contains('{tag}') && tag == null) {
    throw WorkerInstallError(
      'mirror $mirror requires a release tag; set manifest.version or use a '
      'mirror without {tag}.',
    );
  }
  if (_containsTemplate(mirror)) {
    final values = {
      'tag': tag ?? '',
      'target': target,
      'archive': archive.name,
    };

    return Uri.parse(_replaceTemplate(mirror, values));
  }
  final encoded = [
    if (tag != null) _segment(tag),
    _segment(target),
    _segment(archive.name),
  ];
  final base = mirror.endsWith('/')
      ? mirror.substring(0, mirror.length - 1)
      : mirror;

  return Uri.parse('$base/${encoded.join('/')}');
}

/// Converts hook target names to a worker manifest target key.
String hookWorkerHostKey(String os, String arch) =>
    '${os.toLowerCase()}-${arch.toLowerCase()}';

/// Copies a verified library file into a hook output directory.
Future<void> copyVerifiedLibrary({
  required File source,
  required File destination,
  required WorkerArtifact artifact,
}) async {
  final temporary = File(
    '${destination.path}.tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    await verifyWorkerFile(source, artifact);
    await destination.parent.create(recursive: true);
    await source.copy(temporary.path);
    await verifyWorkerFile(temporary, artifact);
    await temporary.rename(destination.path);
    await verifyWorkerFile(destination, artifact);
  } on Object catch (error) {
    if (temporary.existsSync()) await _deleteFileBestEffort(temporary);
    if (error is WorkerInstallError) rethrow;
    throw WorkerInstallError(
      'library copy to ${destination.path} failed ($error); grant write '
      'access and rebuild.',
    );
  }
}

Future<void> _createCacheRoot(String root) async {
  try {
    await Directory(root).create(recursive: true);
  } on Object catch (error) {
    throw WorkerInstallError(
      'cache root $root cannot be created or written ($error); grant write '
      'access or set HOME.',
    );
  }
}

Future<bool> _validFile(String filePath, WorkerArtifact artifact) async {
  try {
    final file = File(filePath);
    await _verifyInstalledFile(file, artifact);

    return true;
  } on WorkerVerifyError {
    return false;
  } on WorkerInstallError {
    return false;
  } on FileSystemException {
    return false;
  }
}

Future<void> _verifyInstalledFile(File file, WorkerArtifact artifact) async {
  await verifyWorkerFile(file, artifact);
  if (!Platform.isWindows && !_isExecutable(file)) {
    throw WorkerInstallError(
      'worker file ${file.path} is not executable; grant execute permission '
      'or reinstall the cache entry.',
    );
  }
}

bool _isExecutable(File file) => file.statSync().mode & 0x49 != 0;

Future<_HeldLock?> _acquireLock(
  WorkerInstallRequest request,
  String digest,
  String installedPath,
) async {
  final lock = Directory(path.join(request.cacheRoot, '.lock-$digest'));
  final deadline = DateTime.now().add(request.lockWait);
  while (true) {
    final held = await _tryAcquireLock(request, lock);
    if (held != null) return held;
    if (await _validFile(installedPath, request.artifact)) {
      return null;
    }
    await _breakStaleLock(
      lock,
      digest,
      request.lockStaleAfter,
      request.onStage,
    );
    _checkLockDeadline(lock, deadline);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }
}

Future<_HeldLock?> _tryAcquireLock(
  WorkerInstallRequest request,
  Directory lock,
) async {
  if (lock.existsSync()) return null;
  try {
    await lock.create();
  } on FileSystemException {
    return null;
  }
  final token = _lockToken();
  final ownsLock = await _writeOwner(
    lock,
    token,
    request.cacheRoot,
    () async => request.onStage?.call('beforeLockOwner'),
  );
  if (!ownsLock) return null;
  await request.onStage?.call('afterLockOwner');
  if (_lockOwner(lock)?.token == token) {
    return (directory: lock, token: token);
  }
  throw WorkerInstallError(
    'cache ${request.cacheRoot} could not retain its installation lock; '
    'retry the installation.',
  );
}

Future<void> _breakStaleLock(
  Directory lock,
  String digest,
  Duration staleAfter,
  Future<void> Function(String stage)? onStage,
) async {
  final held = await _tryAcquireBreakLock(lock.parent, digest);
  if (held == null) return;
  try {
    if (!lock.existsSync() || !await _isStaleLock(lock, staleAfter)) return;
    await onStage?.call('beforeMoveStaleLock');
    await _moveAndDeleteStaleLock(lock);
  } finally {
    await _releaseLock(held);
  }
}

Future<_HeldLock?> _tryAcquireBreakLock(Directory root, String digest) async {
  final breaker = Directory(path.join(root.path, '.break-$digest'));
  if (breaker.existsSync()) {
    await _reclaimBreakLock(breaker);

    return null;
  }
  try {
    await breaker.create();
  } on FileSystemException {
    return null;
  }
  final token = _lockToken();
  if (!await _writeOwner(breaker, token, root.path, null)) return null;

  return (directory: breaker, token: token);
}

Future<void> _reclaimBreakLock(Directory breaker) async {
  if (!await _isStaleLock(breaker, _breakLockStaleAfter)) return;
  await _moveAndDeleteStaleLock(breaker);
}

Future<void> _moveAndDeleteStaleLock(Directory lock) async {
  final stale = Directory(
    '${lock.parent.path}/.stale-lock-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    await lock.rename(stale.path);
    await _deleteBestEffort(stale);
  } on FileSystemException {
    // The lock was released or replaced while checking it.
  }
}

void _checkLockDeadline(Directory lock, DateTime deadline) {
  if (!DateTime.now().isAfter(deadline)) return;
  throw WorkerInstallError(
    'lock directory ${lock.path} remained busy; wait for its owner or remove '
    'it after confirming it is stale.',
  );
}

Future<bool> _isStaleLock(Directory lock, Duration staleAfter) {
  final age = DateTime.now().difference(lock.statSync().modified);
  final owner = _lockOwner(lock);

  return _ownerIsStale(owner, age, staleAfter);
}

_Owner? _lockOwner(Directory lock) {
  return _ownerFile(File(path.join(lock.path, 'owner')));
}

_Owner? _ownerFile(File owner) {
  try {
    final fields = owner.readAsStringSync().trim().split(RegExp(r'\s+'));
    final processId = int.tryParse(fields.firstOrNull ?? '');
    if (processId == null) return null;

    return (processId: processId, token: fields.elementAtOrNull(1));
  } on FileSystemException {
    return null;
  }
}

Future<bool> _writeOwner(
  Directory directory,
  String token,
  String cacheRoot,
  Future<void> Function()? beforeWrite,
) async {
  try {
    await beforeWrite?.call();
    final owner = File(path.join(directory.path, 'owner'));
    try {
      await owner.create(exclusive: true);
    } on PathExistsException {
      return false;
    }
    await owner.writeAsString('$pid $token', flush: true);

    return true;
  } on Object catch (error) {
    await _deleteOwnedDirectory(directory, token);
    throw WorkerInstallError(
      'cache $cacheRoot could not write owner metadata ($error); grant write '
      'access or set HOME.',
    );
  }
}

Future<void> _deleteOwnedDirectory(Directory directory, String token) async {
  final ownerToken = _lockOwner(directory)?.token;
  if (ownerToken != null && ownerToken != token) return;
  await _deleteBestEffort(directory);
}

Future<Directory> _createStaging(WorkerInstallRequest request) async {
  final root = request.cacheRoot;
  final staging = Directory(
    path.join(root, '.staging-$pid-${DateTime.now().microsecondsSinceEpoch}'),
  );
  try {
    await staging.create();
  } on Object catch (error) {
    throw WorkerInstallError(
      'cache $root could not create staging ($error); grant write access or '
      'set HOME.',
    );
  }
  final ownsStaging = await _writeOwner(
    staging,
    'staging',
    root,
    () async => request.onStage?.call('beforeStagingOwner'),
  );
  if (!ownsStaging) {
    await _deleteBestEffort(staging);
    throw WorkerInstallError(
      'cache $root already contains staging owner metadata; retry the '
      'installation.',
    );
  }

  return staging;
}

Future<List<int>> _downloadArchive(
  WorkerInstallRequest request,
  WorkerArchive archive,
) async {
  final bytes = <int>[];
  try {
    await for (final chunk in request.fetcher(request.archiveUrl)) {
      bytes.addAll(chunk);
      if (bytes.length > archive.bytes) {
        throw WorkerInstallError(
          'archive URL ${request.archiveUrl} exceeds ${archive.bytes} bytes; '
          'publish the declared archive or correct its manifest.',
        );
      }
    }
  } on WorkerInstallError {
    rethrow;
  } on Object catch (error) {
    throw WorkerInstallError(
      'archive URL ${request.archiveUrl} could not be read ($error); check '
      'the mirror and retry.',
    );
  }
  _verifyBytes(
    bytes,
    archive.bytes,
    archive.sha256,
    request.archiveUrl,
    'archive',
  );

  return bytes;
}

Future<List<int>> _unpackArchive(
  Uri url,
  List<int> archive,
  int maximumSize,
) async {
  final unpacked = <int>[];
  try {
    await for (final chunk in gzip.decoder.bind(Stream.value(archive))) {
      if (unpacked.length + chunk.length > maximumSize) {
        throw WorkerInstallError(
          'unpacked worker from $url exceeds $maximumSize bytes; publish the '
          'declared worker or correct its manifest.',
        );
      }
      unpacked.addAll(chunk);
    }

    return unpacked;
  } on WorkerInstallError {
    rethrow;
  } on Object catch (error) {
    throw WorkerInstallError(
      'archive URL $url is not valid gzip ($error); publish a gzip archive.',
    );
  }
}

void _verifyBytes(
  List<int> bytes,
  int expectedSize,
  String expectedDigest,
  Uri url,
  String label,
) {
  if (bytes.length != expectedSize) {
    throw WorkerInstallError(
      '$label from $url has ${bytes.length} bytes, expected $expectedSize; '
      'publish the complete archive and manifest.',
    );
  }
  final digest = sha256.convert(bytes).toString();
  if (digest != expectedDigest) {
    throw WorkerInstallError(
      '$label from $url has SHA-256 $digest, expected $expectedDigest; '
      'publish matching release assets.',
    );
  }
}

Future<void> _makeExecutable(File file) async {
  if (Platform.isWindows) return;
  final result = await Process.run('chmod', ['755', file.path]);
  if (result.exitCode != 0) {
    throw WorkerInstallError(
      'worker file ${file.path} could not be made executable; grant write '
      'access or reinstall it.',
    );
  }
}

Future<bool> _publishStaging(
  Directory staging,
  String root,
  WorkerArtifact artifact,
  Future<void> Function(String stage)? onStage,
) async {
  final finalDirectory = Directory(workerCacheDir(root, artifact));
  Directory? stale;
  if (finalDirectory.existsSync()) {
    if (await _validFile(workerCacheFile(root, artifact), artifact)) {
      await _deleteBestEffort(staging);

      return false;
    }
    stale = Directory(
      path.join(root, '.stale-$pid-${DateTime.now().microsecondsSinceEpoch}'),
    );
    await finalDirectory.rename(stale.path);
  }
  try {
    await onStage?.call('beforePublishRename');
    await staging.rename(finalDirectory.path);
  } on FileSystemException {
    if (await _validFile(workerCacheFile(root, artifact), artifact)) {
      await _deleteBestEffort(staging);

      return false;
    }
    rethrow;
  } finally {
    if (stale != null) await _deleteBestEffort(stale);
  }

  return true;
}

Future<void> _sweepStaging(String root, Duration staleAfter) async {
  try {
    final directory = Directory(root);
    await for (final child in directory.list(followLinks: false)) {
      if (child is! Directory || !_isSweepable(child)) continue;
      if (await _isStale(child, staleAfter)) await _deleteBestEffort(child);
    }
  } on Object {
    // Sweeping abandoned entries is opportunistic and must not block installs.
  }
}

bool _isSweepable(Directory directory) => RegExp(
  r'^\.(?:staging|stale|stale-lock)-\d+-',
).hasMatch(path.basename(directory.path));

Future<bool> _isStale(Directory directory, Duration staleAfter) {
  final age = DateTime.now().difference(directory.statSync().modified);
  final owner = _directoryOwner(directory);

  return _ownerIsStale(owner, age, staleAfter);
}

_Owner? _directoryOwner(Directory directory) =>
    _ownerFile(File(path.join(directory.path, 'owner')));

Future<bool> _ownerIsStale(
  _Owner? owner,
  Duration age,
  Duration staleAfter,
) async {
  if (owner == null) return age > staleAfter;

  return !await pidAlive(owner.processId);
}

/// Reports whether a process can still own an installation directory.
///
Future<bool> pidAlive(int processId) async {
  if (Platform.isWindows) return _windowsPidAlive(processId);
  try {
    return Process.killPid(processId, ProcessSignal.sigcont);
  } on ProcessException {
    return false;
  }
}

Future<bool> _windowsPidAlive(int processId) async {
  try {
    final result = await Process.run('tasklist', _taskListArguments(processId));

    return result.exitCode != 0 ||
        result.stdout.toString().contains('$processId');
  } on ProcessException {
    return true;
  }
}

List<String> _taskListArguments(int processId) => [
  '/FI',
  'PID eq $processId',
  '/NH',
  '/FO',
  'CSV',
];

Future<void> _deleteBestEffort(Directory directory) async {
  try {
    if (directory.existsSync()) await directory.delete(recursive: true);
  } on FileSystemException {
    // A competing process or antivirus scanner can own a temporary directory.
  }
}

Future<void> _releaseLock(_HeldLock lock) async {
  try {
    if (_lockOwner(lock.directory)?.token != lock.token) return;
    await lock.directory.delete(recursive: true);
  } on FileSystemException {
    // A replacement lock belongs to another installer.
  }
}

Future<void> _deleteFileBestEffort(File file) async {
  try {
    if (file.existsSync()) await file.delete();
  } on FileSystemException {
    // The caller reports the original copy failure.
  }
}

bool _containsTemplate(String value) =>
    RegExp(r'\{(?:tag|target|archive)\}').hasMatch(value);

String _replaceTemplate(String template, Map<String, String> values) {
  return template.replaceAllMapped(
    RegExp(r'\{(tag|target|archive)\}'),
    (match) => _segment(values[match.group(1)]!),
  );
}

String _segment(String value) {
  if (value.isEmpty || value == '.' || value == '..') {
    throw WorkerInstallError('URL segment $value is not a valid path segment.');
  }

  return Uri.encodeComponent(value);
}

String _lockToken() => List.generate(
  4,
  (_) => Random.secure().nextInt(1 << 32).toRadixString(16),
).join();

typedef _HeldLock = ({Directory directory, String token});

typedef _Owner = ({int processId, String? token});

const _defaultWorkerMirror =
    'https://github.com/runyaga/dart_monty_core/releases/download/{tag}/{archive}';

const _breakLockStaleAfter = Duration(seconds: 30);
