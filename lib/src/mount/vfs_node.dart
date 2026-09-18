import 'package:dart_monty_core/src/mount/vfs_content.dart';

/// A node in the virtual filesystem: a directory or a file.
///
/// Mirrors upstream's `Tree: TypeAlias = 'dict[str, AbstractFile | Tree]'`
/// (`os_access.py:591`). Dart has no union types, so the union becomes a sealed
/// hierarchy and the compiler enforces that every lookup handles both kinds.
///
/// **Why sealed here but an interface one level down.** The set of node *kinds*
/// is closed — a node is a directory or a file, and a third party adding a
/// third kind would break every exhaustive switch. The set of content
/// *backings* is deliberately open, so a callback-backed file can be supplied
/// from outside this library. Sealing [VfsNode] and leaving [VfsFile] an
/// `abstract interface class` keeps those two axes separate: any implementation
/// of [VfsFile], including one declared elsewhere, still falls under the
/// `VfsFile()` case.
sealed class VfsNode {}

/// A directory: a named map of child nodes.
///
/// Empty directories are representable, which is the whole reason the tree
/// exists. The previous flat `path -> content` store had nothing to insert on
/// `mkdir`, so "no key" conflated *absent*, *empty directory* and *mount root*,
/// and `Path.exists` on a freshly created directory answered `false`.
final class VfsDir extends VfsNode {
  /// Creates an empty directory.
  VfsDir();

  /// Child nodes by single path component — never a path with a `/` in it.
  final Map<String, VfsNode> children = {};
}

/// A file in the virtual filesystem.
///
/// Mirrors upstream's `AbstractFile` Protocol (`os_access.py:549-588`), which
/// abstracts leaf content only, never path resolution.
abstract interface class VfsFile implements VfsNode {
  /// The absolute virtual path this file lives at, e.g. `/data/hello.txt`.
  ///
  /// Mutable because renaming a directory has to rewrite the path of every
  /// file beneath it — upstream does exactly this in
  /// `_update_paths_recursive` (`os_access.py:1128-1141`). A caller holding the
  /// file sees the new path, which is the point.
  String get path;
  set path(String value);

  /// The file's content.
  VfsContent get content;

  /// Replaces the file's content.
  set content(VfsContent value);

  /// Unix-style permission bits, e.g. `0o644`. Reported by `stat`, not
  /// enforced — enforcement is the mount's job (`MountMode`).
  int get permissions;
}
