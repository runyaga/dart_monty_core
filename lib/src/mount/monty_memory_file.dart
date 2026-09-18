import 'dart:typed_data';

import 'package:dart_monty_core/src/mount/vfs_content.dart';
import 'package:dart_monty_core/src/mount/vfs_node.dart';

/// A file whose content lives in memory.
///
/// The default, and the only kind that is safe by construction: it cannot reach
/// the host filesystem. Upstream calls its equivalent "the recommended file
/// type for sandboxed Monty execution" (`os_access.py:604-606`).
///
/// A write updates the instance you passed to the handler rather than replacing
/// it, so the reference you hold stays live:
///
/// ```dart
/// final out = MontyMemoryFile('/data/out.txt', '');
/// final handler = memoryMountedOsHandler(
///   mounts: const [MountDir(virtualPath: '/data')],
///   files: [out],
/// );
/// // ... Monty writes to /data/out.txt ...
/// print(out.content.text);
/// ```
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

    return MontyMemoryFile.withContent(path, wrapped, permissions: permissions);
  }

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
  String path;

  @override
  VfsContent content;

  @override
  final int permissions;
}
