import 'package:dart_monty_core/src/worker/worker_install_fetcher.dart';
import 'package:dart_monty_core/src/worker/worker_manifest.dart';

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
    this.manifestVersion,
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

  /// Manifest version that selected [artifact], when available.
  final String? manifestVersion;

  /// Runs named test-only synchronization stages.
  final Future<void> Function(String stage)? onStage;
}
