/// Installs verified published worker artifacts into the per-user cache.
library;

import 'dart:async';
import 'dart:io';

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
  final archive = request.artifact.archive;
  if (archive == null) {
    throw WorkerInstallError(
      'artifact ${request.artifact.file} has no archive; publish a gzip '
      'archive in the worker manifest.',
    );
  }
  await _createCacheRoot(request.cacheRoot);
  final installedPath = workerCacheFile(request.cacheRoot, request.artifact);
  if (await _validFile(installedPath, request.artifact)) {
    return WorkerInstall(
      path: installedPath,
      alreadyInstalled: true,
      downloaded: false,
    );
  }
  await _sweepStaging(request.cacheRoot, request.staleAfter);
  Directory lock;
  try {
    lock = await _acquireLock(request, archive.sha256, installedPath);
  } on _InstalledWhileWaiting {
    return WorkerInstall(
      path: installedPath,
      alreadyInstalled: true,
      downloaded: false,
    );
  }
  Directory? staging;
  try {
    await request.onStage?.call('afterLock');
    if (await _validFile(installedPath, request.artifact)) {
      return WorkerInstall(
        path: installedPath,
        alreadyInstalled: true,
        downloaded: false,
      );
    }
    staging = await _createStaging(request.cacheRoot);
    final archiveBytes = await _downloadArchive(request, archive);
    await request.onStage?.call('afterDownload');
    final workerBytes = _unpackArchive(request.archiveUrl, archiveBytes);
    _verifyBytes(
      workerBytes,
      request.artifact.bytes,
      request.artifact.sha256,
      request.archiveUrl,
      'unpacked worker',
    );
    final stagedFile = File(path.join(staging.path, request.artifact.file));
    await stagedFile.writeAsBytes(workerBytes, flush: true);
    await _makeExecutable(stagedFile);
    await _verifyInstalledFile(stagedFile, request.artifact);
    await request.onStage?.call('beforePublish');
    final published = await _publishStaging(
      staging,
      request.cacheRoot,
      request.artifact,
    );
    staging = null;
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
  final values = <String, String>{
    'tag': tag ?? '',
    'target': target,
    'archive': archive.name,
  };
  if (mirror.contains('{tag}') && tag == null) {
    throw WorkerInstallError(
      'mirror $mirror requires a release tag; set manifest.version or use a '
      'mirror without {tag}.',
    );
  }
  if (_containsTemplate(mirror)) {
    return Uri.parse(_replaceTemplate(mirror, values));
  }
  final encoded = <String>[
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
    if (destination.existsSync()) await _deleteFileBestEffort(destination);
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

Future<Directory> _acquireLock(
  WorkerInstallRequest request,
  String digest,
  String installedPath,
) async {
  final lock = Directory(path.join(request.cacheRoot, '.lock-$digest'));
  final deadline = DateTime.now().add(request.lockWait);
  while (true) {
    try {
      await lock.create();
      final owner = File(path.join(lock.path, 'owner'));
      await owner.create(exclusive: true);
      await owner.writeAsString('$pid', flush: true);
      return lock;
    } on FileSystemException {
      if (await _validFile(installedPath, request.artifact)) {
        throw _InstalledWhileWaiting(installedPath);
      }
      await _breakStaleLock(lock, request.lockStaleAfter);
      if (DateTime.now().isAfter(deadline)) {
        throw WorkerInstallError(
          'lock directory ${lock.path} remained busy; wait for its owner or '
          'remove it after confirming it is stale.',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
      continue;
    } on Object catch (error) {
      throw WorkerInstallError(
        'lock directory ${lock.path} cannot be written ($error); grant write '
        'access or set HOME.',
      );
    }
  }
}

Future<void> _breakStaleLock(Directory lock, Duration staleAfter) async {
  if (!lock.existsSync() || !_isStaleLock(lock, staleAfter)) return;
  final stale = Directory(
    '${lock.parent.path}/.stale-lock-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  try {
    await lock.rename(stale.path);
    await _deleteBestEffort(stale);
  } on FileSystemException {
    // Another installer won the rename race.
  }
}

bool _isStaleLock(Directory lock, Duration staleAfter) {
  final age = DateTime.now().difference(lock.statSync().modified);
  final owner = _lockOwner(lock);
  return age > staleAfter || (owner != null && !pidAlive(owner));
}

int? _lockOwner(Directory lock) {
  try {
    return int.tryParse(File(path.join(lock.path, 'owner')).readAsStringSync());
  } on FileSystemException {
    return null;
  }
}

Future<Directory> _createStaging(String root) async {
  final staging = Directory(
    path.join(root, '.staging-$pid-${DateTime.now().microsecondsSinceEpoch}'),
  );
  await staging.create();
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
  final result = bytes;
  _verifyBytes(
    result,
    archive.bytes,
    archive.sha256,
    request.archiveUrl,
    'archive',
  );
  return result;
}

List<int> _unpackArchive(Uri url, List<int> archive) {
  try {
    return gzip.decode(archive);
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
  final directory = Directory(root);
  await for (final child in directory.list(followLinks: false)) {
    if (child is! Directory || !_isSweepable(child)) continue;
    if (_isStale(child, staleAfter)) await _deleteBestEffort(child);
  }
}

bool _isSweepable(Directory directory) => RegExp(
  r'^\.(?:staging|stale)-\d+-',
).hasMatch(path.basename(directory.path));

bool _isStale(Directory directory, Duration staleAfter) {
  final age = DateTime.now().difference(directory.statSync().modified);
  final owner = _directoryPid(directory);
  return age > staleAfter || owner == null || !pidAlive(owner);
}

int? _directoryPid(Directory directory) {
  final match = RegExp(
    r'^\.(?:staging|stale)-([0-9]+)-',
  ).firstMatch(path.basename(directory.path));
  return match == null ? null : int.tryParse(match.group(1) ?? '');
}

/// Reports whether a process can still own an installation directory.
bool pidAlive(int processId) {
  if (Platform.isWindows) return true;
  try {
    return Process.killPid(processId, ProcessSignal.sigcont);
  } on ProcessException {
    return false;
  }
}

Future<void> _deleteBestEffort(Directory directory) async {
  try {
    if (directory.existsSync()) await directory.delete(recursive: true);
  } on FileSystemException {
    // A competing process or antivirus scanner can own a temporary directory.
  }
}

Future<void> _releaseLock(Directory lock) async {
  final owner = File(path.join(lock.path, 'owner'));
  try {
    if (owner.existsSync()) await owner.delete();
    if (lock.existsSync()) await lock.delete();
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

String _segment(String value) => Uri.encodeComponent(value);

final class _InstalledWhileWaiting implements Exception {
  const _InstalledWhileWaiting(this.path);

  final String path;
}

const _defaultWorkerMirror =
    'https://github.com/runyaga/dart_monty_core/releases/download/{tag}/{archive}';
