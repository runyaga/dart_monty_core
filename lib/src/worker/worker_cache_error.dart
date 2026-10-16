/// Defines worker-cache configuration failures.
library;

/// A worker-cache configuration failure.
final class WorkerCacheError implements Exception {
  /// Creates a cache configuration failure.
  const WorkerCacheError(this.message);

  /// Explains the failure.
  final String message;

  @override
  String toString() => 'Worker cache configuration error: $message';
}
