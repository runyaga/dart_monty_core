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

/// Thrown by an `OsCallHandler` to decline the requested OS call.
///
/// Python sees the call's own no-handler default, which depends on what was
/// asked: `PermissionError: Permission denied: '<path>'` for a filesystem
/// operation, and `RuntimeError: '<op>' is not supported in this environment`
/// for anything else. See [osCallNoHandlerDefault].
///
/// Prefer this over [OsCallException] when the host simply isn't wired up to
/// handle the operation, so scripts can distinguish "not installed" from
/// "failed".
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

/// The exception a declined OS call raises in Python.
///
/// Mirrors upstream's `OsFunctionCall::on_no_handler`
/// (monty-types/src/os.rs:260): a filesystem operation is a permission failure
/// naming the path; anything else reports the operation name and is not a path
/// question at all.
///
/// **Why the host computes this.** In upstream's pool topology, declining
/// travels as `ResumeValue::NotHandled` and the child computes the default
/// (monty-proto/src/worker.rs:503 —
/// `ExtFunctionResult::Error(call.function_call.on_no_handler())`). We embed
/// the interpreter in-process and `ExtFunctionResult` has no `NotHandled`
/// variant (monty-types/src/results.rs:26-39), so there is nothing to send;
/// the host computes the identical default and resumes with it.
///
/// This must NOT be a `NameError`. Declining `Path.read_text` is a refusal to
/// perform an operation, not a claim that the name is undefined — and routing
/// it through the external-function "not found" verb produced exactly that,
/// turning a sandbox refusal into `NameError: name 'Path.read_text' is not
/// defined`.
/// Returns the exception type and message as non-nullable parts, because both
/// callers need them separately — one throws an [OsCallException], the other
/// hands them to `resumeWithException` — and neither should have to assert a
/// nullable type back to non-null.
({String excType, String message}) osCallNoHandlerDefault(
  String op,
  List<Object?> args,
) {
  // The engine's filesystem set is every `Path.*` call plus bare `open`
  // (monty-types/src/os.rs:178, `is_filesystem`).
  if (!op.startsWith('Path.') && op != 'open') {
    return (
      excType: 'RuntimeError',
      message: "'$op' is not supported in this environment",
    );
  }
  final path = args.firstOrNull;

  return (
    excType: 'PermissionError',
    // Deliberately no errno prefix — monty-fs/tests/fs.rs:2390 asserts that
    // `on_no_handler` for filesystem ops omits it.
    message: "Permission denied: '${path is String ? path : '<unknown>'}'",
  );
}
