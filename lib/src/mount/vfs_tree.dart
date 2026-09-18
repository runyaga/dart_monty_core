import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/mount/monty_memory_file.dart';
import 'package:dart_monty_core/src/mount/vfs_content.dart';
import 'package:dart_monty_core/src/mount/vfs_node.dart';

/// The in-memory directory tree backing `memoryMountedOsHandler`.
///
/// Ports upstream's `OSAccess` tree (`os_access.py:591`, `:821-840`). The one
/// invariant worth stating up front is upstream's: **the root always exists**,
/// before any file is added (`self._tree = {'/': {}}`). Every question the
/// handler asks — exists, is_dir, is_file, iterdir — is then a single lookup
/// with an unambiguous answer, instead of a prefix scan that could not tell an
/// absent path from an empty directory.
///
/// Paths in and out are normalised absolute paths (`/a/b/c.txt`). Nothing here
/// enforces mounts, modes or limits; that is the handler's job.
class VfsTree {
  /// Builds a tree from [files], creating parent directories as it goes, and
  /// pre-creates each path in [mountRoots] as a directory.
  ///
  /// Mount roots are seeded so that a mount with nothing in it is still a real
  /// directory. That removes the special case the flat store needed, where a
  /// mount root was the one path that "existed" without a key.
  ///
  /// Throws [ArgumentError] if one file's path runs through another file —
  /// seeding both `/a.txt` and `/a.txt/b.txt` cannot be represented, and
  /// upstream rejects it at construction too (`os_access.py:837-838`).
  VfsTree({
    required List<VfsFile> files,
    Iterable<String> mountRoots = const [],
  }) {
    mountRoots.forEach(_mkdirs);
    for (final file in files) {
      final components = splitPath(file.path);
      final name = components.lastOrNull;
      if (name == null) {
        throw ArgumentError.value(file.path, 'files', 'is not a file path');
      }
      final dir = _mkdirs(
        '/${components.sublist(0, components.length - 1).join('/')}',
        blamePath: file.path,
      );
      dir.children[name] = file;
    }
  }

  final VfsDir _root = VfsDir();

  /// Splits a normalised absolute path into its components.
  ///
  /// `/` yields the empty list — the root has no components, which is what
  /// makes it unnameable and therefore always present.
  static List<String> splitPath(String path) =>
      path.split('/').where((p) => p.isNotEmpty).toList();

  /// The node at [path], or `null` if nothing is there.
  ///
  /// Returns `null` as soon as an *intermediate* component turns out to be a
  /// file: `/a.txt/b` cannot resolve when `/a.txt` is a file. That `null` is
  /// where `ENOTDIR` comes from at the callers that care.
  VfsNode? lookup(String path) {
    VfsNode node = _root;
    for (final component in splitPath(path)) {
      if (node is! VfsDir) return null;
      final next = node.children[component];
      if (next == null) return null;
      node = next;
    }

    return node;
  }

  /// The file at [path], or `null` if absent or a directory.
  VfsFile? fileAt(String path) {
    final node = lookup(path);

    return node is VfsFile ? node : null;
  }

  /// The directory at [path], or `null` if absent or a file.
  VfsDir? dirAt(String path) {
    final node = lookup(path);

    return node is VfsDir ? node : null;
  }

  /// Whether anything exists at [path].
  bool exists(String path) => lookup(path) != null;

  /// The directory containing [path], or `null` if the parent is missing or is
  /// itself a file.
  VfsDir? parentDirOf(String path) => dirAt(parentPath(path));

  /// The absolute paths of [path]'s direct children, or `null` if [path] is not
  /// a directory.
  List<String>? childPathsOf(String path) {
    final dir = dirAt(path);
    if (dir == null) return null;
    final prefix = path == '/' ? '' : path;

    return [for (final name in dir.children.keys) '$prefix/$name'];
  }

