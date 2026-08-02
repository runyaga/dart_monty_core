// Standalone WASM fixture runner for headless-Chrome CI — the dart2wasm twin
// of wasm_runner.dart.
//
// Compile with (this file, and dart2wasm — the header was a copy of its
// dart2js sibling's and named the wrong file AND the wrong compiler, which is
// the sort of instruction that only fails for whoever follows it):
//   dart compile wasm test/integration/wasm_runner_wasm.dart \
//     -o test/integration/web/wasm_runner.wasm
//
// That is what CI runs — .github/workflows/ci.yaml:583.
//
// Runs every fixture from the compile-time corpus through MontyWasm,
// prints one JSON line per fixture, then a summary line.
//
// Output protocol:
//   FIXTURE_RESULT:{"name":"<file>","ok":<bool>}
//   FIXTURE_RESULT:{"name":"<file>","ok":false,"reason":"<msg>"}
//   FIXTURE_DONE:{"total":<n>,"passed":<n>,"failed":<n>,"skipped":<n>}
//
// The CI job greps for FIXTURE_RESULT / FIXTURE_DONE from Chrome stderr.

// Printing is the intended output mechanism for the fixture runner protocol.
// DCM: arity is known at call sites — indexed access is safe.
// ignore_for_file: avoid-unsafe-collection-methods
// DCM: this is a compiled entry-point, not a test file.
// ignore_for_file: prefer-correct-test-file-name

import 'dart:convert';
import 'dart:js_interop';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/monty_conformance.dart';

@JS('console.log')
external void _consoleLog(JSAny? message);

/// Logs [message] to the browser console.
void _log(String message) => _consoleLog(message.toJS);

// ---------------------------------------------------------------------------
// External-function dispatch
// ---------------------------------------------------------------------------

// The external-function table and dispatch live in
// `package:monty_conformance` (fixture_externals.dart), shared with the FFI
// oracle and the browser demo. They used to be duplicated here, and the copies
// drifted: this one kept `typeId: 0` on every dataclass long after the shared
// table gave each class its own, so `dataclass__basic.py` passed on FFI and
// failed on WASM. One table, one dispatch -- see FB-10.

/// Known ext-function names used in the corpus that we do NOT implement yet.
/// Any fixture calling one of these is kept skipped to avoid wrong failures.
const Set<String> _unsupportedExtFns = {};

/// v0.0.18 corpus fixtures exercising interpreter features not yet wired into
/// the WASM binding. Shared with the other WASM fixture harnesses.
// Set by `dart compile wasm -DMONTY_TEST_HOOKS=true` (tool/test_cm_wasm.sh),
// paired with a test-hooks WASM binary so `_test_cm`-based fixtures can run.
const _testHooks = bool.fromEnvironment('MONTY_TEST_HOOKS');

/// Values supplied for [MontyNameLookup] progress when the engine encounters
/// an unregistered global name. Mirrors the oracle in the monty-datatest crate.
const _nameConstants = <String, Object?>{
  'CONST_INT': 42,
  'CONST_STR': 'hello',
  'CONST_FLOAT': 3.14,
  'CONST_BOOL': true,
  'CONST_LIST': [1, 2, 3],
  'CONST_NONE': null,
};

// ---------------------------------------------------------------------------
// MontyValue → Dart conversion (used for async_call echo results)
// ---------------------------------------------------------------------------

Object? _montyValueToDart(MontyValue v) => switch (v) {
  MontyInt(:final value) => value,
  MontyFloat(:final value) => value,
  MontyString(:final value) => value,
  MontyBool(:final value) => value,
  MontyList(:final items) => items.map(_montyValueToDart).toList(),
  _ => null, // MontyNone and any other type → null
};

// ---------------------------------------------------------------------------
// OS call dispatch
// ---------------------------------------------------------------------------

/// Virtual environment for OS call tests — exactly 3 entries.
const _virtualEnv = {
  'VIRTUAL_HOME': '/virtual/home',
  'VIRTUAL_USER': 'testuser',
  'VIRTUAL_EMPTY': '',
};

/// Thrown by [_osDispatch] to signal a Python-level OS error.
/// If [pythonExceptionType] is set, it is raised as that typed exception;
/// otherwise MontyPlatform.resumeWithError raises RuntimeError.
final class _OsError implements Exception {
  const _OsError(this.message, {this.pythonExceptionType});

  final String message;
  final String? pythonExceptionType;

  @override
  String toString() => '_OsError: $message';
}

