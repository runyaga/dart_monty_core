/// Thrown by an `OsCallHandler` to raise a Python exception.
final class OsCallException implements Exception {
  /// Creates an [OsCallException] with [message].
  ///
  /// If [pythonExceptionType] is provided it is used as the Python exception
  /// class (e.g. `'FileNotFoundError'`). Defaults to `'RuntimeError'`.
  const OsCallException(
    this.message, {
    this.pythonExceptionType,
  });

  /// The error message passed to Python.
  final String message;

  /// Optional Python exception type name.
  final String? pythonExceptionType;

  @override
  String toString() => 'OsCallException($message)';
}
