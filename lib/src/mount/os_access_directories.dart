part of 'os_access.dart';

final class _DirectoryOperations {
  _DirectoryOperations(this.tree);
  final _MemoryTree tree;
  MontyNone mkdir(String path, {required bool parents, required bool existOk}) {
    final entry = tree.lookup(path);
    if (entry is AbstractFile || entry is _Directory && !existOk) {
      throw _fsError('FileExistsError', path);
    }
    if (entry is _Directory) return const MontyNone();
    final parent = tree.parent(path);
    if (parent is _Directory) {
      parent.children[fileName(path)] = _Directory();
    } else if (parent is AbstractFile) {
      throw _fsError('NotADirectoryError', path);
    } else if (parents) {
      var dir = tree.entries;
      for (final part in _parts(path)) {
        final next = dir.children.putIfAbsent(part, _Directory.new);
        if (next is! _Directory) throw _fsError('NotADirectoryError', path);
        dir = next;
      }
    } else {
      throw _fsError('FileNotFoundError', path);
    }
    return const MontyNone();
  }

  MontyNone rmdir(String path) {
    final dir = tree.directory(path);
    if (dir.children.isNotEmpty) throw _fsError('OSError', path);
    final parent = tree.parent(path);
    if (parent is! _Directory) throw StateError('Expected parent directory');
    _remove(parent, fileName(path));
    return const MontyNone();
  }

  MontyList iterdir(String path) => MontyList([
    for (final name in tree.directory(path).children.keys)
      MontyPath(_joinPath(path, name)),
  ]);
  MontyNone rename(String path, String target) {
    final source = tree.lookup(path);
    final parent = tree.parent(path);
    final targetParent = tree.parent(target);
    if (source == null || targetParent is! _Directory) {
      throw _fsError('FileNotFoundError', path, target);
    }
    if (parent is! _Directory) throw StateError('Expected parent directory');
    final dest = tree.lookup(target);
    _checkRenameTarget(source, dest, path, target);
    if (source is AbstractFile && dest is AbstractFile) dest.delete();
    _remove(
      parent,
      source is AbstractFile ? fileName(source.path) : fileName(path),
    );
    targetParent.children[fileName(target)] = source;
    if (source is _Directory) _rewritePaths(source, path, target);
    return const MontyNone();
  }
}

void _rewritePaths(_Directory tree, String from, String to) {
  final pending = Queue<Iterator<Object>>()..add(tree.children.values.iterator);
  final visited = <_Directory>{tree};
  final prefix = from.endsWith('/') ? from : '$from/';
  while (pending.isNotEmpty) {
    final current = pending.removeLast();
    if (!current.moveNext()) continue;
    pending.add(current);
    final entry = current.current;
    if (entry is AbstractFile) {
      if (!entry.path.startsWith(prefix)) {
        throw ExternalException(
          'ValueError',
          '${pythonRepr(entry.path)} is not in the subpath of '
              '${pythonRepr(from)}',
        );
      }
      entry.path = _joinPath(to, entry.path.substring(prefix.length));
    } else if (entry is _Directory) {
      if (!visited.add(entry)) {
        throw const ExternalException(
          'RecursionError',
          'maximum recursion depth exceeded',
        );
      }
      pending.add(entry.children.values.iterator);
    }
  }
}

void _checkRenameTarget(
  Object source,
  Object? target,
  String path,
  String dest,
) {
  if (source is AbstractFile) {
    if (target is _Directory) throw _fsError('IsADirectoryError', path, dest);
  } else {
    if (target is AbstractFile) {
      throw _fsError('NotADirectoryError', path, dest);
    }
    if (target is _Directory && target.children.isNotEmpty) {
      throw _fsError('OSError', path, dest);
    }
  }
}