/// Mutable in-memory virtual filesystem, created fresh per fixture run.
final class _VirtualFs {
  _VirtualFs() {
    // 5 direct children of /virtual: file.txt, empty.txt, data.bin, link.txt, subdir
    _files['/virtual/file.txt'] = 'hello world\n'; // 12 bytes, mode 0o644
    _files['/virtual/empty.txt'] = '';
    _files['/virtual/data.bin'] = <int>[0, 1, 2, 3];
    _files['/virtual/link.txt'] = 'link';
    _dirs
      ..add('/virtual')
      ..add('/virtual/subdir')
      ..add('/virtual/subdir/deep');
    _files['/virtual/subdir/nested.txt'] = 'nested content';
    _files['/virtual/subdir/deep/file.txt'] = 'deep';
  }

  /// VFS rooted at `/mnt` for `# mount-fs` fixtures.
  _VirtualFs.mountFs() {
    _dirs
      ..add('/mnt')
      ..add('/mnt/subdir')
      ..add('/mnt/subdir/deep');
    _files['/mnt/hello.txt'] = 'hello world\n'; // 12 chars
    _files['/mnt/empty.txt'] = '';
    _files['/mnt/data.bin'] = <int>[0, 1, 2, 3];
    _files['/mnt/readonly.txt'] = 'readonly content'; // 16 chars → st_size=16
    _files['/mnt/subdir/nested.txt'] = 'nested content';
    _files['/mnt/subdir/deep/file.txt'] = 'deep file';
  }

  // Files: absolute path → String (text) or List<int> (bytes).
  final _files = <String, Object>{};
  // Directories: set of absolute paths.
  final _dirs = <String>{};

  bool exists(String p) => _files.containsKey(p) || _dirs.contains(p);
  bool isFile(String p) => _files.containsKey(p);
  bool isDir(String p) => _dirs.contains(p);

  List<String> iterdir(String dir) {
    if (_files.containsKey(dir)) {
      throw _OsError(
        "[Errno 20] Not a directory: '$dir'",
        pythonExceptionType: 'NotADirectoryError',
      );
    }
    if (!_dirs.contains(dir)) {
      throw _OsError(
        "[Errno 2] No such file or directory: '$dir'",
        pythonExceptionType: 'FileNotFoundError',
      );
    }
    final out = <String>[];
    for (final f in _files.keys) {
      if (_parent(f) == dir) out.add(f);
    }
    for (final d in _dirs) {
      if (d != dir && _parent(d) == dir) out.add(d);
    }

    return out;
  }

  MontyNamedTuple stat(String p) {
    int mode;
    int size;
    if (_files.containsKey(p)) {
      const sReg = 0x8000; // S_IFREG
      final c = _files[p]!;
      size = c is String ? c.length : (c as List<int>).length;
      mode = sReg | 0x1A4; // 0o644
    } else if (_dirs.contains(p)) {
      const sDir = 0x4000; // S_IFDIR
      size = 0;
      mode = sDir | 0x1ED; // 0o755
    } else {
      throw _OsError(
        "[Errno 2] No such file or directory: '$p'",
        pythonExceptionType: 'FileNotFoundError',
      );
    }

    return MontyNamedTuple(
      typeName: 'os.stat_result',
      fieldNames: const [
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
      ],
      values: [
        MontyInt(mode),
        const MontyInt(1),
        const MontyInt(1),
        const MontyInt(1),
        const MontyInt(0),
        const MontyInt(0),
        MontyInt(size),
        const MontyInt(0),
        const MontyInt(0),
        const MontyInt(0),
      ],
    );
  }

  /// Writes text to [p] and returns the number of Unicode codepoints written.
  int writeText(String p, String t) {
    if (_dirs.contains(p)) {
      throw _OsError(
        "[Errno 21] Is a directory: '$p'",
        pythonExceptionType: 'IsADirectoryError',
      );
    }
    final parent = _parent(p);
    if (parent != '/' && !_dirs.contains(parent)) {
      throw _OsError(
        "[Errno 2] No such file or directory: '$p'",
        pythonExceptionType: 'FileNotFoundError',
      );
    }
    _files[p] = t;

    return t.runes.length; // codepoint count, not UTF-16 unit count
  }

  /// Writes bytes to [p] and returns the number of bytes written (needed by
  /// the buffered binary `open(...).write()` path to advance position).
  int writeBytes(String p, List<int> b) {
    if (_dirs.contains(p)) {
      throw _OsError(
        "[Errno 21] Is a directory: '$p'",
        pythonExceptionType: 'IsADirectoryError',
      );
    }
    final parent = _parent(p);
    if (parent != '/' && !_dirs.contains(parent)) {
      throw _OsError(
        "[Errno 2] No such file or directory: '$p'",
        pythonExceptionType: 'FileNotFoundError',
      );
    }
    _files[p] = b;

    return b.length;
  }

