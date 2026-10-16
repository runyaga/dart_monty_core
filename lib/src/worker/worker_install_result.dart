/// Reports the completed installation.
final class WorkerInstallResult {
  /// Creates an installation report.
  const WorkerInstallResult({
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
