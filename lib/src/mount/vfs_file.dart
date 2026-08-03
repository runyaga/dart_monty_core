import 'dart:typed_data';

import 'package:dart_monty_core/src/mount/vfs_content.dart';

/// A file in the virtual filesystem.
///
/// An `abstract interface class` rather than a sealed type: the set of *node
/// kinds* is closed (a node is a file or a directory), but the set of *content
/// backings* is deliberately open, so a future callback-backed file can be
/// supplied from outside this library without reopening the node hierarchy.
///
/// Mirrors upstream's `AbstractFile` Protocol (`os_access.py:549-588`), which
/// abstracts leaf content only — never path resolution.
abstract interface class VfsFile {
  /// The absolute virtual path this file lives at, e.g. `/data/hello.txt`.
  String get path;

  /// The file's content.
  VfsContent get content;

  /// Replaces the file's content.
  set content(VfsContent value);

  /// Unix-style permission bits, e.g. `0o644`. Reported by `stat`, not
  /// enforced — enforcement is the mount's job (`MountMode`).
  int get permissions;
}

/// A file whose content lives in memory.
///
/// The default, and the only kind that is safe by construction: it cannot
/// reach the host filesystem. Upstream calls its equivalent "the recommended
/// file type for sandboxed Monty execution" (`os_access.py:604-606`).
final class MontyMemoryFile implements VfsFile {
  /// Creates an in-memory file from [content], which may be a `String` or a
  /// `List<int>`/`Uint8List`.
  ///
  /// Taking both keeps seeding readable — `MontyMemoryFile('/a.txt', 'hello')`
  /// rather than an explicit encode at every call site — while the stored form
  /// still records which one it was.
  factory MontyMemoryFile(
    String path,
    Object content, {
    int permissions = 0x1A4,
  }) {
    final wrapped = switch (content) {
      final String s => VfsText(s),
      final Uint8List b => VfsBytes(b),
      final List<int> b => VfsBytes(Uint8List.fromList(b)),
      _ => throw ArgumentError.value(
        content,
        'content',
        'must be a String or a List<int>',
      ),
    };

    return MontyMemoryFile._(path, wrapped, permissions);
  }

  MontyMemoryFile._(this.path, this.content, this.permissions);

  /// Creates an in-memory file from already-wrapped [content].
  ///
  /// The unnamed constructor takes a `String` or `List<int>` and wraps it; use
  /// this when you already hold a [VfsContent] and want to say which it is.
  MontyMemoryFile.withContent(
    this.path,
    this.content, {
    this.permissions = 0x1A4,
  });

  @override
  final String path;

  @override
  VfsContent content;

  @override
  final int permissions;
}