  /// Performs the open-time effect for `open(p, mode)` and returns the
  /// FileHandle payload the interpreter resumes with. `r`/`rb` require an
  /// existing file; `w`/`wb` truncate (creating if missing); `a`/`ab` create
  /// if missing, preserving content. The engine then drives reads/writes via
  /// `Path.read_text`/`write_text`/`append_text`.
  MontyFileHandle open(String p, String mode) {
    if (_dirs.contains(p)) {
      throw _OsError(
        "[Errno 21] Is a directory: '$p'",
        pythonExceptionType: 'IsADirectoryError',
      );
    }
    final readOnly = mode == 'r' || mode == 'rb';
    if (readOnly) {
      if (!_files.containsKey(p)) {
        throw _OsError(
          "[Errno 2] No such file or directory: '$p'",
          pythonExceptionType: 'FileNotFoundError',
        );
      }
    } else {
      final parent = _parent(p);
      if (parent != '/' && !_dirs.contains(parent)) {
        throw _OsError(
          "[Errno 2] No such file or directory: '$p'",
          pythonExceptionType: 'FileNotFoundError',
        );
      }
      if (mode == 'w' || mode == 'wb') {
        _files[p] = ''; // truncate / create empty
      } else {
        _files.putIfAbsent(p, () => ''); // a/ab: create, preserve content
      }
    }

    return MontyFileHandle(path: p, mode: mode);
  }

  /// Appends text to [p], returning the number of codepoints written.
  int appendText(String p, String t) {
    final existing = _files[p];
    final base = existing is String
        ? existing
        : existing is List<int>
        ? utf8.decode(existing, allowMalformed: true)
        : '';
    _files[p] = '$base$t';

    return t.runes.length;
  }

  /// Appends bytes to [p], returning the number of bytes written.
  int appendBytes(String p, List<int> b) {
    final existing = _files[p];
    final base = existing is List<int>
        ? existing
        : existing is String
        ? utf8.encode(existing)
        : <int>[];
    _files[p] = [...base, ...b];

    return b.length;
  }

  void unlink(String p) {
    if (_dirs.contains(p)) {
      throw _OsError(
        "[Errno 1] Operation not permitted: '$p'",
        pythonExceptionType: 'PermissionError',
      );
    }
    if (!_files.containsKey(p)) {
      throw _OsError(
        "[Errno 2] No such file or directory: '$p'",
        pythonExceptionType: 'FileNotFoundError',
      );
    }
    _files.remove(p);
  }

  void rmdir(String p) {
    if (_files.containsKey(p)) {
      throw _OsError(
        "[Errno 20] Not a directory: '$p'",
        pythonExceptionType: 'NotADirectoryError',
      );
    }
    if (!_dirs.contains(p)) {
      throw _OsError(
        "[Errno 2] No such file or directory: '$p'",
        pythonExceptionType: 'FileNotFoundError',
      );
    }
    if (_hasChildren(p)) {
      throw _OsError(
        "[Errno 39] Directory not empty: '$p'",
        pythonExceptionType: 'OSError',
      );
    }
    _dirs.remove(p);
  }

  void mkdir(String p, {bool parents = false, bool existOk = false}) {
    // A file at this path always blocks mkdir (even with exist_ok).
    if (_files.containsKey(p)) {
      throw _OsError(
        "[Errno 17] File exists: '$p'",
        pythonExceptionType: 'FileExistsError',
      );
    }

    if (_dirs.contains(p)) {
      if (!existOk) {
        throw _OsError(
          "[Errno 17] File exists: '$p'",
          pythonExceptionType: 'FileExistsError',
        );
      }

      return; // exist_ok=true and dir already exists — no-op
    }

    if (parents) {
      final parts = p.split('/');
      for (var i = 2; i <= parts.length; i++) {
        final seg = parts.sublist(0, i).join('/');
        if (seg.isNotEmpty) {
          if (_files.containsKey(seg)) {
            throw _OsError(
              "[Errno 20] Not a directory: '$seg'",
              pythonExceptionType: 'NotADirectoryError',
            );
          }
          if (!_dirs.contains(seg)) _dirs.add(seg);
        }
      }
    } else {
      final parent = _parent(p);
      if (parent != '/' && !_dirs.contains(parent)) {
        throw _OsError(
          "[Errno 2] No such file or directory: '$p'",
          pythonExceptionType: 'FileNotFoundError',
        );
      }
      _dirs.add(p);
    }
  }

