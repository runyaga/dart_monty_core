/// Defines worker-cache verification reasons.
library;

/// Reasons a cached worker cannot be verified.
enum WorkerVerifyReason {
  /// The expected path does not exist.
  missing,

  /// The file length differs from the manifest.
  size,

  /// The streamed SHA-256 digest differs from the manifest.
  digest,

  /// The expected path is not a regular file.
  notAFile,
}
