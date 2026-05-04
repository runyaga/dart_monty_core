/// Programming-error sentinel for DartMonty API misuse.
///
/// Extends [Error] (not [Exception]) so it is never silently swallowed by
/// `on Exception` catch blocks. This type signals a bug at the call site —
/// do not catch it in production code.
final class MontyInternalError extends Error {
  /// Creates a [MontyInternalError] with the given [message].
  MontyInternalError(this.message);

  /// Human-readable description of the programming error.
  final String message;

  @override
  String toString() => 'MontyInternalError: $message';
}
