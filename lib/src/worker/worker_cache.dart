/// Locates and verifies cached worker artifacts.
library;

import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:dart_monty_core/src/worker/worker_cache_error.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:dart_monty_core/src/worker/worker_verify_error.dart';
import 'package:dart_monty_core/src/worker/worker_verify_reason.dart';
import 'package:path/path.dart' as path;

export 'package:dart_monty_core/src/worker/worker_cache_error.dart';
export 'package:dart_monty_core/src/worker/worker_verify_error.dart';
export 'package:dart_monty_core/src/worker/worker_verify_reason.dart';

/// Returns the per-user worker cache root for the current host.
///
/// macOS and Linux derive the root only from `HOME`; Windows derives it only
/// from `LOCALAPPDATA`.
String workerCacheRoot({
  Map<String, String>? environment,
  String? operatingSystem,
}) {
  final os = operatingSystem ?? Platform.operatingSystem;
  final variables = environment ?? Platform.environment;

  return switch (os) {
    'macos' => _cacheFromHome(variables, macos: true),
    'linux' => _cacheFromHome(variables, macos: false),
    'windows' => _cacheFromLocalAppData(variables),
    _ => throw WorkerCacheError(
      'operating system "$os" is unsupported; use macos, linux, or windows.',
    ),
  };
}

/// Returns the cache directory for [artifact].
String workerCacheDir(String root, WorkerArtifact artifact) {
  final context = _contextForRoot(root);

  return _workerCacheDir(root, artifact, context);
}

/// Returns the cache file for [artifact].
String workerCacheFile(String root, WorkerArtifact artifact) {
  final context = _contextForRoot(root);

  return context.join(_workerCacheDir(root, artifact, context), artifact.file);
}

/// Verifies [file] against [artifact] without loading its contents at once.
Future<void> verifyWorkerFile(File file, WorkerArtifact artifact) async {
  final entityType = FileSystemEntity.typeSync(file.path);
  if (entityType == FileSystemEntityType.notFound) {
    throw WorkerVerifyError(
      path: file.path,
      reason: WorkerVerifyReason.missing,
      expected: artifact.bytes,
      actual: null,
    );
  }
  if (entityType != FileSystemEntityType.file) {
    throw WorkerVerifyError(
      path: file.path,
      reason: WorkerVerifyReason.notAFile,
      expected: 'file',
      actual: entityType.toString(),
    );
  }
  final size = await file.length();
  if (size != artifact.bytes) {
    throw WorkerVerifyError(
      path: file.path,
      reason: WorkerVerifyReason.size,
      expected: artifact.bytes,
      actual: size,
    );
  }
  final actualDigest = (await sha256.bind(file.openRead()).first).toString();
  if (actualDigest != artifact.sha256) {
    throw WorkerVerifyError(
      path: file.path,
      reason: WorkerVerifyReason.digest,
      expected: artifact.sha256,
      actual: actualDigest,
    );
  }
}

String _cacheFromHome(Map<String, String> variables, {required bool macos}) {
  final home = _absoluteVariable(variables, 'HOME', windows: false);

  return macos
      ? path.posix.join(home, 'Library', 'Caches', 'dart_monty')
      : path.posix.join(home, '.cache', 'dart_monty');
}

String _cacheFromLocalAppData(Map<String, String> variables) =>
    path.windows.join(
      _absoluteVariable(variables, 'LOCALAPPDATA', windows: true),
      'dart_monty',
      'Cache',
    );

String _absoluteVariable(
  Map<String, String> variables,
  String name, {
  required bool windows,
}) {
  final value = variables[name];
  if (value == null || value.isEmpty || !_isAbsoluteForHost(value, windows)) {
    throw WorkerCacheError(
      '$name must be an absolute path; set $name before running Dart.',
    );
  }

  return value;
}

String _workerCacheDir(
  String root,
  WorkerArtifact artifact,
  path.Context context,
) => context.join(root, 'worker-${artifact.sha256}');

bool _isAbsoluteForHost(String value, bool windows) =>
    windows ? _isWindowsAbsolute(value) : value.startsWith('/');

bool _isWindowsAbsolute(String value) =>
    RegExp(r'^[A-Za-z]:[\\/]|^\\\\[^\\/]+[\\/][^\\/]+').hasMatch(value);

path.Context _contextForRoot(String root) =>
    _isWindowsAbsolute(root) ? path.windows : path.posix;
