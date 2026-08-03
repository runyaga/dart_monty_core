import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/externals.dart';
import 'package:dart_monty_core/src/mount/mount_dir.dart';
import 'package:dart_monty_core/src/mount/mount_mode.dart';
import 'package:dart_monty_core/src/mount/open_call.dart';
import 'package:dart_monty_core/src/mount/vfs_content.dart';
import 'package:dart_monty_core/src/mount/vfs_node.dart';
import 'package:dart_monty_core/src/mount/vfs_tree.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';

/// Builds an [OsCallHandler] that serves Python `pathlib.Path` operations
/// from an in-memory virtual filesystem.
///
/// `mounts` declare which path prefixes Python can reach. `files` seeds the
/// backing store. Paths outside every mount fall through to [fallthrough] (or
/// raise `PermissionError` in Python if no fallthrough is given).
///
/// ```dart
/// final handler = memoryMountedOsHandler(
///   mounts: const [MountDir(virtualPath: '/data')],
///   files: [MontyMemoryFile('/data/hello.txt', 'Hello!')],
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
/// Directories are real nodes ([VfsDir]), so an empty one exists: `mkdir`
/// inserts it and `Path.exists` says `true` before anything is written into
/// it. Seeding a nested file creates its parent directories, and every mount
/// root is a directory whether or not it has contents.
///
/// Seeding two files where one's path runs through the other — `/a.txt` and
/// `/a.txt/b.txt` — throws [ArgumentError] at construction, as it does
/// upstream (`os_access.py:837-838`); it is not representable and there is no
/// useful runtime behaviour to fall back on.
OsCallHandler memoryMountedOsHandler({
  required List<MountDir> mounts,
  required List<VfsFile> files,
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

  // Mount roots are seeded as directories so a mount with nothing in it is
  // still a real directory, which is what lets `_isMountRoot` stop being a
  // special case in every existence question.
  final vfs = VfsTree(
    files: [
      for (final f in files) f..path = _normalizePath(f.path),
    ],
    mountRoots: normalizedMounts.map((m) => m.virtualPath),
  );

  /// Requires that [path]'s parent directory exists before a file is created
  /// there, per upstream's `_write_file` (os_access.py:964-970).
  ///
  /// This check was added and then REVERTED in 11bd4a8, because while `mkdir`
  /// was a no-op the parent it demanded could never come into existence and
  /// `mkdir`-then-write failed. Directories are real now, so it returns.
  void requireParentDir(String path) {
    if (vfs.parentDirOf(path) == null) {
      throw OsCallException(
        "[Errno 2] No such file or directory: '$path'",
        pythonExceptionType: 'FileNotFoundError',
      );
    }
  }

  /// Rejects an operation aimed at a directory, the way CPython does
  /// (`os_access.py:950-951`, `:960`).
  ///
  /// One guard rather than a check per op. Without it, writing to a directory
  /// SUCCEEDED: the store saw the existing node was not a file and replaced
  /// it, taking the directory and everything under it with it — silent data
  /// loss rather than a wrong message.
  void refuseDirectory(String path) {
    if (vfs.lookup(path) is VfsDir) {
      throw OsCallException(
        "[Errno 21] Is a directory: '$path'",
        pythonExceptionType: 'IsADirectoryError',
      );
    }
  }

  /// Reads the file at [path], distinguishing "is a directory" from "is not
  /// there" — reporting a directory as missing is wrong twice, because the
  /// path plainly exists and a caller told a file is absent will try to
  /// create it.
  VfsFile requireFile(String path) {
    refuseDirectory(path);
    final file = vfs.fileAt(path);
    if (file == null) {
      throw OsCallException(
        "[Errno 2] No such file or directory: '$path'",
        pythonExceptionType: 'FileNotFoundError',
      );
    }

    return file;
  }

  /// The single write path. Every content-producing op routes through here so
  /// the checks cannot drift apart between `write_text` and `open(..., 'w')`.
  void putContent(String path, VfsContent content) {
    refuseDirectory(path);
    requireParentDir(path);
    vfs.putContent(path, content);
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
        exists: vfs.exists,
        // Must move with the store, in this same commit. Left reading
        // `_hasChildren`, the 649-line open__fs.py would keep passing on
        // stale semantics — a false green, which is worse than a red.
        isDirectory: (p) => vfs.lookup(p) is VfsDir,
        ensureWritable: (p) => _requireWritable(mount, p),
        truncate: (p) => putContent(p, VfsText('')),
        createIfMissing: (p) {
          if (!vfs.exists(p)) putContent(p, VfsText(''));
        },
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
        return _decodeUtf8(requireFile(path).content.bytes);

      case 'Path.read_bytes':

        // Return a typed bytes value (not a bare List, which would decode as
        // a Python list and break binary `open(...).read()` buffering). No
        // re-encode: the store holds the bytes as written.
        return MontyBytes(requireFile(path).content.bytes);

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
        refuseDirectory(path);
        final existing = vfs.fileAt(path);
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
        refuseDirectory(path);
        final prior = vfs.fileAt(path);
        putContent(
          path,
          VfsBytes(Uint8List.fromList([...?prior?.content.bytes, ...bytes])),
        );

        return bytes.length;

      case 'Path.exists':
        return vfs.exists(path);

      case 'Path.is_file':
        return vfs.lookup(path) is VfsFile;

      case 'Path.is_dir':
        return vfs.lookup(path) is VfsDir;

      case 'Path.is_symlink':
        return false;

      case 'Path.stat':
        return switch (vfs.lookup(path)) {
          VfsDir() => _dirStat(),
          final VfsFile f => _fileStat(f.content.byteLength),
          null => throw OsCallException(
            "[Errno 2] No such file or directory: '$path'",
            pythonExceptionType: 'FileNotFoundError',
          ),
        };

      case 'Path.unlink':
        _requireWritable(mount, path);
        if (vfs.fileAt(path) == null) {
          throw OsCallException(
            "[Errno 2] No such file or directory: '$path'",
            pythonExceptionType: 'FileNotFoundError',
          );
        }
        vfs.remove(path);

        return null;

      case 'Path.iterdir':
        // Directory-vs-file and missing-path errors are Phase 2; today an
        // absent path still yields an empty listing, as it did before.
        return (vfs.childPathsOf(path) ?? const <String>[])
            .map(MontyPath.new)
            .toList();

      case 'Path.absolute':
      case 'Path.resolve':
        return path;

      case 'Path.mkdir':
        _requireWritable(mount, path);
        final parents = (kwargs?['parents'] as bool?) ?? false;
        final existOk = (kwargs?['exist_ok'] as bool?) ?? false;
        switch (vfs.lookup(path)) {
          case VfsFile():
            // A file occupies the path. exist_ok only applies to existing
            // directories — Python raises FileExistsError here regardless.
            throw OsCallException(
              "[Errno 17] File exists: '$path'",
              pythonExceptionType: 'FileExistsError',
            );
          case VfsDir():
            if (!existOk) {
              throw OsCallException(
                'Directory exists: $path',
                pythonExceptionType: 'FileExistsError',
              );
            }

            return null;
          case null:
            break;
        }
        if (vfs.parentDirOf(path) == null) {
          if (!parents) {
            // CPython names the TARGET, not the missing parent, and prefixes
            // the errno — mount_fs__errors.py:129-137 asserts the exact
            // string. This said `No such directory: <parent>`, wrong twice.
            throw OsCallException(
              "[Errno 2] No such file or directory: '$path'",
              pythonExceptionType: 'FileNotFoundError',
            );
          }
          _mkdirParents(vfs, path);
        }
        vfs.mkdir(path);

        return null;

      case 'Path.rmdir':
        _requireWritable(mount, path);
        switch (vfs.lookup(path)) {
          case VfsFile():
            throw OsCallException(
              "[Errno 20] Not a directory: '$path'",
              pythonExceptionType: 'NotADirectoryError',
            );
          case final VfsDir d:
            if (d.children.isNotEmpty) {
              throw OsCallException(
                "[Errno 39] Directory not empty: '$path'",
                pythonExceptionType: 'OSError',
              );
            }
            // An empty directory is now a real, removable node — including a
            // mount root, which the flat model had to exempt because it could
            // not tell one from an absent path.
            if (!_isMountRoot(path, normalizedMounts)) vfs.remove(path);

            return null;
          case null:
            // CPython raises; mount_fs__errors.py:110-115 asserts the message.
            throw OsCallException(
              "[Errno 2] No such file or directory: '$path'",
              pythonExceptionType: 'FileNotFoundError',
            );
        }

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
        // The full CPython matrix — file onto dir, dir onto file, dir onto
        // non-empty dir, file OVERWRITING an existing file — is Phase 3. This
        // keeps exactly the behaviour the flat store had, on the tree.
        switch (vfs.lookup(path)) {
          case VfsFile():
            requireParentDir(target);
            vfs.move(path, target);

            return null;
          case final VfsDir d when d.children.isNotEmpty:
            if (vfs.exists(target)) {
              throw OsCallException(
                'Rename target already exists: $target',
                pythonExceptionType: 'OSError',
              );
            }
            requireParentDir(target);
            vfs.move(path, target);

            return null;
          case _:
            throw OsCallException(
              "[Errno 2] No such file or directory: '$path'",
              pythonExceptionType: 'FileNotFoundError',
            );
        }
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

/// Creates the missing directories above [path], for `mkdir(parents=True)`.
void _mkdirParents(VfsTree vfs, String path) {
  final components = VfsTree.splitPath(path);
  final walked = StringBuffer();
  for (final component in components.sublist(0, components.length - 1)) {
    walked.write('/$component');
    final soFar = walked.toString();
    if (!vfs.exists(soFar)) vfs.mkdir(soFar);
  }
}

bool _isMountRoot(String normalized, List<MountDir> mounts) {
  for (final m in mounts) {
    if (m.virtualPath == normalized) return true;
  }

  return false;
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
