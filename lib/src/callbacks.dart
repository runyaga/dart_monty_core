/// A callback invoked when Python calls a registered host function.
///
/// Receives the named arguments map from Python. Return value is
/// serialized back to Python as the function's return value.
/// Return `null` to return `None` to Python.
typedef MontyCallback = Future<Object?> Function(Map<String, Object?> args);

/// A callback invoked when Python performs an OS operation (filesystem,
/// environment, datetime).
///
/// [operation] is the dotted operation name, e.g. `"Path.read_text"`,
/// `"os.getenv"`, `"datetime.now"`.
/// [args] and [kwargs] are the positional and keyword arguments.
///
/// Throw an [OsCallException] to raise a Python exception from the handler.
/// Return `null` to return `None` to Python.
typedef OsCallHandler = Future<Object?> Function(
  String operation,
  List<Object?> args,
  Map<String, Object?>? kwargs,
);

/// Thrown by an [OsCallHandler] to raise a Python exception.
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
