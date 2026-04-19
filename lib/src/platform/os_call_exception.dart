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

/// Thrown by an `OsCallHandler` to signal that the host does not implement
/// the requested OS call.
///
/// Python sees a `NameError: name '<fn>' is not defined` — the same error it
/// would raise for an undefined global. Prefer this over [OsCallException]
/// when the host simply isn't wired up to handle the operation, so scripts
/// can distinguish "not installed" from "failed".
final class OsCallNotHandledException implements Exception {
  /// Creates an [OsCallNotHandledException].
  ///
  /// [fnName] is optional; when omitted, the runtime falls back to the
  /// operation name of the pending OS call.
  const OsCallNotHandledException([this.fnName]);

  /// Optional override for the function name embedded in the NameError.
  /// Defaults to the pending OS call's operation name.
  final String? fnName;

  @override
  String toString() => fnName == null
      ? 'OsCallNotHandledException()'
      : 'OsCallNotHandledException($fnName)';
}