  String rename(String src, String dst) {
    if (!_files.containsKey(src) && !_dirs.contains(src)) {
      throw _OsError(
        "[Errno 2] No such file or directory: '$src'",
        pythonExceptionType: 'FileNotFoundError',
      );
    }

    if (_files.containsKey(src)) {
      // File rename — overwrite dst if it already exists.
      _files[dst] = _files.remove(src)!;
    } else {
      // Directory rename.
      if (_dirs.contains(dst) && _hasChildren(dst)) {
        throw _OsError(
          "[Errno 39] Directory not empty: '$dst'",
          pythonExceptionType: 'OSError',
        );
      }
      _dirs.remove(dst); // remove empty dst dir (POSIX replace semantics)

      // Move all files and subdirs under src to dst.
      final srcPrefix = '$src/';
      for (final k
          in _files.keys.where((f) => f.startsWith(srcPrefix)).toList()) {
        _files['$dst/${k.substring(srcPrefix.length)}'] = _files.remove(k)!;
      }
      for (final d
          in _dirs.where((dir) => dir.startsWith(srcPrefix)).toList()) {
        _dirs
          ..remove(d)
          ..add('$dst/${d.substring(srcPrefix.length)}');
      }
      _dirs
        ..remove(src)
        ..add(dst);
    }

    return dst;
  }

  // Private helpers come after all public members.
  String _parent(String p) {
    final i = p.lastIndexOf('/');

    return i > 0 ? p.substring(0, i) : '/';
  }

  bool _hasChildren(String dir) {
    final prefix = '$dir/';
    for (final f in _files.keys) {
      if (f.startsWith(prefix)) return true;
    }
    for (final d in _dirs) {
      if (d.startsWith(prefix)) return true;
    }

    return false;
  }
}

/// Returns the Python type name for [v], used in TypeError messages.
String _montyTypeName(MontyValue v) => switch (v) {
  MontyInt() => 'int',
  MontyFloat() => 'float',
  MontyBool() => 'bool',
  MontyString() => 'str',
  MontyBytes() => 'bytes',
  MontyList() => 'list',
  MontyDict() => 'dict',
  MontyNone() => 'NoneType',
  _ => 'object',
};

/// Throws [_OsError] if any path component exceeds 255 bytes or the total
/// path exceeds 4096 bytes.
void _validatePath(String p) {
  if (p.length > 4096) {
    throw _OsError(
      "[Errno 36] File name too long: '$p'",
      pythonExceptionType: 'OSError',
    );
  }
  for (final component in p.split('/')) {
    if (component.length > 255) {
      throw _OsError(
        "[Errno 36] File name too long: '$p'",
        pythonExceptionType: 'OSError',
      );
    }
  }
}

/// Extracts the path string from a [MontyPath] or [MontyString].
String _pathStr(MontyValue v) {
  if (v is MontyPath) return v.value;
  if (v is MontyString) return v.value;
  throw _OsError('Expected path argument, got ${v.runtimeType}');
}

