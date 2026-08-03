import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:dart_monty_core/src/externals.dart';
import 'package:dart_monty_core/src/mount/mount_dir.dart';
import 'package:dart_monty_core/src/mount/mount_mode.dart';
import 'package:dart_monty_core/src/mount/open_call.dart';
import 'package:dart_monty_core/src/mount/vfs_accountant.dart';
import 'package:dart_monty_core/src/mount/vfs_content.dart';
import 'package:dart_monty_core/src/mount/vfs_node.dart';
import 'package:dart_monty_core/src/mount/vfs_path.dart';
import 'package:dart_monty_core/src/mount/vfs_tree.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';

/// Builds an [OsCallHandler] that serves Python `pathlib.Path` operations
/// from an in-memory virtual filesystem.
///
/// `mounts` declare which path prefixes Python can reach. `files` seeds the
/// backing store. Paths outside every mount fall through to [fallthrough] (or,
/// with no fallthrough, are reported as **absent** — `FileNotFoundError`, and
/// `false` from the existence queries. Not `PermissionError`: saying a path is
/// both denied and non-existent contradicts itself, and "denied" confirms the
/// path was worth denying. That holds for a `rename` target too).
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
/// - **Cumulative write limit** — bytes written through a mount, totalled
///   across calls, capped by `MountDir.writeBytesLimit` (`OSError`)
/// - **Retained-memory budget** — bytes the sandbox currently holds under a
///   mount, capped by `MountDir.memoryUsageLimit`, 100 MB by default
///   (`MemoryError`). Deleting gives budget back; the write limit is monotonic
///   and does not. A `write_bytes` loop is caught by the first, a large live
///   tree by the second.
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
          virtualPath: normalizeVfsPath(m.virtualPath),
          mode: m.mode,
          writeBytesLimit: m.writeBytesLimit,
          memoryUsageLimit: m.memoryUsageLimit,
        ),
      )
      .toList(growable: false);

  // Mount roots are seeded as directories so a mount with nothing in it is
  // still a real directory, which is what lets `_isMountRoot` stop being a
  // special case in every existence question.
  final vfs = VfsTree(
    files: [
      for (final f in files) f..path = normalizeVfsPath(f.path),
    ],
    mountRoots: normalizedMounts.map((m) => m.virtualPath),
  );

  // Per-mount byte accounting. Seeded content is deliberately NOT charged —
  // see [VfsAccountant] — so the budget bounds what the sandbox makes us
  // retain, not what the consumer handed us.
  final accountant = VfsAccountant();

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
  // directories are first-class (docs/contributor/vfs-phases.md, Phase 1b).

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
      final path = normalizeVfsPath(rawPath);
      final mount = _findMount(path, normalizedMounts);
      if (mount == null) {
        // Same premise as the Path.* ops below: outside every mount, the file
        // is not there.
        if (fallthrough == null) {
          throw OsCallException(
            "[Errno 2] No such file or directory: '$path'",
            pythonExceptionType: 'FileNotFoundError',
          );
        }

        return notMine(op, args, kwargs);
      }

      if (_pathTooLong(path)) throw _nameTooLong(path);

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
        // `open(p, 'w')` and `open(p, 'a')` create nodes, so they are charged
        // the per-entry cost even though they write no content — a million
        // `open(..., 'w')` calls is exactly the exhaustion the budget bounds.
        truncate: (p) {
          accountant.recordWrite(mount, p, wrote: 0, retains: 0);
          putContent(p, VfsText(''));
        },
        createIfMissing: (p) {
          if (vfs.exists(p)) return;
          accountant.recordWrite(mount, p, wrote: 0, retains: 0);
          putContent(p, VfsText(''));
        },
      );
    }

    if (!op.startsWith('Path.')) return notMine(op, args, kwargs);

    final rawPath = args.firstOrNull;
    if (rawPath is! String) return notMine(op, args, kwargs);
    final path = normalizeVfsPath(rawPath);
    final mount = _findMount(path, normalizedMounts);
    if (mount == null) {
      // FB-11 P5. A QUERY about a path is not an ACCESS of it. CPython
      // answers False for a path that is not there, and the sandbox's answer
      // for a path it does not mount is the same: it is not there. Raising
      // PermissionError told the caller a secret it did not ask for and made
      // `Path('/nonexistent').exists()` unusable.
      //
      // A configured fallthrough still gets first refusal — a host that DOES
      // serve those paths must not be shadowed by our answer.
      if (fallthrough == null) {
        if (_isQuery(op)) return false;

        // And the same premise, carried through: if the sandbox's answer to
        // "is it there" is no, its answer to "read it" must be "it is not
        // there", not "you may not". Saying `exists() == False` and
        // `PermissionError` about the SAME path is self-contradictory, it is
        // what pathlib__os_read_error.py rejects, and `Permission denied`
        // actually leaks more — it confirms the path is meaningful enough to
        // be worth denying.
        //
        // This is NOT the decline path. A handler that throws
        // OsCallNotHandledException still gets upstream's
        // `on_no_handler` wording (monty-types/src/os.rs:260), because
        // declining and answering are different acts.
        throw OsCallException(
          "[Errno 2] No such file or directory: '$path'",
          pythonExceptionType: 'FileNotFoundError',
        );
      }

      return notMine(op, args, kwargs);
    }

    // A name too long for the OS is checked BEFORE the store is consulted,
    // because it is a property of the path rather than of what is there.
    //
    // The predicates SWALLOW it: CPython's `exists`/`is_file`/`is_dir` catch
    // OSError and answer False, on the reasoning that an unopenable name is
    // not there and that is all the caller asked. Everything else raises.
    if (_pathTooLong(path)) {
      if (_isQuery(op)) return false;
      throw _nameTooLong(path);
    }

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
        final wroteText = utf8.encode(value).length;
        accountant.recordWrite(
          mount,
          path,
          wrote: wroteText,
          retains: wroteText,
        );
        putContent(path, VfsText(value));

        return _codepointCount(value);

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
        accountant.recordWrite(
          mount,
          path,
          wrote: bytes.length,
          retains: bytes.length,
        );
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
        refuseDirectory(path);
        final existing = vfs.fileAt(path);
        final head = existing == null
            ? ''
            : _decodeUtf8(existing.content.bytes);
        final combined = '$head$value';
        // An append WROTE only the new bytes but RETAINS the whole file.
        accountant.recordWrite(
          mount,
          path,
          wrote: utf8.encode(value).length,
          retains: utf8.encode(combined).length,
        );
        putContent(path, VfsText(combined));

        return _codepointCount(value);

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
        refuseDirectory(path);
        final prior = vfs.fileAt(path);
        final joined = Uint8List.fromList([...?prior?.content.bytes, ...bytes]);
        accountant.recordWrite(
          mount,
          path,
          wrote: bytes.length,
          retains: joined.length,
        );
        putContent(path, VfsBytes(joined));

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
        // CPython raises IsADirectoryError on Linux and PermissionError on
        // macOS; mount_fs__errors.py accepts either. IsADirectoryError is the
        // one that carries a message worth reading.
        requireFile(path);
        vfs.remove(path);
        accountant.recordRemove(mount, path);

        return null;

      case 'Path.iterdir':
        // Three distinct answers. Returning an empty list for a path that is
        // not there was the worst of them: indistinguishable from a
        // successful listing of an empty directory.
        return switch (vfs.lookup(path)) {
          final VfsDir d => [
            for (final name in d.children.keys)
              MontyPath(path == '/' ? '/$name' : '$path/$name'),
          ],
          VfsFile() => throw OsCallException(
            "[Errno 20] Not a directory: '$path'",
            pythonExceptionType: 'NotADirectoryError',
          ),
          null => throw OsCallException(
            "[Errno 2] No such file or directory: '$path'",
            pythonExceptionType: 'FileNotFoundError',
          ),
        };

      case 'Path.absolute':
      case 'Path.resolve':
        // A Path, not a str. Returning the bare String meant Python got a
        // `str`, and mount_fs__ops.py's `.name` on the result raised
        // AttributeError.
        //
        // `path` is already normalised, so `..` and `.` are collapsed.
        // Upstream's Python host does NOT do this and its comment claims it
        // does; CPython's resolve() does, and CPython is what the fixtures
        // are written against.
        return MontyPath(path);

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
              // Same message as the file case: CPython does not distinguish,
              // and mount_fs__errors.py asserts the exact string for BOTH
              // plain mkdir() and mkdir(parents=True, exist_ok=False).
              throw OsCallException(
                "[Errno 17] File exists: '$path'",
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
          _mkdirParents(vfs, path, accountant, mount);
        }
        accountant.recordMkdir(mount, path);
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
            if (!_isMountRoot(path, normalizedMounts)) {
              vfs.remove(path);
              accountant.recordRemove(mount, path);
            }

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
        final target = normalizeVfsPath(rawTarget);
        final targetMount = _findMount(target, normalizedMounts);
        if (targetMount == null) {
          // FB-11 P5 again, and it was never carried through to here. A TARGET
          // outside every mount used to decline, which with no fallthrough
          // surfaced as `PermissionError: Permission denied: '<target>'` — the
          // exact secret the source path at :237-264 was changed to stop
          // telling. Sandboxed code could distinguish "outside my mounts" from
          // "fine" by which exception came back.
          //
          // Upstream does not pin this case: `route_call` propagates `None` for
          // an unmounted dst (monty-fs/src/mount_table.rs:125) and its own
          // security test accepts either outcome outright —
          // `None => {} // Also acceptable — dst doesn't match any mount.`
          // (monty-fs/tests/fs_security.rs:1078). So this is our call, and our
          // own stated reasoning already answers it.
          //
          // FileNotFoundError naming the target also makes an out-of-mount
          // target indistinguishable from one whose parent is simply missing,
          // which `requireParentDir` already reports with this same message.
          if (fallthrough == null) {
            throw OsCallException(
              "[Errno 2] No such file or directory: '$target'",
              pythonExceptionType: 'FileNotFoundError',
            );
          }

          // `args`, not `[target]`. Declining used to rewrite the call to a
          // single argument, so a fallthrough handler received `Path.rename`
          // with its source dropped — and upstream's own `on_no_handler` names
          // the SOURCE for a rename (monty-types/src/os.rs:241,
          // `Self::Rename(a) => Some(a.src.as_str())`), never the target.
          return notMine(op, args, kwargs);
        }
        _requireWritable(targetMount, target);
        // CPython's rename is four errors and one SILENT OVERWRITE,
        // depending on what sits at each end. mount_fs__errors.py asserts
        // each message verbatim.
        //
        //   src      dst              result
        //   ------   --------------   ------------------------------------
        //   missing  -                FileNotFoundError, naming the SOURCE
        //   file     missing          move
        //   file     file             OVERWRITE, silently — POSIX semantics
        //   file     directory        IsADirectoryError
        //   dir      file             NotADirectoryError
        //   dir      non-empty dir    [Errno 39] Directory not empty
        //   dir      empty dir        move, replacing the empty directory
        final source = vfs.lookup(path);
        if (source == null) {
          throw OsCallException(
            "[Errno 2] No such file or directory: '$path'",
            pythonExceptionType: 'FileNotFoundError',
          );
        }
        switch ((source, vfs.lookup(target))) {
          case (VfsFile(), VfsDir()):
            throw OsCallException(
              "[Errno 21] Is a directory: '$target'",
              pythonExceptionType: 'IsADirectoryError',
            );
          case (VfsDir(), VfsFile()):
            throw OsCallException(
              "[Errno 20] Not a directory: '$target'",
              pythonExceptionType: 'NotADirectoryError',
            );
          case (VfsDir(), final VfsDir dst) when dst.children.isNotEmpty:
            // Upstream snapshotted errno 66 here, which is macOS's ENOTEMPTY
            // number; the fixture accepts 66 or 39 off-monty but pins 39 for
            // us, and 39 is what Linux CPython reports.
            throw OsCallException(
              "[Errno 39] Directory not empty: '$target'",
              pythonExceptionType: 'OSError',
            );
          case _:
            // Everything left over is a move: onto nothing, onto a file it
            // replaces, or onto an empty directory it takes the place of.
            requireParentDir(target);
            // A rename onto an existing file destroys it, so release the
            // target's charge before the source takes its key.
            accountant.recordRemove(targetMount, target);
            vfs.move(path, target);
            accountant.recordMove(mount, path, targetMount, target);

            return null;
        }
    }

    return notMine(op, args, kwargs);
  };
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

