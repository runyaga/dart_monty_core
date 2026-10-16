import 'dart:typed_data';
import 'package:dart_monty_core/src/worker/python_rules.dart';

/// Validates the public host-side content boundary.
Object checkedContent(Object content) {
  if (content is String || content is Uint8List) return content;
  throw ArgumentError.value(
    content,
    'content',
    'must be a String or Uint8List',
  );
}

/// PurePosixPath.name; roots and the empty path have no name.
String fileName(String path) {
  final normalized = purePosixPath(path);
  if (normalized == '/' || normalized == '//' || normalized == '.') return '';
  return normalized.split('/').lastOrNull ?? '';
}
