part of 'os_access.dart';

final class _Directory {
  final Map<String, Object> children = {};
}

final class _MemoryTree {
  _MemoryTree() {
    entries.children['/'] = _Directory();
  }

  void seed(List<AbstractFile> files, String root) {
    for (final file in files) {
      file.path = purePosixPath(
        file.path.startsWith('/') ? file.path : _joinPath(root, file.path),
      );
      final parts = _parts(file.path);
      var subtree = entries;
      for (final part in parts.take(parts.length - 1)) {
        final entry = subtree.children.putIfAbsent(part, _Directory.new);
        if (entry is! _Directory) {
          throw ArgumentError(
            'Cannot put file $file within sub-directory of file $entry',
          );
        }
        subtree = entry;
      }
      subtree.children[parts.lastOrNull ?? ''] = file;
    }
  }

  final _Directory entries = _Directory();

  Object? lookup(String path) {
    Object? entry = entries;
    final parts = _parts(path);
    if (parts.isEmpty) {
      throw const ExternalException(
        'ValueError',
        'not enough values to unpack (expected at least 1, got 0)',
      );
    }
    for (final part in parts) {
      if (entry is! _Directory) return null;
      entry = entry.children[part];
    }
    return entry;
  }

  Object require(String path) =>
      lookup(path) ?? (throw _fsError('FileNotFoundError', path));
  AbstractFile file(String path) {
    final entry = require(path);
    if (entry is AbstractFile) return entry;
    throw _fsError('IsADirectoryError', path);
  }

  _Directory directory(String path) {
    final entry = require(path);
    if (entry is _Directory) return entry;
    throw _fsError('NotADirectoryError', path);
  }

  Object? parent(String path) => lookup(_parentPath(path));
}

List<String> _parts(String path) {
  final normalized = purePosixPath(path);
  return [
    if (normalized.startsWith('//'))
      '//'
    else if (normalized.startsWith('/'))
      '/',
    ...normalized.split('/').where((p) => p.isNotEmpty && p != '.'),
  ];
}

String _parentPath(String path) {
  final parts = _parts(path);
  if (parts.length <= 1) return path.startsWith('/') ? path : '.';
  final parent = parts.take(parts.length - 1).toList();
  final root = parent.firstOrNull ?? '';
  return root.startsWith('/')
      ? root + parent.skip(1).join('/')
      : parent.join('/');
}

ExternalException _fsError(String type, String path, [String? target]) {
  final prefix = switch (type) {
    'FileNotFoundError' => '[Errno 2] No such file or directory',
    'FileExistsError' => '[Errno 17] File exists',
    'IsADirectoryError' => '[Errno 21] Is a directory',
    'NotADirectoryError' => '[Errno 20] Not a directory',
    _ =>
      target == null
          ? '[Errno 39] Directory not empty'
          : '[Errno 66] Directory not empty',
  };
  return ExternalException(
    type,
    '$prefix: ${pythonRepr(path)}'
    '${target == null ? '' : ' -> ${pythonRepr(target)}'}',
  );
}

void _remove(_Directory directory, String name) {
  if (!directory.children.containsKey(name)) {
    throw ExternalException('KeyError', pythonRepr(name));
  }
  directory.children.remove(name);
}

String _joinPath(String base, String child) =>
    purePosixPath('${base.endsWith('/') ? base : '$base/'}$child');