/// Creates the missing directories above [path], for `mkdir(parents=True)`.
///
/// A FILE in the way stops it: `mkdir -p /mnt/hello.txt/sub` cannot succeed
/// when `hello.txt` is a file, and `mount_fs__ops.py` requires an OSError
/// rather than the `StateError` the tree throws when asked to insert under a
/// non-directory. That StateError is a bug report for us, not an answer for
/// Python.
void _mkdirParents(
  VfsTree vfs,
  String path,
  VfsAccountant accountant,
  MountDir mount,
) {
  final components = VfsTree.splitPath(path);
  final walked = StringBuffer();
  for (final component in components.sublist(0, components.length - 1)) {
    walked.write('/$component');
    final soFar = walked.toString();
    switch (vfs.lookup(soFar)) {
      case VfsFile():
        throw OsCallException(
          "[Errno 20] Not a directory: '$soFar'",
          pythonExceptionType: 'NotADirectoryError',
        );
      case VfsDir():
        continue;
      case null:
        // Charged BEFORE the mkdir, so a budget refusal leaves the tree as it
        // was. `parents: true` is inherently partial on failure anyway —
        // upstream tolerates that (os_access.py:988-995) — but a node we
        // refused to charge must never exist.
        accountant.recordMkdir(mount, soFar);
        vfs.mkdir(soFar);
    }
  }
}

