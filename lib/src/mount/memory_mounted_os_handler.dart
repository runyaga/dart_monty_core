import 'dart:convert';

import 'package:dart_monty_core/src/externals.dart';
import 'package:dart_monty_core/src/mount/mount_dir.dart';
import 'package:dart_monty_core/src/mount/mount_mode.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';

/// Builds an [OsCallHandler] that serves Python `pathlib.Path` operations
/// from an in-memory virtual filesystem.
///
/// `mounts` declare which path prefixes Python can reach. `vfs` is the
/// backing store: keys are normalized absolute paths, values are file
/// contents. Paths outside every mount fall through to [fallthrough] (or
/// raise `PermissionError` in Python if no fallthrough is given).
///
/// ```dart
/// final handler = memoryMountedOsHandler(
///   mounts: const [MountDir(virtualPath: '/data')],
///   vfs: {'/data/hello.txt': 'Hello!'},
/// );
/// final r = await Monty('pathlib.Path("/data/hello.txt").read_text()')
///     .run(osHandler: handler);
/// print(r.value); // MontyString('Hello!')
/// ```
///
/// The handler enforces:
/// - **Path normalisation** (`.`, `..`, empty segments collapsed)
/// - **Sandbox boundary** (resolved path must stay under some mount's
///   `virtualPath` — `..` traversal that escapes raises
///   `PermissionError`)
/// - **Mode** (writes against a [MountMode.readOnly] mount raise
///   `PermissionError`)
/// - **Per-write byte limit** (writes exceeding `writeBytesLimit` raise
///   `OSError`); cumulative tracking across calls is a follow-up.
///
/// Supported operations: `Path.read_text`, `Path.read_bytes`,
/// `Path.write_text`, `Path.write_bytes`, `Path.exists`, `Path.is_file`,
/// `Path.is_dir`, `Path.is_symlink`, `Path.unlink`, `Path.iterdir`,
/// `Path.absolute`, `Path.resolve`, `Path.mkdir`, `Path.rmdir`,
/// `Path.rename`. Unsupported ops fall through.
///
/// Directories are implicit in the flat `Map<String, String>` model: a
/// path is a directory iff some key with that prefix exists, or the path
/// itself is a mount root. `Path.mkdir` therefore performs the relevant
/// error checks (parent missing, target already a file, target already
/// a non-empty directory under `exist_ok=False`) but does not insert
/// anything into the map on success — `Path.exists` against a freshly
/// `mkdir`'d empty directory returns `False` until a child is written.
/// This matches the trade-off of the flat-map backing store; consumers
/// that need first-class empty directories should use a richer handler.
OsCallHandler memoryMountedOsHandler({
  required List<MountDir> mounts,
  required Map<String, String> vfs,
  OsCallHandler? fallthrough,
}) {
  final normalizedMounts = mounts
      .map(
        (m) => MountDir(
          virtualPath: _normalizePath(m.virtualPath),
          mode: m.mode,
          writeBytesLimit: m.writeBytesLimit,
        ),
      )
      .toList(growable: false);

  Future<Object?> notMine(
    String op,
    List<Object?> args,
    Map<String, Object?>? kwargs,
  ) async {
    if (fallthrough != null) return fallthrough(op, args, kwargs);
    throw OsCallException(
      'Path is outside any mount: ${args.firstOrNull}',
      pythonExceptionType: 'PermissionError',
    );
  }

  return (op, args, kwargs) async {
    if (!op.startsWith('Path.')) return notMine(op, args, kwargs);

    final rawPath = args.firstOrNull;
    if (rawPath is! String) return notMine(op, args, kwargs);
    final path = _normalizePath(rawPath);
    final mount = _findMount(path, normalizedMounts);
    if (mount == null) return notMine(op, args, kwargs);

    switch (op) {
      case 'Path.read_text':
        final content = vfs[path];
        if (content == null) {
          throw OsCallException(
            'No such file: $path',
            pythonExceptionType: 'FileNotFoundError',
          );
        }

        return content;

      case 'Path.read_bytes':
        final content = vfs[path];
        if (content == null) {
          throw OsCallException(
            'No such file: $path',
            pythonExceptionType: 'FileNotFoundError',
          );
        }

        return utf8.encode(content);

      case 'Path.write_text':
        _requireWritable(mount, path);
        final value = args.elementAtOrNull(1);
        if (value is! String) {
          throw OsCallException(
            'write_text expects a string, got ${value.runtimeType}',
            pythonExceptionType: 'TypeError',
          );
        }
        _enforceLimit(mount, path, utf8.encode(value).length);
        vfs[path] = value;

        return value.length;

      case 'Path.write_bytes':
        _requireWritable(mount, path);
        final value = args.elementAtOrNull(1);
        final List<int> bytes;
        if (value is List) {
          bytes = value.cast<int>();
        } else {
          throw OsCallException(
            'write_bytes expects a List<int>, got ${value.runtimeType}',
            pythonExceptionType: 'TypeError',
          );
        }
        _enforceLimit(mount, path, bytes.length);
        vfs[path] = utf8.decode(bytes, allowMalformed: true);

        return bytes.length;

      case 'Path.exists':
        return vfs.containsKey(path) || _hasChildren(vfs, path);

      case 'Path.is_file':
        return vfs.containsKey(path);

      case 'Path.is_dir':
        return !vfs.containsKey(path) && _hasChildren(vfs, path);

      case 'Path.is_symlink':
        return false;

      case 'Path.unlink':
        _requireWritable(mount, path);
        if (!vfs.containsKey(path)) {
          throw OsCallException(
            'No such file: $path',
            pythonExceptionType: 'FileNotFoundError',
          );
        }
        vfs.remove(path);

        return null;

      case 'Path.iterdir':
        final prefix = path.endsWith('/') ? path : '$path/';
        final children = <String>{};
        for (final key in vfs.keys) {
          if (!key.startsWith(prefix)) continue;
          final tail = key.substring(prefix.length);
          final firstSlash = tail.indexOf('/');
          children.add(
            firstSlash == -1 ? key : '$prefix${tail.substring(0, firstSlash)}',
          );
        }

        return children.map(MontyPath.new).toList();

      case 'Path.absolute':
      case 'Path.resolve':
        return path;

      case 'Path.mkdir':
        _requireWritable(mount, path);
        final parents = (kwargs?['parents'] as bool?) ?? false;
        final existOk = (kwargs?['exist_ok'] as bool?) ?? false;
        if (vfs.containsKey(path)) {
          // A file occupies the path. exist_ok only applies to existing
          // directories — Python raises FileExistsError here regardless.
          throw OsCallException(
            'File exists at $path',
            pythonExceptionType: 'FileExistsError',
          );
        }
        if (_hasChildren(vfs, path) || _isMountRoot(path, normalizedMounts)) {
          if (!existOk) {
            throw OsCallException(
              'Directory exists: $path',
              pythonExceptionType: 'FileExistsError',
            );
          }

          return null;
        }
        final parentOfTarget = _parentPath(path);
        if (!parents && !_dirExists(vfs, parentOfTarget, normalizedMounts)) {
          throw OsCallException(
            'No such directory: $parentOfTarget',
            pythonExceptionType: 'FileNotFoundError',
          );
        }
        // No-op: directories are implicit. The target becomes "exists"
        // the moment a child key is written under it.

        return null;

      case 'Path.rmdir':
        _requireWritable(mount, path);
        if (vfs.containsKey(path)) {
          throw OsCallException(
            'Not a directory: $path',
            pythonExceptionType: 'NotADirectoryError',
          );
        }
        if (_hasChildren(vfs, path)) {
          throw OsCallException(
            'Directory not empty: $path',
            pythonExceptionType: 'OSError',
          );
        }
        // Empty/non-existent under the flat-map model — no key to drop.

        return null;

      case 'Path.rename':
        _requireWritable(mount, path);
        final rawTarget = args.elementAtOrNull(1);
        if (rawTarget is! String) {
          throw OsCallException(
            'rename expects a destination path string, got '
            '${rawTarget.runtimeType}',
            pythonExceptionType: 'TypeError',
          );
        }
        final target = _normalizePath(rawTarget);
        final targetMount = _findMount(target, normalizedMounts);
        if (targetMount == null) {
          return notMine(op, [target], kwargs);
        }
        _requireWritable(targetMount, target);
        final srcContent = vfs[path];
        if (srcContent != null) {
          // File rename: re-key.
          vfs.remove(path);
          vfs[target] = srcContent;

          return null;
        }
        if (_hasChildren(vfs, path)) {
          // Directory rename: re-prefix every child key. Targeting a
          // non-empty directory is rejected to avoid silent merges.
          if (_hasChildren(vfs, target) || vfs.containsKey(target)) {
            throw OsCallException(
              'Rename target already exists: $target',
              pythonExceptionType: 'OSError',
            );
          }
          final oldPrefix = path.endsWith('/') ? path : '$path/';
          final newPrefix = target.endsWith('/') ? target : '$target/';
          final moves = <String, String>{};
          for (final key in vfs.keys) {
            if (key.startsWith(oldPrefix)) {
              moves[key] = '$newPrefix${key.substring(oldPrefix.length)}';
            }
          }
          for (final entry in moves.entries) {
            final value = vfs.remove(entry.key);
            if (value != null) vfs[entry.value] = value;
          }

          return null;
        }
        throw OsCallException(
          'No such file or directory: $path',
          pythonExceptionType: 'FileNotFoundError',
        );
    }

    return notMine(op, args, kwargs);
  };
}

