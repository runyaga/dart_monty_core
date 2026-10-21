import 'package:dart_monty_core/src/mount/abstract_file.dart';
import 'package:dart_monty_core/src/mount/file_content.dart';
import 'package:dart_monty_core/src/worker/python_rules.dart';

/// A virtual file backed by uncached synchronous host callbacks.
///
/// Both callbacks receive the normalized construction path after a rename.
/// They execute with host privileges.
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

  /// Reads the current content for every read, `stat`, and append.
  ///
  /// The result must be a `String` or `Uint8List` when `OSAccess` serves the
  /// file. An append reads before it writes.
  Object Function(String path) read;

  /// Writes replacement content without caching or awaiting the result.
  ///
  /// Appends receive the old and new content combined. A truncating `open`
  /// writes empty content.
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
