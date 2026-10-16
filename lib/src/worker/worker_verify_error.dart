/// Defines worker-cache verification failures.
library;

import 'package:dart_monty_core/src/worker/worker_verify_reason.dart';

/// A cached worker verification failure.
final class WorkerVerifyError implements Exception {
  /// Creates a verification failure.
  const WorkerVerifyError({
    required this.path,
    required this.reason,
    required this.expected,
    required this.actual,
  });

  /// Path that failed verification.
  final String path;

  /// Verification check that failed.
  final WorkerVerifyReason reason;

  /// Expected value for the failed check.
  final Object? expected;

  /// Actual value for the failed check.
  final Object? actual;

  @override
  String toString() =>
      'Worker verification failed for $path: $reason; expected $expected, '
      'actual $actual.';
}