/// Handles one OS call from the interpreter.
///
/// Returns the value to resume with (JSON-serializable), or throws [_OsError].
Object? _osDispatch(
  String op,
  List<MontyValue> args,
  Map<String, MontyValue>? kwargs,
  _VirtualFs vfs,
) {
  switch (op) {
    // ---- open() / file I/O ----
    case 'open':
      final p = _pathStr(args.first);
      _validatePath(p);
      final modeArg = args.length > 1 ? args[1] : const MontyString('r');
      final mode = modeArg is MontyString ? modeArg.value : 'r';

      return vfs.open(p, mode);

    case 'Path.append_text':
      final p = _pathStr(args.first);
      _validatePath(p);
      final atArg = args.length > 1 ? args[1] : const MontyNone();
      if (atArg is! MontyString) {
        throw _OsError(
          'data must be str, not ${_montyTypeName(atArg)}',
          pythonExceptionType: 'TypeError',
        );
      }

      return vfs.appendText(p, atArg.value);

    case 'Path.append_bytes':
      final p = _pathStr(args.first);
      _validatePath(p);
      final abArg = args.length > 1 ? args[1] : const MontyNone();
      if (abArg is! MontyBytes) {
        throw _OsError(
          "a bytes-like object is required, not '${_montyTypeName(abArg)}'",
          pythonExceptionType: 'TypeError',
        );
      }
      return vfs.appendBytes(p, abArg.value);

    // ---- datetime ----
    case 'date.today':
      return const MontyDate(year: 2024, month: 1, day: 15);

    case 'datetime.now':
      final tz = args.isNotEmpty ? args.first : const MontyNone();
      if (tz is MontyTimeZone) {
        return MontyDateTime(
          year: 2024,
          month: 1,
          day: 15,
          hour: 10,
          minute: 30,
          second: 0,
          offsetSeconds: tz.offsetSeconds,
          timezoneName: tz.name,
        );
      }

      // Naive datetime (no tz arg, or MontyNone)
      return const MontyDateTime(
        year: 2024,
        month: 1,
        day: 15,
        hour: 10,
        minute: 30,
        second: 0,
      );

    // ---- os.getenv ----
    case 'os.getenv':
      final key = (args.first as MontyString).value;
      if (_virtualEnv.containsKey(key)) return _virtualEnv[key];
      final def = args.length > 1 ? args[1] : const MontyNone();

      return def.dartValue;

    // ---- os.environ ----
    case 'os.environ':
      return Map<String, String>.from(_virtualEnv);

    // ---- Path existence / type queries ----
    // These do NOT validate path length — Python's exists()/is_file()/is_dir()
    // swallow ENAMETOOLONG and return False.
    case 'Path.exists':
      return vfs.exists(_pathStr(args.first));
    case 'Path.is_file':
      return vfs.isFile(_pathStr(args.first));
    case 'Path.is_dir':
      return vfs.isDir(_pathStr(args.first));
    case 'Path.is_symlink':
      return false;

    // ---- Path read ----
    case 'Path.read_text':
      final p = _pathStr(args.first);
      _validatePath(p);
      if (vfs._dirs.contains(p)) {
        throw _OsError(
          "[Errno 21] Is a directory: '$p'",
          pythonExceptionType: 'IsADirectoryError',
        );
      }
      final c = vfs._files[p];
      if (c == null) {
        throw _OsError(
          "[Errno 2] No such file or directory: '$p'",
          pythonExceptionType: 'FileNotFoundError',
        );
      }
      if (c is List<int>) {
        final bytes = c;
        try {
          return utf8.decode(bytes, allowMalformed: false);
        } on FormatException catch (e) {
          final pos = e.offset ?? 0;
          final byte = pos < bytes.length ? bytes[pos] : 0;
          final hex = '0x${byte.toRadixString(16).padLeft(2, '0')}';
          throw _OsError(
            "'utf-8' codec can't decode byte $hex "
            'in position $pos: invalid start byte',
            pythonExceptionType: 'UnicodeDecodeError',
          );
        }
      }

      return c as String;

    case 'Path.read_bytes':
      final p = _pathStr(args.first);
      _validatePath(p);
      if (vfs._dirs.contains(p)) {
        throw _OsError(
          "[Errno 21] Is a directory: '$p'",
          pythonExceptionType: 'IsADirectoryError',
        );
      }
      final c = vfs._files[p];
      if (c == null) {
        throw _OsError(
          "[Errno 2] No such file or directory: '$p'",
          pythonExceptionType: 'FileNotFoundError',
        );
      }
      // utf8.encode (not codeUnits) so non-ASCII text reads back as its real
      // on-disk UTF-8 bytes (e.g. β → 0xCE 0xB2, not the UTF-16 unit 946).
      final b = c is String ? utf8.encode(c) : c as List<int>;

      return MontyBytes(b);

    // ---- Path write / mutate ----
    case 'Path.write_text':
      final p = _pathStr(args.first);
      _validatePath(p);
      // Type-check data argument (Monty may or may not check before OS call).
      if (args.length < 2) {
        throw const _OsError(
          "Path.write_text() missing 1 required positional argument: 'data'",
          pythonExceptionType: 'TypeError',
        );
      }
      final wtArg = args[1];
      if (wtArg is! MontyString) {
        throw _OsError(
          'data must be str, not ${_montyTypeName(wtArg)}',
          pythonExceptionType: 'TypeError',
        );
      }

      return vfs.writeText(p, wtArg.value); // returns codepoint count

    case 'Path.write_bytes':
      final p = _pathStr(args.first);
      _validatePath(p);
      if (args.length < 2) {
        throw const _OsError(
          "Path.write_bytes() missing 1 required positional argument: 'data'",
          pythonExceptionType: 'TypeError',
        );
      }
      final wbArg = args[1];
      if (wbArg is! MontyBytes) {
        final wbTypeName = _montyTypeName(wbArg);
        throw _OsError(
          "memoryview: a bytes-like object is required, not '$wbTypeName'",
          pythonExceptionType: 'TypeError',
        );
      }

      return vfs.writeBytes(p, wbArg.value);

    case 'Path.mkdir':
      final p = _pathStr(args.first);
      _validatePath(p);
      final parents =
          kwargs?['parents'] is MontyBool &&
          (kwargs!['parents']! as MontyBool).value;
      final existOk =
          kwargs?['exist_ok'] is MontyBool &&
          (kwargs!['exist_ok']! as MontyBool).value;
      vfs.mkdir(p, parents: parents, existOk: existOk);

      return null;

    case 'Path.unlink':
      vfs.unlink(_pathStr(args.first));

      return null;

    case 'Path.rmdir':
      vfs.rmdir(_pathStr(args.first));

      return null;

    // ---- Path stat ----
    case 'Path.stat':
      final p = _pathStr(args.first);
      _validatePath(p);

      return vfs.stat(p);

    // ---- Path iterdir ----
    case 'Path.iterdir':
      return vfs.iterdir(_pathStr(args.first)).map(MontyPath.new).toList();

    // ---- Path rename ----
    case 'Path.rename':
      final dst = vfs.rename(_pathStr(args.first), _pathStr(args[1]));

      return MontyPath(dst);

    // ---- Path resolve / absolute ----
    case 'Path.resolve':
    case 'Path.absolute':
      return MontyPath(_pathStr(args.first));

    default:
      throw StateError('Unsupported OS call: $op');
  }
}

