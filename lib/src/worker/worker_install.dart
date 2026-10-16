/// Installs verified published worker artifacts into the per-user cache.
library;

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

// The hook compiles this library without package resolution.
// ignore: always_use_package_imports, reason: The hook uses direct sibling imports.
import 'worker_cache.dart';
// The hook compiles this library without package resolution.
// ignore: always_use_package_imports, reason: The hook uses direct sibling imports.
import 'worker_manifest.dart';

/// Opens an archive as a stream of bytes.
typedef WorkerFetcher = Stream<List<int>> Function(Uri url);

/// Describes one worker-cache installation.
// ignore: prefer-match-file-name, reason: This file groups worker installation request and result types.
final class WorkerInstallRequest {
  /// Creates an installation request.
  const WorkerInstallRequest({
    required this.artifact,
    required this.cacheRoot,
    required this.archiveUrl,
    this.fetcher = defaultWorkerFetcher,
    this.staleAfter = const Duration(hours: 1),
    this.lockWait = const Duration(minutes: 2),
    this.lockStaleAfter = const Duration(minutes: 10),
    this.log,
    this.onStage,
  });

  /// Artifact to install.
  final WorkerArtifact artifact;

  /// Per-user worker-cache root.
  final String cacheRoot;

  /// Archive download location.
  final Uri archiveUrl;

  /// Opens the archive download.
  final WorkerFetcher fetcher;

  /// Age at which abandoned staging directories are swept.
  final Duration staleAfter;

  /// Maximum time spent waiting for the installation lock.
  final Duration lockWait;

  /// Age at which an installation lock is considered stale.
  final Duration lockStaleAfter;

  /// Receives concise installation progress messages.
  final void Function(String message)? log;

  /// Runs named test-only synchronization stages.
  final Future<void> Function(String stage)? onStage;
}

/// Reports the completed installation.
final class WorkerInstall {
  /// Creates an installation report.
  const WorkerInstall({
    required this.path,
    required this.alreadyInstalled,
    required this.downloaded,
  });

  /// Installed cache-file path.
  final String path;

  /// Whether a valid existing cache file satisfied the request.
  final bool alreadyInstalled;

  /// Whether this request downloaded an archive.
  final bool downloaded;
}

/// Explains a recoverable worker installation failure.
final class WorkerInstallError implements Exception {
  /// Creates an installation failure.
  const WorkerInstallError(this.message);

  /// Explains the failing URL or path and a remedy.
  final String message;

  @override
  String toString() => 'Worker installation failed: $message';
}

/// Opens a file or permitted HTTP(S) archive.
Stream<List<int>> defaultWorkerFetcher(Uri url) async* {
  if (url.scheme == 'file') {
    yield* File.fromUri(url).openRead();

    return;
  }
  if (!_isAllowedRemoteUrl(url)) {
    throw WorkerInstallError(
      'URL $url uses an unsupported scheme or insecure host; use file:, '
      'https:, or loopback http:.',
    );
  }

  yield* _fetchRemoteArchive(url);
}

Stream<List<int>> _fetchRemoteArchive(Uri url) async* {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 20);
  try {
    var current = url;
    for (var redirects = 0; ; redirects++) {
      if (!_isAllowedRemoteUrl(current)) {
        throw WorkerInstallError(
          'redirect URL $current is not permitted; use https: or loopback '
          'http:.',
        );
      }
      final request = await client.getUrl(current);
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode == HttpStatus.ok) {
        yield* response;

        return;
      }
      if (!_redirectStatus(response.statusCode) || redirects == 5) {
        throw WorkerInstallError(
          'URL $current returned HTTP ${response.statusCode}; publish the '
          'archive or configure worker_mirror.',
        );
      }
      final location = response.headers.value(HttpHeaders.locationHeader);
      if (location == null) {
        throw WorkerInstallError(
          'URL $current redirected without Location; fix the mirror response.',
        );
      }
      current = current.resolve(location);
      await response.drain<void>();
    }
  } on WorkerInstallError {
    rethrow;
  } on Object catch (error) {
    throw WorkerInstallError(
      'URL $url could not be downloaded ($error); check the mirror and '
      'network connection.',
    );
  } finally {
    client.close(force: true);
  }
}

/// Installs [request]'s worker archive into its cache.
Future<WorkerInstall> installWorker(WorkerInstallRequest request) async {
  final archive = _requiredArchive(request.artifact);
  await _createCacheRoot(request.cacheRoot);
  final installedPath = workerCacheFile(request.cacheRoot, request.artifact);
  final existing = await _existingInstall(installedPath, request.artifact);
  if (existing != null) return existing;
  await _sweepStaging(request.cacheRoot, request.staleAfter);
  _HeldLock lock;
  try {
    lock = await _acquireLock(request, request.artifact.sha256, installedPath);
  } on _InstalledWhileWaiting {
    return _alreadyInstalled(installedPath);
  }

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

Future<_HeldLock> _acquireLock(
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
      throw _InstalledWhileWaiting(installedPath);
    }
    await _breakStaleLock(lock, digest, request.lockStaleAfter);
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
  if (_lockOwner(lock)?.token == token) return _HeldLock(lock, token);
  throw WorkerInstallError(
    'cache ${request.cacheRoot} could not retain its installation lock; '
    'retry the installation.',
  );
}

Future<void> _breakStaleLock(
  Directory lock,
  String digest,
  Duration staleAfter,
) async {
  final held = await _tryAcquireBreakLock(lock.parent, digest);
  if (held == null) return;
  try {
    if (!lock.existsSync() || !await _isStaleLock(lock, staleAfter)) return;
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

  return _HeldLock(breaker, token);
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

    return _Owner(processId, fields.elementAtOrNull(1));
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
    final result = await Process.run('tasklist', [
      '/FI',
      'PID eq $processId',
      '/NH',
      '/FO',
      'CSV',
    ]);
    if (result.exitCode != 0) return true;

    return result.stdout.toString().contains('$processId');
  } on ProcessException {
    return true;
  }
}

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

bool _isAllowedRemoteUrl(Uri url) =>
    url.scheme == 'https' || (url.scheme == 'http' && _isLoopback(url.host));

bool _isLoopback(String host) =>
    host == '127.0.0.1' || host == '::1' || host == 'localhost';

bool _redirectStatus(int status) =>
    status == HttpStatus.movedPermanently ||
    status == HttpStatus.found ||
    status == HttpStatus.seeOther ||
    status == HttpStatus.temporaryRedirect ||
    status == HttpStatus.permanentRedirect;

bool _containsTemplate(String value) =>
    RegExp(r'\{(?:tag|target|archive)\}').hasMatch(value);

String _replaceTemplate(String template, Map<String, String> values) {
  var result = template;
  for (final entry in values.entries) {
    result = result.replaceAll('{${entry.key}}', _segment(entry.value));
  }

  return result;
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

final class _HeldLock {
  const _HeldLock(this.directory, this.token);

  final Directory directory;
  final String token;
}

final class _Owner {
  const _Owner(this.processId, this.token);

  final int processId;
  final String? token;
}

final class _InstalledWhileWaiting implements Exception {
  const _InstalledWhileWaiting(this.path);

  final String path;

  @override
  String toString() => 'Worker installed while waiting: $path';
}

const _defaultWorkerMirror =
    'https://github.com/runyaga/dart_monty_core/releases/download/{tag}/{archive}';

const _breakLockStaleAfter = Duration(seconds: 30);