String _normalizePath(String path) {
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

MountDir? _findMount(String normalized, List<MountDir> mounts) {
  MountDir? match;
  var matchLen = -1;
  for (final m in mounts) {
    final virtual = m.virtualPath;
    final String prefix;
    if (virtual == '/') {
      prefix = '/';
    } else if (virtual.endsWith('/')) {
      prefix = virtual;
    } else {
      prefix = '$virtual/';
    }
    final inMount =
        normalized == virtual ||
        '$normalized/'.startsWith(prefix) ||
        virtual == '/';
    if (inMount && virtual.length > matchLen) {
      match = m;
      matchLen = virtual.length;
    }
  }

  return match;
}

void _requireWritable(MountDir mount, String path) {
  if (mount.mode == MountMode.readOnly) {
    throw OsCallException(
      'Mount is read-only: $path',
      pythonExceptionType: 'PermissionError',
    );
  }
}

void _enforceLimit(MountDir mount, String path, int bytes) {
  final limit = mount.writeBytesLimit;
  if (limit != null && bytes > limit) {
    throw OsCallException(
      'Write exceeds mount limit ($bytes > $limit bytes): $path',
      pythonExceptionType: 'OSError',
    );
  }
}

bool _hasChildren(Map<String, String> vfs, String path) {
  final prefix = path.endsWith('/') ? path : '$path/';
  for (final key in vfs.keys) {
    if (key.startsWith(prefix)) return true;
  }

  return false;
}

bool _isMountRoot(String normalized, List<MountDir> mounts) {
  for (final m in mounts) {
    if (m.virtualPath == normalized) return true;
  }

  return false;
}

bool _dirExists(
  Map<String, String> vfs,
  String normalized,
  List<MountDir> mounts,
) {
  if (_isMountRoot(normalized, mounts)) return true;

  return _hasChildren(vfs, normalized);
}

String _parentPath(String normalized) {
  if (normalized == '/' || normalized.isEmpty) return '/';
  final i = normalized.lastIndexOf('/');
  if (i <= 0) return '/';

  return normalized.substring(0, i);
}
