/// Describes published worker artifacts for supported host targets.
library;

import 'dart:convert';

/// Describes published worker artifacts.
final class WorkerManifest {
  /// Creates a manifest description.
  WorkerManifest({
    required Map<String, WorkerTarget> targets,
    this.version,
    this.mirror,
  }) : targets = Map.unmodifiable(targets);

  /// Parses a schema-1 manifest JSON string.
  factory WorkerManifest.fromJson(String source) {
    final decoded = _decode(source);
    final schema = decoded['schema'];
    if (schema != 1) {
      throw const WorkerManifestError('schema must be 1.');
    }
    final version = _optionalString(decoded, 'version');
    final mirror = _optionalString(decoded, 'mirror');
    final rawTargets = decoded['targets'];
    if (rawTargets is! Map) {
      throw const WorkerManifestError('targets must be a map.');
    }
    final targets = <String, WorkerTarget>{};
    for (final entry in rawTargets.entries) {
      if (entry.key is! String) {
        throw const WorkerManifestError('targets keys must be strings.');
      }
      final targetKey = entry.key as String;
      if (!_supportedTargets.contains(targetKey)) {
        throw WorkerManifestError('targets.$targetKey is unsupported.');
      }
      final target = _stringMap(entry.value, 'targets.$targetKey');
      final worker = target['worker'];
      if (worker is! Map) {
        throw WorkerManifestError('targets.$targetKey.worker must be a map.');
      }
      final library = target['library'];
      if (target.containsKey('library') && library is! Map) {
        throw WorkerManifestError('targets.$targetKey.library must be a map.');
      }
      targets[targetKey] = WorkerTarget(
        worker: _artifact(worker, 'targets.$targetKey.worker'),
        library: !target.containsKey('library')
            ? null
            : _artifact(library, 'targets.$targetKey.library'),
      );
    }

    return WorkerManifest(version: version, mirror: mirror, targets: targets);
  }

  /// Release tag, when a manifest provides one.
  final String? version;

  /// Mirror URL template, when a manifest provides one.
  final String? mirror;

  /// Artifacts by host target key.
  final Map<String, WorkerTarget> targets;

  /// Returns the target for [host], or null when none is published.
  WorkerTarget? targetFor(String host) => targets[host];
}

/// A manifest validation failure.
final class WorkerManifestError implements Exception {
  /// Creates a manifest validation failure with [message].
  const WorkerManifestError(this.message);

  /// Explains which manifest value is invalid.
  final String message;

  @override
  String toString() => 'Invalid worker manifest: $message';
}

/// Describes an optional archive containing an artifact.
final class WorkerArchive {
  /// Creates an archive description.
  const WorkerArchive({
    required this.name,
    required this.bytes,
    required this.sha256,
  });

  /// Archive basename.
  final String name;

  /// Archive byte count.
  final int bytes;

  /// Archive SHA-256 digest.
  final String sha256;
}

/// Describes a published worker file.
final class WorkerArtifact {
  /// Creates an artifact description.
  const WorkerArtifact({
    required this.file,
    required this.bytes,
    required this.sha256,
    this.archive,
  });

  /// Artifact basename.
  final String file;

  /// Artifact byte count.
  final int bytes;

  /// Artifact SHA-256 digest.
  final String sha256;

  /// Archive containing the artifact, when published that way.
  final WorkerArchive? archive;
}

/// Describes the artifacts for one host target.
final class WorkerTarget {
  /// Creates a target description.
  const WorkerTarget({required this.worker, this.library});

  /// Worker executable artifact.
  final WorkerArtifact worker;

  /// Optional host-library artifact.
  final WorkerArtifact? library;
}

const _supportedTargets = {
  'macos-arm64',
  'linux-x64',
  'linux-arm64',
  'windows-x64',
};

Map<String, Object?> _decode(String source) {
  try {
    final decoded = jsonDecode(source);
    if (decoded is! Map) {
      throw const WorkerManifestError('root must be a map.');
    }

    return _stringMap(decoded, 'root');
  } on FormatException {
    throw const WorkerManifestError('JSON is malformed.');
  }
}

Map<String, Object?> _stringMap(Object? value, String key) {
  if (value is! Map) {
    throw WorkerManifestError('$key must be a map.');
  }
  final mapped = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw WorkerManifestError('$key keys must be strings.');
    }
    mapped[entry.key as String] = entry.value;
  }

  return mapped;
}

String? _optionalString(Map<String, Object?> map, String key) {
  if (!map.containsKey(key)) return null;
  final value = map[key];
  if (value is! String) {
    throw WorkerManifestError('$key must be a string.');
  }

  return value;
}

WorkerArtifact _artifact(Object? value, String key) {
  final artifact = _stringMap(value, key);
  final file = _requiredBasename(artifact, 'file', key);
  final bytes = _requiredPositiveInt(artifact, 'bytes', key);
  final digest = _requiredDigest(artifact, 'sha256', key);
  WorkerArchive? archive;
  if (artifact.containsKey('archive')) {
    final archiveMap = _stringMap(artifact['archive'], '$key.archive');
    archive = WorkerArchive(
      name: _requiredBasename(archiveMap, 'name', '$key.archive'),
      bytes: _requiredPositiveInt(archiveMap, 'bytes', '$key.archive'),
      sha256: _requiredDigest(archiveMap, 'sha256', '$key.archive'),
    );
  }

  return WorkerArtifact(
    file: file,
    bytes: bytes,
    sha256: digest,
    archive: archive,
  );
}

String _requiredBasename(Map<String, Object?> map, String name, String key) {
  final value = map[name];
  if (value is! String ||
      value.isEmpty ||
      value == '.' ||
      value == '..' ||
      value.contains('/') ||
      value.contains(r'\')) {
    throw WorkerManifestError('$key.$name must be a plain basename.');
  }

  return value;
}

int _requiredPositiveInt(Map<String, Object?> map, String name, String key) {
  final value = map[name];
  if (value is! int || value <= 0) {
    throw WorkerManifestError('$key.$name must be a positive integer.');
  }

  return value;
}

String _requiredDigest(Map<String, Object?> map, String name, String key) {
  final value = map[name];
  if (value is! String || !_digestPattern.hasMatch(value)) {
    throw WorkerManifestError(
      '$key.$name must be 64 lowercase hex characters.',
    );
  }

  return value;
}

final _digestPattern = RegExp(r'^[0-9a-f]{64}$');
