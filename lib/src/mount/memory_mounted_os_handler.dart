import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/externals.dart';
import 'package:dart_monty_core/src/mount/mount_dir.dart';
import 'package:dart_monty_core/src/mount/mount_mode.dart';
import 'package:dart_monty_core/src/mount/open_call.dart';
import 'package:dart_monty_core/src/mount/vfs_content.dart';
import 'package:dart_monty_core/src/mount/vfs_file.dart';
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
/// Serves **all 19 filesystem operations** the engine can issue (the
/// `is_filesystem` set at monty-types/src/os.rs:178): `open`, `Path.read_text`,
/// `Path.read_bytes`, `Path.write_text`, `Path.write_bytes`,
/// `Path.append_text`, `Path.append_bytes`, `Path.exists`, `Path.is_file`,
/// `Path.is_dir`, `Path.is_symlink`, `Path.stat`, `Path.unlink`,
/// `Path.iterdir`, `Path.absolute`, `Path.resolve`, `Path.mkdir`,
/// `Path.rmdir`, `Path.rename`.
///
/// Anything else — a non-filesystem call such as `os.getenv`, or a path
/// outside every mount — goes to [fallthrough], or raises the call's own
/// no-handler default when no fallthrough is configured.
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
  required List<VfsFile> files,
  OsCallHandler? fallthrough,
}) {
  // Keyed by normalised path. Still FLAT in this phase — the tree lands in 1b.
  final vfs = <String, VfsFile>{
    for (final f in files) _normalizePath(f.path): f,
  };
  final normalizedMounts = mounts
      .map(
        (m) => MountDir(
          virtualPath: _normalizePath(m.virtualPath),
          mode: m.mode,
          writeBytesLimit: m.writeBytesLimit,
        ),
      )
      .toList(growable: false);

  /// Stores [content] at [path], mirroring upstream's `_write_file`
  /// (os_access.py:955-970): if a file is already there, MUTATE it rather than
  /// replacing the node.
  ///
  /// That distinction is not cosmetic. A caller holds the `VfsFile` objects it
  /// passed in, so replacing the entry would silently detach their reference
  /// and any later inspection would read a stale object.
  void putContent(String path, VfsContent content) {
    final existing = vfs[path];
    if (existing != null) {
      existing.content = content;

      return;
    }
    vfs[path] = MontyMemoryFile.withContent(path, content);
  }

  Future<Object?> notMine(
    String op,
    List<Object?> args,
    Map<String, Object?>? kwargs,
  ) async {
    if (fallthrough != null) return fallthrough(op, args, kwargs);

    // Mirror upstream's `OsFunctionCall::on_no_handler`
    // (monty-types/src/os.rs:260-274) rather than inventing wording. It splits
    // on whether the call is a filesystem operation, and this one message did
    // not: it raised `PermissionError: Path is outside any mount: <arg>` for
    // everything, which called `os.getenv`'s variable name a path, rendered
    // `null` for calls that carry no path, and claimed a file that provably
    // exists inside a mount was outside it (this is also reached from :355,
    // which sits AFTER the mount check, so "outside any mount" cannot be true
    // there).
    //
    // Emulated here rather than delegated because there is no way to decline:
    // upstream's JS calls a dedicated `resumeNotHandled`, we have no such
    // binding, and `OsCallNotHandledException` routes to `resumeNotFound`,
    // which reports a bare NAME and yields `NameError: name 'Path.read_text'
    // is not defined` — measured. Declining that way would turn a sandbox
    // refusal into a missing-function message.
    final noHandler = osCallNoHandlerDefault(op, args);
    throw OsCallException(
      noHandler.message,
      pythonExceptionType: noHandler.excType,
    );
  }

  // A parent-directory check for write_text/write_bytes lived here and was
  // REVERTED. It is correct in principle — without it a typo'd path silently
  // creates a file in a directory nobody named — but it is unsafe while
  // `mkdir` is a no-op: the parent it demands can never come into existence,
  // so `mkdir` followed by writing into that directory failed. See the
  // "mkdir then write into it" test, and reinstate this in Phase 1 once
  // directories are first-class (~/dev/plans/monty-0.19-upgrade/vfs-design.md).

  return (op, args, kwargs) async {
    // Carries [path, mode]; reads and writes then arrive separately as
    // `Path.read_text`/`write_text`/`append_text`, handled below.
    //
    // Do not "correct" this to 'Open'. Upstream's Rust enum variant is
    // `Open`, but it carries `#[strum(serialize = "open")]`, so the string
    // that crosses the boundary is lowercase — reading the Rust source
    // suggests the opposite. It is also the only undotted op name.
    if (op == 'open') {
      final rawPath = args.firstOrNull;
      if (rawPath is! String) return notMine(op, args, kwargs);
      final path = _normalizePath(rawPath);
      final mount = _findMount(path, normalizedMounts);
      if (mount == null) return notMine(op, args, kwargs);

      final modeArg = args.elementAtOrNull(1);
      final mode = modeArg is String ? modeArg : 'r';

      // Core owns the open() mode→effect mapping; this handler just supplies
      // its in-memory store primitives.
      return resolveOpenCall(
        path,
        mode,
        exists: vfs.containsKey,
        isDirectory: (p) =>
            _hasChildren(vfs, p) || _isMountRoot(p, normalizedMounts),
        ensureWritable: (p) => _requireWritable(mount, p),
        truncate: (p) => putContent(p, VfsText('')),
        createIfMissing: (p) =>
            vfs.putIfAbsent(p, () => MontyMemoryFile(p, '')),
      );
    }

    if (!op.startsWith('Path.')) return notMine(op, args, kwargs);

    final rawPath = args.firstOrNull;
    if (rawPath is! String) return notMine(op, args, kwargs);
    final path = _normalizePath(rawPath);
    final mount = _findMount(path, normalizedMounts);
    if (mount == null) return notMine(op, args, kwargs);

    switch (op) {
      case 'Path.read_text':
        final file = vfs[path];
        if (file == null) {
          throw OsCallException(
            "[Errno 2] No such file or directory: '$path'",
            pythonExceptionType: 'FileNotFoundError',
          );
        }

        return _decodeUtf8(file.content.bytes);

      case 'Path.read_bytes':
        final file = vfs[path];
        if (file == null) {
          throw OsCallException(
            "[Errno 2] No such file or directory: '$path'",
            pythonExceptionType: 'FileNotFoundError',
          );
        }

        // Return a typed bytes value (not a bare List, which would decode as
        // a Python list and break binary `open(...).read()` buffering). No
        // re-encode: the store holds the bytes as written.
        return MontyBytes(file.content.bytes);

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
        putContent(path, VfsText(value));

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
        putContent(path, VfsBytes(Uint8List.fromList(bytes)));

        return bytes.length;

      case 'Path.append_text':
        _requireWritable(mount, path);
        final value = args.elementAtOrNull(1);
        if (value is! String) {
          throw OsCallException(
            'append_text expects a string, got ${value.runtimeType}',
            pythonExceptionType: 'TypeError',
          );
        }
        _enforceLimit(mount, path, utf8.encode(value).length);
        final existing = vfs[path];
        final head = existing == null
            ? ''
            : _decodeUtf8(existing.content.bytes);
        putContent(path, VfsText('$head$value'));

        return value.length;

      case 'Path.append_bytes':
        _requireWritable(mount, path);
        final value = args.elementAtOrNull(1);
        final List<int> bytes;
        if (value is List) {
          bytes = value.cast<int>();
        } else {
          throw OsCallException(
            'append_bytes expects a List<int>, got ${value.runtimeType}',
            pythonExceptionType: 'TypeError',
          );
        }
        _enforceLimit(mount, path, bytes.length);
        final prior = vfs[path];
        putContent(
          path,
          VfsBytes(Uint8List.fromList([...?prior?.content.bytes, ...bytes])),
        );

        return bytes.length;

      case 'Path.exists':
        return vfs.containsKey(path) || _hasChildren(vfs, path);

      case 'Path.is_file':
        return vfs.containsKey(path);

      case 'Path.is_dir':
        return !vfs.containsKey(path) && _hasChildren(vfs, path);

      case 'Path.is_symlink':
        return false;

      case 'Path.stat':
        final content = vfs[path];
        final isDir =
            content == null &&
            (_hasChildren(vfs, path) || _isMountRoot(path, normalizedMounts));
        if (content == null && !isDir) {
          throw OsCallException(
            "[Errno 2] No such file or directory: '$path'",
            pythonExceptionType: 'FileNotFoundError',
          );
        }

        return isDir
            ? _dirStat()
            : _fileStat(vfs[path]?.content.byteLength ?? 0);

      case 'Path.unlink':
        _requireWritable(mount, path);
        if (!vfs.containsKey(path)) {
          throw OsCallException(
            "[Errno 2] No such file or directory: '$path'",
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
            "[Errno 17] File exists: '$path'",
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
          // CPython names the TARGET, not the missing parent, and prefixes the
          // errno — mount_fs__errors.py:129-137 asserts the exact string. This
          // said `No such directory: <parent>`, which was wrong twice.
          throw OsCallException(
            "[Errno 2] No such file or directory: '$path'",
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
            "[Errno 20] Not a directory: '$path'",
            pythonExceptionType: 'NotADirectoryError',
          );
        }
        if (_hasChildren(vfs, path)) {
          throw OsCallException(
            "[Errno 39] Directory not empty: '$path'",
            pythonExceptionType: 'OSError',
          );
        }
        // No key, no children, not a mount root: the path does not exist.
        // This used to return success, but CPython raises and
        // mount_fs__errors.py:110-115 asserts the exact message.
        //
        // The flat-map model cannot represent an EMPTY directory — `mkdir`
        // inserts nothing and `Path.exists` on a freshly-created one already
        // reports False. So "no key and no children" genuinely means absent
        // here, and raising is the answer consistent with what `exists()` says
        // about the very same path. A mount root is the one path that exists
        // without a key.
        if (!_isMountRoot(path, normalizedMounts)) {
          throw OsCallException(
            "[Errno 2] No such file or directory: '$path'",
            pythonExceptionType: 'FileNotFoundError',
          );
        }

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
          "[Errno 2] No such file or directory: '$path'",
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

bool _hasChildren(Map<String, VfsFile> vfs, String path) {
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
  Map<String, VfsFile> vfs,
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

/// Field order of Python's `os.stat_result`, mirroring upstream's
/// `STAT_RESULT_FIELDS` (monty-types/src/os.rs:487-490). The first seven are
/// ints and the last three floats; the wire distinguishes them, so a caller
/// reading `st_mtime` gets a float as CPython gives.
const _statFields = [
  'st_mode',
  'st_ino',
  'st_dev',
  'st_nlink',
  'st_uid',
  'st_gid',
  'st_size',
  'st_atime',
  'st_mtime',
  'st_ctime',
];

/// Builds a `StatResult` the way upstream's `stat_result` does
/// (monty-types/src/os.rs:460-486).
///
/// `ino`, `dev`, `uid` and `gid` are zero and the three timestamps are equal:
/// an in-memory store has no inode, no device and no owner, and inventing
/// plausible-looking values would be worse than reporting none. Upstream's own
/// mount handler does the same.
MontyNamedTuple _statResult({
  required int mode,
  required int nlink,
  required int size,
  double mtime = 0,
}) => MontyNamedTuple(
  typeName: 'StatResult',
  fieldNames: _statFields,
  values: [
    MontyInt(mode),
    const MontyInt(0),
    const MontyInt(0),
    MontyInt(nlink),
    const MontyInt(0),
    const MontyInt(0),
    MontyInt(size),
    MontyFloat(mtime),
    MontyFloat(mtime),
    MontyFloat(mtime),
  ],
);

/// A regular file: mode `0o644` with the file type bits OR'd in, one link.
MontyNamedTuple _fileStat(int size) =>
    _statResult(mode: 0x81A4, nlink: 1, size: size);

/// A directory: mode `0o755` with the directory type bits OR'd in, two links
/// (`.` and the parent's entry), and the conventional 4096-byte size.
MontyNamedTuple _dirStat() => _statResult(mode: 0x41ED, nlink: 2, size: 4096);

/// Decodes stored bytes as UTF-8, raising the way CPython does when they are
/// not valid UTF-8.
///
/// This is the payoff of storing content rather than a `String`. The previous
/// store decoded at WRITE time with `allowMalformed: true`, replacing every
/// invalid byte with U+FFFD — so by the time anything read the file the
/// offending bytes no longer existed and `read_text` could not fail even in
/// principle. Upstream decodes at the surface and lets it fail
/// (monty-fs/src/common.rs:102, :343).
///
/// Message shape follows upstream's `unicode_decode_error_msg`
/// (monty-types/src/exceptions.rs:765-779): the single-byte form names the byte
/// and its position, and the reason distinguishes an invalid START byte from an
/// invalid CONTINUATION byte — 0xC2..=0xF4 begins a multi-byte sequence,
/// anything else in the high range cannot start one.
String _decodeUtf8(Uint8List bytes) {
  try {
    return utf8.decode(bytes);
  } on FormatException catch (e) {
    final pos = e.offset ?? 0;
    final byte = bytes.elementAtOrNull(pos) ?? 0;
    final hex = '0x${byte.toRadixString(16).padLeft(2, '0')}';
    final reason = byte >= 0xC2 && byte <= 0xF4
        ? 'invalid continuation byte'
        : 'invalid start byte';

    throw OsCallException(
      "'utf-8' codec can't decode byte $hex in position $pos: $reason",
      pythonExceptionType: 'UnicodeDecodeError',
    );
  }
}
