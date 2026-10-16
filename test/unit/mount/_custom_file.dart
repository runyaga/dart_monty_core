import 'package:dart_monty_core/dart_monty_core.dart';

/// An implementation outside the library, proving AbstractFile is open.
final class CustomFile implements AbstractFile {
  @override
  String path = 'f';
  @override
  final String name = 'f';
  @override
  int get permissions => 384;
  @override
  bool get deleted => _deleted;
  bool _deleted = false;
  Object _data = 'custom';
  @override
  Object readContent() => _data;
  @override
  void writeContent(Object content) => _data = content;
  @override
  void delete() => _deleted = true;
}
