import 'package:dart_monty_core/src/mount/abstract_file.dart';
import 'package:dart_monty_core/src/mount/file_content.dart';
import 'package:dart_monty_core/src/worker/python_rules.dart';

/// A mutable in-memory file whose content is a String or Uint8List.
final class MemoryFile implements AbstractFile {
  /// Creates a file, normalizing [path] as Python's PurePosixPath does.
  MemoryFile(String path, Object content, {this.permissions = 0x1A4})
    : path = purePosixPath(path),
      name = fileName(path),
      _content = checkedContent(content);

  @override
  String path;
  @override
  final String name;
  @override
  int permissions;
  Object _content;
  bool _deleted = false;

  /// The current text or bytes. Other types raise ArgumentError.
  Object get content => _content;
  set content(Object value) => _content = checkedContent(value);

  @override
  bool get deleted => _deleted;
  @override
  Object readContent() => content;
  @override
  void writeContent(Object content) => this.content = content;
  @override
  void delete() => _deleted = true;
  @override
  String toString() {
    final preview = _content is String ? "'...'" : "b'...'";

    return 'MemoryFile(path=$path, content=$preview, permissions=$permissions)';
  }
}
