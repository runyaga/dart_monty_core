part of 'os_access.dart';

final class _OsAccessFiles {
  const _OsAccessFiles(this.tree, this.files);
  final _OsAccessTree tree;
  final List<AbstractFile> files;
  MontyInt write(String path, Object data) {
    final entry = tree.lookup(path);
    if (entry is AbstractFile) {
      entry.writeContent(data);
    } else if (entry is _Directory) {
      throw _fsError('IsADirectoryError', path);
    } else {
      final parent = tree.parent(path);
      if (parent is! _Directory) throw _fsError('FileNotFoundError', path);
      final file = MemoryFile(path, data);
      parent.children[file.name] = file;
      files.add(file);
    }

    return MontyInt(
      data is String ? data.runes.length : (data as Uint8List).length,
    );
  }

  MontyInt append(String path, Object data) {
    final entry = tree.lookup(path);
    if (entry is _Directory) throw _fsError('IsADirectoryError', path);
    if (entry is! AbstractFile) return write(path, data);
    final content = entry.readContent();
    final combined = data is String
        ? '${_text(content)}$data'
        : Uint8List.fromList([..._bytes(content), ...data as Uint8List]);
    entry.writeContent(combined);

    return MontyInt(
      data is String ? data.runes.length : (data as Uint8List).length,
    );
  }

  MontyNamedTuple stat(String path) {
    final entry = tree.require(path);

    return entry is AbstractFile
        ? StatResult.fileStat(
            _bytes(entry.readContent()).length,
            entry.permissions,
          )
        : StatResult.dirStat();
  }

  MontyNone unlink(String path) {
    final file = tree.file(path)..delete();
    final parent = tree.parent(path);
    if (parent is! _Directory) throw StateError('Expected parent directory');
    _remove(parent, file.name);

    return const MontyNone();
  }
}

Uint8List _bytes(Object content) => switch (checkedContent(content)) {
  final Uint8List bytes => bytes,
  final String text => Uint8List.fromList(utf8.encode(text)),
  _ => throw StateError('unreachable content'),
};
String _text(Object content) {
  if (content is String) return content;
  final bytes = _bytes(content);
  try {
    final decoded = utf8.decode(bytes);
    // Dart strips the leading UTF-8 BOM; Python's bytes.decode() preserves it.
    final hasBom =
        bytes.firstOrNull == 0xEF &&
        bytes.elementAtOrNull(1) == 0xBB &&
        bytes.elementAtOrNull(2) == 0xBF;

    return hasBom ? '\uFEFF$decoded' : decoded;
  } on FormatException {
    throw ExternalException('ValueError', _utf8Failure(bytes));
  }
}

String _utf8Failure(Uint8List bytes) {
  var start = 0;
  while (start < bytes.length) {
    final byte =
        bytes.elementAtOrNull(start) ??
        (throw StateError('Missing UTF-8 start byte'));
    final width = _utf8Width(byte);
    if (width == 0) {
      return _utf8Message(bytes, start, start + 1, 'invalid start byte');
    }
    for (var offset = 1; offset < width; offset++) {
      final end = start + offset;
      if (end >= bytes.length) {
        return _utf8Message(bytes, start, end, 'unexpected end of data');
      }
      final next =
          bytes.elementAtOrNull(end) ??
          (throw StateError('Missing UTF-8 continuation byte'));
      if (!_continuation(byte, next, offset)) {
        return _utf8Message(bytes, start, end, 'invalid continuation byte');
      }
    }
    start += width;
  }
  throw StateError('UTF-8 decoder rejected valid bytes');
}

bool _continuation(int start, int byte, int offset) {
  if (byte < 0x80 || byte > 0xBF) return false;
  if (offset != 1) return true;

  return switch (start) {
    0xE0 => byte >= 0xA0,
    0xED => byte <= 0x9F,
    0xF0 => byte >= 0x90,
    0xF4 => byte <= 0x8F,
    _ => true,
  };
}

String _utf8Message(Uint8List bytes, int start, int end, String reason) {
  const prefix = "'utf-8' codec can't decode";
  if (end == start + 1) {
    final byte =
        bytes.elementAtOrNull(start) ??
        (throw StateError('Missing UTF-8 error byte'));
    final hex = byte.toRadixString(16).padLeft(2, '0');

    return '$prefix byte 0x$hex in position $start: $reason';
  }

  return '$prefix bytes in position $start-${end - 1}: $reason';
}

int _utf8Width(int byte) => switch (byte) {
  < 0x80 => 1,
  >= 0xC2 && <= 0xDF => 2,
  >= 0xE0 && <= 0xEF => 3,
  >= 0xF0 && <= 0xF4 => 4,
  _ => 0,
};
