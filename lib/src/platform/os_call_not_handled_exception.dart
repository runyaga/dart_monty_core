/// Thrown synchronously by an `OsHandler` to decline the requested OS call,
/// as upstream's handler returns `NOT_HANDLED`.
///
/// The worker then raises the call's own default, which depends on what was
/// asked: `PermissionError` naming the path for a filesystem operation, and
/// `RuntimeError` saying the operation is not supported in this environment
/// for anything else. The worker knows the pending operation,
/// so the exception carries nothing.
final class OsCallNotHandledException implements Exception {
  /// Declines the pending OS call.
  const OsCallNotHandledException();

  @override
  String toString() => 'OsCallNotHandledException()';
}