// ---------------------------------------------------------------------------
// Shared dispatch-loop runner (Path A + Path C)
// ---------------------------------------------------------------------------

/// Runs [source] through [platform] using `start()` + a dispatch loop.
///
/// Returns `(thrownExcType, resultValue, shouldSkip)`.
Future<(String?, MontyValue?, bool)> _runDispatchLoop(
  MontyPlatform platform,
  String source,
  String key,
  _VirtualFs vfs, {
  List<String> externalFunctions = const [],
}) async {
  String? thrownExcType;
  MontyValue? resultValue;
  var shouldSkip = false;

  MontyProgress? progress;
  try {
    progress = await platform.start(
      source,
      externalFunctions: externalFunctions,
      scriptName: key,
    );
  } on MontyScriptError catch (e) {
    thrownExcType = e.excType;
  } on MontyResourceError {
    thrownExcType = 'MemoryLimitExceeded';
  }

  if (progress != null) {
    // Stores async_call echo values keyed by callId.
    // Consumed when MontyResolveFutures arrives.
    final pendingResults = <int, Object?>{};
    dispatchLoop:
    while (true) {
      switch (progress!) {
        case MontyComplete(:final result):
          thrownExcType = result.error?.excType;
          resultValue = result.value;
          break dispatchLoop;

        case MontyPending(
          :final functionName,
          :final args,
          :final callId,
          :final kwargs,
          :final methodCall,
        ):
          if (functionName == 'async_call') {
            // Echo function: store the result and convert to a future so the
            // engine can continue running other coroutines in the same gather.
            pendingResults[callId] = _montyValueToDart(args.first);
            try {
              progress = await (platform as MontyFutureCapable)
                  .resumeAsFuture();
            } on MontyScriptError catch (e) {
              thrownExcType = e.excType;
              break dispatchLoop;
            } on MontyResourceError {
              thrownExcType = 'MemoryLimitExceeded';
              break dispatchLoop;
            }
          } else if (!conformanceExtFns.contains(functionName)) {
            if (methodCall) {
              // Unknown public method on external dataclass — raise
              // AttributeError so Python try/except blocks can catch it.
              final typeName =
                  (args.firstOrNull as MontyDataclass?)?.name ?? 'object';
              try {
                progress = await platform.resumeWithException(
                  'AttributeError',
                  "'$typeName' object has no attribute '$functionName'",
                );
              } on MontyScriptError catch (e) {
                thrownExcType = e.excType;
                break dispatchLoop;
              }
            } else {
              shouldSkip = true;
              break dispatchLoop;
            }
          } else {
            final isRaiseError = functionName == 'raise_error';
            try {
              if (isRaiseError) {
                final excType = (args.first as MontyString).value;
                final msg = (args[1] as MontyString).value;
                progress = await platform.resumeWithException(excType, msg);
              } else {
                final ret = conformanceDispatch(functionName, args, kwargs);
                progress = await platform.resume(ret);
              }
            } on MontyScriptError catch (e) {
              thrownExcType = e.excType;
              break dispatchLoop;
            } on MontyResourceError {
              thrownExcType = 'MemoryLimitExceeded';
              break dispatchLoop;
            }
          }

        case MontyOsCall(
          :final operationName,
          :final args,
          :final kwargs,
        ):
          Object? osRet;
          _OsError? osErr;
          try {
            osRet = _osDispatch(operationName, args, kwargs, vfs);
          } on _OsError catch (e) {
            osErr = e;
          }
          try {
            if (osErr case _OsError(
              :final pythonExceptionType,
              :final message,
            ) when pythonExceptionType != null) {
              progress = await platform.resumeWithException(
                pythonExceptionType,
                message,
              );
            } else if (osErr != null) {
              progress = await platform.resumeWithError(osErr.message);
            } else {
              progress = await platform.resume(osRet);
            }
          } on MontyScriptError catch (e) {
            thrownExcType = e.excType;
            break dispatchLoop;
          } on MontyResourceError {
            thrownExcType = 'MemoryLimitExceeded';
            break dispatchLoop;
          } on Object catch (_) {
            shouldSkip = true;
            break dispatchLoop;
          }

        case MontyNameLookup(:final variableName):
          try {
            if (_nameConstants.containsKey(variableName)) {
              progress = await platform.resumeNameLookup(
                variableName,
                _nameConstants[variableName],
              );
            } else {
              progress = await platform.resumeNameLookupUndefined(variableName);
            }
          } on MontyScriptError catch (e) {
            thrownExcType = e.excType;
            break dispatchLoop;
          } on MontyResourceError {
            thrownExcType = 'MemoryLimitExceeded';
            break dispatchLoop;
          }

        case MontyResolveFutures(:final pendingCallIds):
          // Resolve all pending futures with their stored echo values.
          try {
            final results = <int, Object?>{
              for (final id in pendingCallIds) id: pendingResults.remove(id),
            };
            progress = await (platform as MontyFutureCapable).resolveFutures(
              results,
            );
          } on MontyScriptError catch (e) {
            thrownExcType = e.excType;
            break dispatchLoop;
          } on MontyResourceError {
            thrownExcType = 'MemoryLimitExceeded';
            break dispatchLoop;
          }
      }
    }
  }

  return (thrownExcType, resultValue, shouldSkip);
}

