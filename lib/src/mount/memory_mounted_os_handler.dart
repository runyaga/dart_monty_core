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
/// `Path.absolute`, `Path.resolve`. Unsupported ops fall through.
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

    final rawPath = args.isEmpty ? null : args.first;
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
        final value = args.length > 1 ? args[1] : null;
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
        final value = args.length > 1 ? args[1] : null;
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
  return isAbs ? '/${segments.join('/')}' : segments.join('/');
}

MountDir? _findMount(String normalized, List<MountDir> mounts) {
  MountDir? match;
  var matchLen = -1;
  for (final m in mounts) {
    final prefix = m.virtualPath == '/'
        ? '/'
        : (m.virtualPath.endsWith('/') ? m.virtualPath : '${m.virtualPath}/');
    final inMount =
        normalized == m.virtualPath ||
        '$normalized/'.startsWith(prefix) ||
        m.virtualPath == '/';
    if (inMount && m.virtualPath.length > matchLen) {
      match = m;
      matchLen = m.virtualPath.length;
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
