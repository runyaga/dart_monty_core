import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_exception.dart';

/// Applies the open-time effect for a Python `open(path, mode)` call and
/// returns the [MontyFileHandle] the interpreter resumes with.
///
/// This is the low-level `open()` implementation, owned by `dart_monty_core`
/// so every [OsCallHandler] can support `open()` without re-deriving the
/// mode → effect mapping. It is **store-agnostic**: the caller supplies the
/// filesystem primitives as callbacks, so the same logic backs the in-memory
/// [memoryMountedOsHandler] and any `package:file`/host-backed handler.
///
/// The interpreter never holds a live OS handle: it takes this handle and then
/// drives reads/writes through the regular `Path.read_text` / `write_text` /
/// `append_text` OS-calls. A handler therefore only needs this for the bare
/// `Open` call itself.
///
/// Semantics (the only modes monty emits):
/// - `r` / `rb` — the file must already exist; otherwise throws a typed
///   `FileNotFoundError`, or `IsADirectoryError` when [isDirectory] reports a
///   directory at [path].
/// - `w` / `wb` — [ensureWritable] then [truncate] (create empty / overwrite).
/// - `a` / `ab` — [ensureWritable] then [createIfMissing] (preserve content).
///
/// [ensureWritable] is where a handler enforces mount policy: throw an
/// `OsCallException(pythonExceptionType: 'PermissionError')` to reject writes
/// to a read-only location. It defaults to a no-op for handlers without policy.
MontyFileHandle resolveOpenCall(
  String path,
  String mode, {
  required bool Function(String path) exists,
  bool Function(String path) isDirectory = _alwaysFalse,
  void Function(String path)? ensureWritable,
  required void Function(String path) truncate,
  required void Function(String path) createIfMissing,
}) {
  final readOnly = mode == 'r' || mode == 'rb';
  if (readOnly) {
    if (!exists(path)) {
      if (isDirectory(path)) {
        throw OsCallException(
          "[Errno 21] Is a directory: '$path'",
          pythonExceptionType: 'IsADirectoryError',
        );
      }
      throw OsCallException(
        "[Errno 2] No such file or directory: '$path'",
        pythonExceptionType: 'FileNotFoundError',
      );
    }
  } else {
    ensureWritable?.call(path);
    if (mode == 'w' || mode == 'wb') {
      truncate(path);
    } else {
      createIfMissing(path);
    }
  }

  return MontyFileHandle(path: path, mode: mode);
}

bool _alwaysFalse(String path) => false;
