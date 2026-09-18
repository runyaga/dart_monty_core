/// Collapses `.`, `..` and empty segments, CLAMPING at the root.
///
/// Deliberately hand-rolled rather than `package:path`'s `p.posix.normalize`,
/// which is a correct POSIX normaliser and therefore the wrong tool here.
/// Measured, on the cases that matter:
///
///     input                       p.posix.normalize   this
///     /mnt/../../../etc/passwd    /etc/passwd         /etc/passwd
///     ../escape.txt               ../escape.txt       /escape.txt
///     '' (empty)                  .                   /
///
/// This is a clamp, not a normalisation: every path is treated as absolute and
/// `..` can never survive, so no input can produce a result that is not rooted
/// before `_findMount` sees it. `p.posix.normalize` preserves a leading `..`
/// because that is what POSIX means, and it would hand a relative string to
/// the mount check.
///
/// (Dart has no first-class `Path` type to lean on — `package:path` is
/// functions over `String` by design, and `MontyPath` is a wire value, not a
/// path library.)
///
/// Internal, but shared: `memoryMountedOsHandler` clamps every path that
/// crosses its surface, and `VfsCallbackFile` clamps the path it freezes at
/// construction so the two agree. They must agree — the handler re-clamps a
/// seeded file's `path`, and a callback file whose frozen path differed from
/// its seeded one would hand the host a path the tree never used.
String normalizeVfsPath(String path) {
  if (path.isEmpty) return '/';
  final isAbs = path.startsWith('/');
  final segments = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (segments.isNotEmpty) segments.removeLast();
      continue;
    }
    segments.add(part);
  }
  final joined = segments.join('/');

  return isAbs ? '/$joined' : joined;
}
