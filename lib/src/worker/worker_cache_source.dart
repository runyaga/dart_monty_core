/// Defines test-only worker-cache inputs.
library;

import 'dart:async';
import 'dart:io';

import 'package:dart_monty_core/src/worker/worker_manifest.dart';
import 'package:meta/meta.dart';

/// Test-only inputs for the per-user worker cache.
@immutable
class WorkerCacheSource {
  /// Creates test-only inputs for the per-user worker cache.
  const WorkerCacheSource({
    this.environment,
    this.operatingSystem,
    this.manifest,
    this.verify,
  });

  /// Environment used to determine the cache root.
  final Map<String, String>? environment;

  /// Operating system used to determine the cache root and permissions.
  final String? operatingSystem;

  /// Manifest from which to select a cached worker artifact.
  final WorkerManifest? manifest;

  /// Verifies a cached worker artifact before it is launched.
  final FutureOr<void> Function(File, WorkerArtifact)? verify;
}
