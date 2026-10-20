import 'package:dart_monty_core/src/mount/abstract_file.dart';
import 'package:dart_monty_core/src/mount/file_content.dart';
import 'package:dart_monty_core/src/worker/python_rules.dart';

/// A file backed by synchronous host callbacks, with no content cache.
///
/// Callbacks always receive the normalized construction path, including after
/// renames. They run with the host's privileges; audit their effects.
///
/// Nothing is cached: every operation that needs content invokes [read]
/// again — a `Path.read_text`, `Path.read_bytes` or `Path.stat` (which
/// sizes the file), and an append (which reads before it writes). [write]
/// fires for `Path.write_text` and `Path.write_bytes`, for the appends
/// (old and new content combined), and for an `open` in a write mode,
/// which truncates by writing empty content.
final class CallbackFile implements AbstractFile {
  /// Creates a callback file with settable callbacks and permissions.
  CallbackFile(this.path, this.read, this.write, {this.permissions = 0x1A4})
    : name = fileName(path),
      _seededPath = purePosixPath(path) {
    path = _seededPath;
  }

  @override
  String path;
  @override
  final String name;
  @override
  int permissions;

  /// Invoked on every read, `stat` and append; returns String or Uint8List
  /// to OSAccess.
  Object Function(String path) read;

  /// Invoked on every write and truncating `open`, with the new content
  /// alone or old and new combined on an append; the result is not cached
  /// or awaited.
  void Function(String path, Object content) write;
  final String _seededPath;
  bool _deleted = false;
  @override
  bool get deleted => _deleted;
  @override
  Object readContent() => read(_seededPath);
  @override
  void writeContent(Object content) => write(_seededPath, content);
  @override
  void delete() => _deleted = true;
  @override
  String toString() =>
      'CallbackFile(path=$path, read=$read, write=$write, '
      'permissions=$permissions)';
}
