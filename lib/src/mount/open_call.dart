import 'package:dart_monty_core/src/externals.dart' show OsCallHandler;
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:dart_monty_core/src/platform/os_call_exception.dart';

/// Applies the open-time effect for a Python `open(path, mode)` call and
/// returns the [MontyFileHandle] the interpreter resumes with.
///
/// This is the low-level `open()` implementation, owned by `dart_monty_core`
/// so every [OsCallHandler] can support `open()` without re-deriving the
/// mode → effect mapping. It is **store-agnostic**: the caller supplies the
/// filesystem primitives as callbacks, so the same logic backs the in-memory
/// `memoryMountedOsHandler` and any `package:file`/host-backed handler.
///
/// The interpreter never holds a live OS handle: it takes this handle and then
/// drives reads/writes through the regular `Path.read_text` / `write_text` /
/// `append_text` OS-calls. A handler therefore only needs this for the bare
/// `open` call itself.
///
/// Semantics (the only modes monty emits):
/// - `r` / `rb` — [isDirectory] must be false and [exists] must be true;
///   otherwise throws a typed `IsADirectoryError` or `FileNotFoundError`
///   respectively. [exists] means "a node is here", NOT "a file is here" — a
///   store where directories exist must answer `true` for them and let
///   [isDirectory] make the distinction.
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
  required void Function(String path) truncate,
  required void Function(String path) createIfMissing,
  bool Function(String path) isDirectory = _alwaysFalse,
  void Function(String path)? ensureWritable,
}) {
  // Parse the mode BEFORE any side effect. Upstream builds its handle first
  // for exactly this reason (`os_access.py:870-876`): "a malformed `mode`
  // raises `ValueError` without touching the filesystem. Direct callers (not
  // routed through Monty, which pre-validates) could otherwise pass e.g.
  // `'wxyz'` and silently trigger the truncate/create branch."
  //
  // We had the mirror-image bug: every unrecognised mode fell through to
  // [createIfMissing], so `open(p, 'wxyz')` silently CREATED a file.
  final action = _openAction(mode);
  if (action == 'r') {
    // Two INDEPENDENT checks, not nested. Upstream states them as one
    // sentence — "verify the file exists and is not a directory"
    // (os_access.py:851-853) — and the distinction only became visible when
    // the store gained real directories: while [exists] effectively meant "is
    // a file", a directory answered `false` and fell into the nested branch by
    // accident. With a tree, a directory answers `true` to [exists] and
    // opening one for read returned a handle.
    if (isDirectory(path)) {
      throw OsCallException(
        "[Errno 21] Is a directory: '$path'",
        pythonExceptionType: 'IsADirectoryError',
      );
    }
    if (!exists(path)) {
      throw OsCallException(
        "[Errno 2] No such file or directory: '$path'",
        pythonExceptionType: 'FileNotFoundError',
      );
    }
  } else {
    ensureWritable?.call(path);
    if (action == 'w') {
      truncate(path);
    } else {
      createIfMissing(path);
    }
  }

  return MontyFileHandle(path: path, mode: mode);
}

/// The open-time action for [mode] — `r`, `w` or `a` — or a Python
/// `ValueError` if [mode] is malformed.
///
/// `b`/`t`/`+` are orthogonal to the open-time effect: only the leading action
/// decides whether we check existence, truncate, or create-if-missing. That is
/// upstream's split too (`os_access.py:878-882`), which is why `r+` is a read
/// action and does not truncate.
///
/// Rejecting rather than defaulting is the point. `x` (exclusive create) is
/// deliberately NOT accepted: upstream's own code asserts the action is one of
/// `r`/`w`/`a` (`os_access.py:896`), so silently treating `x` as append would
/// invent a semantic neither side implements.
String _openAction(String mode) {
  var action = '';
  var binary = false;
  var text = false;
  var plus = false;

  for (final c in mode.split('')) {
    switch (c) {
      case 'r' || 'w' || 'a':
        if (action.isNotEmpty) throw _invalidMode(mode);
        action = c;
      case 'b':
        if (binary) throw _invalidMode(mode);
        binary = true;
      case 't':
        if (text) throw _invalidMode(mode);
        text = true;
      case '+':
        if (plus) throw _invalidMode(mode);
        plus = true;
      default:
        throw _invalidMode(mode);
    }
  }

  // No action character at all (`''`, `'+'`, `'b'`), or the contradictory
  // `bt` pair, which CPython also rejects.
  if (action.isEmpty || (binary && text)) throw _invalidMode(mode);

  return action;
}

OsCallException _invalidMode(String mode) =>
    OsCallException("invalid mode: '$mode'", pythonExceptionType: 'ValueError');

bool _alwaysFalse(String path) => false;