/// The number of Unicode CODEPOINTS in [text] — what CPython's `len(str)`
/// returns, and therefore what `write_text`/`append_text` must report.
///
/// Dart's `String.length` counts UTF-16 code units, so an astral-plane
/// character such as an emoji counts twice. The three lengths in play here
/// agree for ASCII, which is exactly why the divergence hid: `write_text`
/// returns codepoints, `stat().st_size` returns UTF-8 bytes, and
/// `String.length` is neither.
int _codepointCount(String text) => text.runes.length;

/// Whether [op] merely ASKS about a path rather than accessing it.
///
/// These four answer `false` instead of raising, in two situations: a name too
/// long for the OS, and a path outside every mount. CPython does the same —
/// `Path.exists` catches `OSError` and reports absence — and the reasoning is
/// the same in both cases: the caller asked whether something is there, and
/// the answer is no.
bool _isQuery(String op) => const {
  'Path.exists',
  'Path.is_file',
  'Path.is_dir',
  'Path.is_symlink',
}.contains(op);

/// The longest a single path component may be, in BYTES. Linux's `NAME_MAX`.
const _nameMaxBytes = 255;

/// The longest a whole path may be, in BYTES. Linux's `PATH_MAX`.
const _pathMaxBytes = 4096;

/// Whether [path] exceeds `NAME_MAX` in any component or `PATH_MAX` overall.
///
/// BYTES, not characters — 'é' is one character and two bytes, so 128 of them
/// make an illegal 256-byte component. Counting `String.length` would accept
/// it, and would also count an astral-plane character twice.
bool _pathTooLong(String path) {
  if (utf8.encode(path).length > _pathMaxBytes) return true;
  for (final component in path.split('/')) {
    if (utf8.encode(component).length > _nameMaxBytes) return true;
  }

  return false;
}

/// CPython names the FULL path here, not the offending component.
OsCallException _nameTooLong(String path) => OsCallException(
  "[Errno 36] File name too long: '$path'",
  pythonExceptionType: 'OSError',
);

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
