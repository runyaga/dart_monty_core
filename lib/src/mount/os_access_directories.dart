part of 'os_access.dart';

final class _OsAccessDirectories {
  const _OsAccessDirectories(this.tree);
  final _OsAccessTree tree;
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
    if (source == null) throw _fsError('FileNotFoundError', path, target);
    final parent = tree.parent(path);
    if (parent is! _Directory) throw StateError('Expected parent directory');
    final targetParent = tree.parent(target);
    if (targetParent is! _Directory) {
      throw _fsError('FileNotFoundError', path, target);
    }
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
  final visited = {tree};
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

// ---------------------------------------------------------------------------
// Upstream's `Path.scan` -- the one call behind `os.scandir`, `os.walk`,
// `Path.walk` and `Path.glob`.
// ---------------------------------------------------------------------------

/// The most entries one scan may report, the root included.
const _maxScanEntries = 100000;

/// The most bytes of path data one scan may estimate.
const _maxScanPathBytes = 100000000;

/// The levels a scan that follows links descends without a depth of its own.
///
/// Following links bounds the walk, so that a link cycle ends.
const _maxScanLinkDepth = 64;

/// Upstream's `Path.scan`: the tree at a root, read in one call.
///
/// The reply is the tree -- the root itself, spelled as the empty relative
/// path, and every entry below it -- so a pattern is a pruning hint and not
/// a filter: it is read and ignored, and the sandbox runs the selector over
/// the reply itself.
MontyValue _scan(
  _OsAccessTree tree,
  List<MontyValue> args,
  Map<String, MontyValue> kwargs,
) => _OsAccessScan(tree).scan(
  _scanRoot(args.firstOrNull),
  maxDepth: _scanMaxDepth(kwargs['max_depth']),
  followSymlinks: _scanFollowSymlinks(kwargs['follow_symlinks']),
);

/// The root of a scan, as the request spelled it: the error names it so.
String _scanRoot(MontyValue? arg) => switch (arg) {
  MontyPath(:final value) || MontyString(:final value) => value,
  _ => throw const ExternalException('TypeError', 'expected a path'),
};

/// The depth a scan is bounded by; none for the whole tree.
///
/// A negative depth is the root alone, as upstream's depth is a `u32`.
int? _scanMaxDepth(MontyValue? keyword) => switch (keyword) {
  MontyInt(:final value) => value < 0 ? 0 : value,
  _ => null,
};

/// Whether a scan descends into linked directories.
///
/// A keyword that is not a boolean is false, as upstream's `follow_symlinks`
/// is.
bool _scanFollowSymlinks(MontyValue? keyword) => switch (keyword) {
  MontyBool(:final value) => value,
  _ => false,
};

/// Upstream's `Path.scan`: a subtree, read in one call.
///
/// The walk is iterative -- a stack of the directories still to list -- so a
/// deep tree costs no stack of its own. The tree is read as it is now, so a
/// file written after a scan is in the next one.
final class _OsAccessScan {
  const _OsAccessScan(this.tree);

  final _OsAccessTree tree;

  /// The entries of the tree at [root]: the root itself and every entry
  /// below it, down to [maxDepth] levels.
  ///
  /// A root that is not there is a `FileNotFoundError` naming it as the
  /// request spelled it. A root that is a file is described, not listed.
  MontyList scan(
    String root, {
    required int? maxDepth,
    required bool followSymlinks,
  }) {
    final entry = tree.lookup(root);
    if (entry == null) throw _fsError('FileNotFoundError', root);
    final entries = <MontyValue>[_scanEntry('', entry)];
    final rootPath = purePosixPath(root);
    if (_characters(rootPath) * 4 > _maxScanPathBytes) {
      throw _scanBytesError();
    }
    if (entry is! _Directory) return MontyList(entries);
    _walk(
      rootPath,
      entry,
      entries,
      maxDepth: maxDepth,
      followSymlinks: followSymlinks,
    );

    return MontyList(entries);
  }

  /// Lists the tree below [root], appending every entry to [entries].
  void _walk(
    String rootPath,
    _Directory root,
    List<MontyValue> entries, {
    required int? maxDepth,
    required bool followSymlinks,
  }) {
    // Following links without a depth of its own stops 64 levels down, as
    // upstream's does, so that a link cycle ends.
    final limit = maxDepth ?? (followSymlinks ? _maxScanLinkDepth : null);
    var pathBytes = _characters(rootPath) * 4;
    final stack = [_ScanFrame(rootPath, '', 0, root)];
    while (stack.isNotEmpty) {
      final frame = stack.removeLast();
      if (limit != null && frame.depth >= limit) continue;
      for (final child in frame.directory.children.entries) {
        pathBytes = _addChild(frame, child, entries, stack, pathBytes);
      }
    }
  }

  /// Adds one child of a listed directory to [entries] and returns the path
  /// data the tree has cost so far.
  ///
  /// The child is queued for listing when it is a directory. Upstream
  /// descends into a linked directory only when the call says to follow
  /// links; this tree holds no links, so every directory is descended into.
  int _addChild(
    _ScanFrame frame,
    MapEntry<String, Object> child,
    List<MontyValue> entries,
    List<_ScanFrame> stack,
    int pathBytes,
  ) {
    if (entries.length >= _maxScanEntries) throw _scanEntriesError();
    final name = child.key;
    final bytes = pathBytes + _scanFrameBytes(frame, name) * 4;
    if (bytes > _maxScanPathBytes) throw _scanBytesError();
    final relative = frame.relative.isEmpty ? name : '${frame.relative}/$name';
    entries.add(_scanEntry(relative, child.value));
    final value = child.value;
    if (value is _Directory) {
      stack.add(
        _ScanFrame(
          _joinPath(frame.path, name),
          relative,
          frame.depth + 1,
          value,
        ),
      );
    }

    return bytes;
  }
}

/// One entry of a scan: its path relative to the root, and what it is.
///
/// The tree holds no links, so an entry is never one.
MontyTuple _scanEntry(String relative, Object value) => MontyTuple([
  MontyString(relative),
  MontyBool(value is _Directory),
  MontyBool(value is AbstractFile),
  const MontyBool(false),
]);

/// The characters an entry costs: its relative path and its absolute one.
///
/// Upstream estimates four bytes per character of both.
int _scanFrameBytes(_ScanFrame frame, String name) {
  final nameLength = _characters(name);
  final relativeLength =
      frame.relativeLength + (frame.relative.isEmpty ? 0 : 1) + nameLength;

  return relativeLength + frame.pathLength + 1 + nameLength;
}

/// The characters of [text], as Python's `len` counts them.
int _characters(String text) => text.runes.length;

/// The error a scan that reports too many entries raises.
ExternalException _scanEntriesError() => const ExternalException(
  'RuntimeError',
  'directory scan exceeded $_maxScanEntries entries',
);

/// The error a scan that estimates too much path data raises.
ExternalException _scanBytesError() => const ExternalException(
  'RuntimeError',
  'directory scan exceeded $_maxScanPathBytes bytes of path data',
);

/// A directory a scan still has to list.
final class _ScanFrame {
  _ScanFrame(this.path, this.relative, this.depth, this.directory)
    : pathLength = _characters(path),
      relativeLength = _characters(relative);

  /// The absolute path of the directory, as upstream spells it.
  final String path;

  /// The characters of [path].
  final int pathLength;

  /// The path of the directory relative to the root of the scan.
  final String relative;

  /// The characters of [relative].
  final int relativeLength;

  /// The levels the directory is below the root of the scan.
  final int depth;

  /// The directory itself.
  final _Directory directory;
}