  /// Stores [content] at [path], creating the file if it is not there.
  ///
  /// Mirrors upstream's `_write_file` (`os_access.py:955-970`): when a file
  /// already exists it is MUTATED, not replaced. That is not cosmetic — the
  /// caller holds the [VfsFile] it passed in, and replacing the node would
  /// silently detach their reference.
  ///
  /// The caller is responsible for having checked that [path] is not a
  /// directory and that its parent exists; this throws [StateError] if it is
  /// reached with a missing parent, because that is a bug in the caller rather
  /// than something Python did.
  void putContent(String path, VfsContent content) {
    final existing = lookup(path);
    if (existing is VfsFile) {
      existing.content = content;

      return;
    }
    final parent = parentDirOf(path);
    if (parent == null) {
      throw StateError('putContent($path): parent directory does not exist');
    }
    parent.children[_leafOf(path)] = MontyMemoryFile.withContent(path, content);
  }

  /// Creates an empty directory at [path]. The parent must already exist.
  void mkdir(String path) {
    final parent = parentDirOf(path);
    if (parent == null) {
      throw StateError('mkdir($path): parent directory does not exist');
    }
    parent.children[_leafOf(path)] = VfsDir();
  }

  /// Removes whatever is at [path] and returns it, or `null` if nothing was
  /// there. The root itself cannot be removed.
  VfsNode? remove(String path) {
    final name = splitPath(path).lastOrNull;
    if (name == null) return null;

    return parentDirOf(path)?.children.remove(name);
  }

  /// Moves the node at [from] to [to], rewriting the `path` of every file in
  /// the moved subtree.
  ///
  /// Upstream does the same rewrite in `_update_paths_recursive`
  /// (`os_access.py:1128-1141`): the tree structure moves, but the
  /// [VfsFile] objects still carry their old paths until they are reassigned.
  /// Callers holding those files see the new path.
  void move(String from, String to) {
    final node = remove(from);
    if (node == null) return;
    final parent = parentDirOf(to);
    if (parent == null) {
      throw StateError('move($from, $to): destination parent does not exist');
    }
    parent.children[_leafOf(to)] = node;
    _rewritePaths(node, to);
  }

  void _rewritePaths(VfsNode node, String newPath) {
    switch (node) {
      case VfsFile():
        node.path = newPath;
      case VfsDir():
        final prefix = newPath == '/' ? '' : newPath;
        for (final entry in node.children.entries) {
          _rewritePaths(entry.value, '$prefix/${entry.key}');
        }
    }
  }

  /// The final component of [path].
  ///
  /// The root has no name, so creating, replacing or removing it is not
  /// expressible — a caller that gets here with `/` has a bug rather than a
  /// filesystem error to report.
  static String _leafOf(String path) {
    final name = splitPath(path).lastOrNull;
    if (name == null) {
      throw StateError('the root directory has no name: $path');
    }

    return name;
  }

  /// Creates every directory along [path] and returns the deepest one.
  ///
  /// [blamePath] names the file being seeded, so a conflict reports the file
  /// the caller wrote rather than the intermediate directory it implied.
  VfsDir _mkdirs(String path, {String? blamePath}) {
    var dir = _root;
    final walked = StringBuffer();
    for (final component in splitPath(path)) {
      walked.write('/$component');
      final existing = dir.children[component];
      switch (existing) {
        case null:
          final created = VfsDir();
          dir.children[component] = created;
          dir = created;
        case final VfsDir d:
          dir = d;
        case VfsFile():
          throw ArgumentError.value(
            blamePath ?? path,
            'files',
            'cannot be placed under $walked, which is a file',
          );
      }
    }

    return dir;
  }
}

/// The parent of a normalised absolute path. The root is its own parent.
String parentPath(String path) {
  final components = VfsTree.splitPath(path);
  if (components.isEmpty) return '/';

  return '/${components.sublist(0, components.length - 1).join('/')}';
}