// ---------------------------------------------------------------------------
// Evaluate an expectation against the actual result
// ---------------------------------------------------------------------------

/// Returns `(ok, reason)` — reason is empty when ok.
(bool, String) _evaluate(
  FixtureExpectation expectation,
  String? thrownExcType,
  MontyValue? resultValue,
) {
  switch (expectation) {
    case ExpectNoException():
      if (thrownExcType == null) return (true, '');

      return (false, 'expected no error, got $thrownExcType');

    case ExpectReturn(value: final fixtureValue):
      final expected = MontyValue.fromDart(fixtureValue);
      if (thrownExcType == null && resultValue == expected) return (true, '');
      if (thrownExcType != null) {
        // Say what was expected as well as what happened. "unexpected error:
        // X" told a reader neither which value the fixture wanted nor where it
        // died, and this runner's output IS the CI diagnostic (core#145).
        return (false, 'expected $expected, got error $thrownExcType');
      }

      return (false, 'value mismatch: expected $expected, got $resultValue');

    case ExpectRaise(:final excType):
      if (thrownExcType == excType) return (true, '');

      return (
        false,
        'excType mismatch: expected $excType, got $thrownExcType',
      );
  }
}

// ---------------------------------------------------------------------------
// Runner
// ---------------------------------------------------------------------------

