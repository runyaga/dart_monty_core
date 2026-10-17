/// Explains a recoverable worker installation failure.
final class WorkerInstallError implements Exception {
  /// Creates an installation failure.
  const WorkerInstallError(this.message);

  /// Explains the failing URL or path and a remedy.
  final String message;

  @override
  String toString() => 'Worker installation failed: $message';
}