Future<void> main() async {
  var passed = 0;
  var failed = 0;
  var skipped = 0;

  final stopwatch = Stopwatch()..start();
  for (final MapEntry(:key, :value) in fixtureCorpus.entries) {
    // Engine-level divergences are always skipped; test-hooks fixtures run
    // only under a `-DMONTY_TEST_HOOKS=true` build against a test-hooks WASM.
    if (alwaysUnsupportedWasmFixtures.contains(key) ||
        (!_testHooks && testHooksWasmFixtures.contains(key))) {
      skipped++;
      continue;
    }
    // -----------------------------------------------------------------------
    // Path D — run-async: start() + async dispatch loop
    // Handles pure-async fixtures and async+call-external (async_call echo).
    // -----------------------------------------------------------------------
    if (fixtureIsRunAsync(value)) {
      final expectation = parseFixture(
        value,
        skipWasm: true,
        skipRunAsync: false,
        skipCallExternal: false, // async+ext fixtures are handled here too
      );
      if (expectation == null) {
        skipped++;
        continue;
      }

      final extFns = fixtureIsCallExternal(value) ? ['async_call'] : <String>[];
      final platform = createPlatformMonty();
      try {
        final vfs = _VirtualFs();
        final (thrownExcType, resultValue, shouldSkip) = await _runDispatchLoop(
          platform,
          value,
          key,
          vfs,
          externalFunctions: extFns,
        );

        if (shouldSkip) {
          skipped++;
        } else {
          final (ok, reason) = _evaluate(
            expectation,
            thrownExcType,
            resultValue,
          );
          if (ok) {
            passed++;
            _log('FIXTURE_RESULT:{"name":"$key","ok":true}');
          } else {
            failed++;
            final escaped = reason.replaceAll('"', r'\"');
            _log(
              'FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}',
            );
          }
        }
      } on Object catch (e) {
        failed++;
        final escaped = '$e'.replaceAll('"', r'\"');
        _log('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');
      } finally {
        await platform.dispose();
      }
      continue;
    }

    // -----------------------------------------------------------------------
    // Path C — mount-fs: start() with /mnt VFS + injected `root` variable
    // -----------------------------------------------------------------------
    if (fixtureMountsFs(value)) {
      final expectation = parseFixture(
        value,
        skipWasm: true,
        skipMountFs: false,
      );
      if (expectation == null) {
        skipped++;
        continue;
      }

      // Inject `root = Path('/mnt')` before the fixture body.
      // The fixture already imports `from pathlib import Path`; the duplicate
      // import at the top is harmless in Python.
      final source = "from pathlib import Path\nroot = Path('/mnt')\n$value";

      final platform = createPlatformMonty();
      try {
        final vfs = _VirtualFs.mountFs();
        final (thrownExcType, resultValue, shouldSkip) = await _runDispatchLoop(
          platform,
          source,
          key,
          vfs,
        );

        if (shouldSkip) {
          skipped++;
        } else {
          final (ok, reason) = _evaluate(
            expectation,
            thrownExcType,
            resultValue,
          );
          if (ok) {
            passed++;
            _log('FIXTURE_RESULT:{"name":"$key","ok":true}');
          } else {
            failed++;
            final escaped = reason.replaceAll('"', r'\"');
            _log(
              'FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}',
            );
          }
        }
      } on Object catch (e) {
        failed++;
        final escaped = '$e'.replaceAll('"', r'\"');
        _log('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');
      } finally {
        await platform.dispose();
      }
      continue;
    }

    // -----------------------------------------------------------------------
    // Path A — call-external: start() + ext-function dispatch loop
    // -----------------------------------------------------------------------
    if (fixtureIsCallExternal(value)) {
      // Skip fixtures that call ext functions we haven't implemented yet.
      if (_unsupportedExtFns.any((fn) => value.contains('$fn('))) {
        skipped++;
        continue;
      }

      // Parse the fixture expectation with call-external skipping disabled
      // (run-async / mount-fs still cause a skip via parseFixture).
      final expectation = parseFixture(
        value,
        skipWasm: true,
        skipCallExternal: false,
      );
      if (expectation == null) {
        skipped++;
        continue;
      }

      final platform = createPlatformMonty();
      try {
        final vfs = _VirtualFs();
        final (thrownExcType, resultValue, shouldSkip) = await _runDispatchLoop(
          platform,
          value,
          key,
          vfs,
          externalFunctions: conformanceExtFns.toList(),
        );

        if (shouldSkip) {
          skipped++;
        } else {
          final (ok, reason) = _evaluate(
            expectation,
            thrownExcType,
            resultValue,
          );
          if (ok) {
            passed++;
            _log('FIXTURE_RESULT:{"name":"$key","ok":true}');
          } else {
            failed++;
            final escaped = reason.replaceAll('"', r'\"');
            _log(
              'FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}',
            );
          }
        }
      } on Object catch (e) {
        failed++;
        final escaped = '$e'.replaceAll('"', r'\"');
        _log('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');
      } finally {
        await platform.dispose();
      }
    } else {
      // -----------------------------------------------------------------------
      // Path B — normal: platform.run() (no external calls needed)
      // -----------------------------------------------------------------------
      final expectation = parseFixture(value, skipWasm: true);
      if (expectation == null) {
        skipped++;
        continue;
      }

      final platform = createPlatformMonty();
      try {
        MontyResult? result;
        String? thrownExcType;
        try {
          result = await platform.run(value, scriptName: key);
          thrownExcType = result.error?.excType;
        } on MontyScriptError catch (e) {
          thrownExcType = e.excType;
        } on MontyResourceError {
          thrownExcType = 'MemoryLimitExceeded';
        }

        final (ok, reason) = _evaluate(
          expectation,
          thrownExcType,
          result?.value,
        );
        if (ok) {
          passed++;
          _log('FIXTURE_RESULT:{"name":"$key","ok":true}');
        } else {
          failed++;
          final escaped = reason.replaceAll('"', r'\"');
          _log(
            'FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}',
          );
        }
      } on Object catch (e) {
        failed++;
        final escaped = '$e'.replaceAll('"', r'\"');
        _log('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');
      } finally {
        await platform.dispose();
      }
    }
  }

  _log(
    'FIXTURE_DONE:{'
    '"total":${passed + failed + skipped},'
    '"passed":$passed,'
    '"failed":$failed,'
    '"skipped":$skipped,'
    '"ms":${stopwatch.elapsedMilliseconds}'
    '}',
  );
}
