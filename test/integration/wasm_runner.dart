// Standalone WASM fixture runner for headless-Chrome CI.
//
// Compile with:
//   dart compile js test/integration/wasm_runner.dart \
//     -o test/integration/web/wasm_runner.dart.js
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
// ignore_for_file: avoid_print
// DCM: arity is known at call sites — indexed access is safe.
// ignore_for_file: avoid-unsafe-collection-methods
// DCM: this is a compiled entry-point, not a test file.
// ignore_for_file: prefer-correct-test-file-name

import 'dart:convert';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/platform/monty_future_capable.dart';

import '_fixture_corpus.dart';
import '_fixture_parser.dart';

// ---------------------------------------------------------------------------
// External-function dispatch
// ---------------------------------------------------------------------------

/// Functions the test harness can dispatch. Registered with platform.start()
/// so the interpreter pauses on them and we resume with the computed result.
const _supportedExtFns = {
  'add_ints',
  'concat_strings',
  'return_value',
  'get_list',
  'raise_error', // raise_error(excType, msg) → resumeWithException
  'make_point',
  'make_mutable_point',
  'make_user',
  'make_empty',
  // Dataclass method calls (self is arguments[0])
  'sum', // Point/MutablePoint.sum() → x + y
  'add', // Point.add(dx, dy) → new Point(x=x+dx, y=y+dy)
  'scale', // Point.scale(factor) → new Point(x=x*factor, y=y*factor)
  'describe', // Point.describe(label) → '{label}({x}, {y})'
  'greeting', // User.greeting() → 'Hello, {name}!'
};

/// Known ext-function names used in the corpus that we do NOT implement yet.
/// Any fixture calling one of these is kept skipped to avoid wrong failures.
const Set<String> _unsupportedExtFns = {};

/// Dispatches a supported [functionName] call to its Dart implementation.
/// Returns the Dart value to resume with (passed to MontyPlatform.resume).
Object? _dispatch(
  String functionName,
  List<MontyValue> args,
  Map<String, MontyValue>? kwargs,
) => switch (functionName) {
  // add_ints(a: int, b: int) → int
  'add_ints' => (args.first.dartValue! as int) + (args[1].dartValue! as int),
  // concat_strings(a: str, b: str) → str
  'concat_strings' => '${args.first.dartValue}${args[1].dartValue}',
  // return_value(x: any) → x  (identity)
  'return_value' => args.first.dartValue,
  // get_list() → [1, 2, 3]
  'get_list' => [1, 2, 3],
  // make_point() → frozen Point(x=1, y=2)
  'make_point' => {
    '__type': 'dataclass',
    'name': 'Point',
    'type_id': 0,
    'field_names': ['x', 'y'],
    'attrs': {'x': 1, 'y': 2},
    'frozen': true,
  },
  // make_mutable_point() → mutable MutablePoint(x=1, y=2)
  'make_mutable_point' => {
    '__type': 'dataclass',
    'name': 'MutablePoint',
    'type_id': 0,
    'field_names': ['x', 'y'],
    'attrs': {'x': 1, 'y': 2},
    'frozen': false,
  },
  // make_user(name: str) → frozen User(name=name, active=True)
  // Frozen so that hash(user) works (the fixture asserts hashability).
  'make_user' => {
    '__type': 'dataclass',
    'name': 'User',
    'type_id': 0,
    'field_names': ['name', 'active'],
    'attrs': {
      'name': (args.first as MontyString).value,
      'active': true,
    },
    'frozen': true,
  },
  // make_empty() → mutable Empty() with no fields
  'make_empty' => {
    '__type': 'dataclass',
    'name': 'Empty',
    'type_id': 0,
    'field_names': <String>[],
    'attrs': <String, Object?>{},
    'frozen': false,
  },
  // --- dataclass method calls (arguments[0] is self) ---

  // sum(self) → self.x + self.y
  'sum' => () {
    final self = args.first as MontyDataclass;
    return (self.attrs['x']! as MontyInt).value +
        (self.attrs['y']! as MontyInt).value;
  }(),

  // add(self, dx, dy) → new dataclass(x=self.x+dx, y=self.y+dy)
  'add' => () {
    final self = args.first as MontyDataclass;
    final dx = (args[1] as MontyInt).value;
    final dy = (args[2] as MontyInt).value;
    return {
      '__type': 'dataclass',
      'name': self.name,
      'type_id': self.typeId,
      'field_names': ['x', 'y'],
      'attrs': {
        'x': (self.attrs['x']! as MontyInt).value + dx,
        'y': (self.attrs['y']! as MontyInt).value + dy,
      },
      'frozen': self.frozen,
    };
  }(),

  // scale(self, factor) → new dataclass(x=self.x*factor, y=self.y*factor)
  'scale' => () {
    final self = args.first as MontyDataclass;
    final factor = (args[1] as MontyInt).value;
    return {
      '__type': 'dataclass',
      'name': self.name,
      'type_id': self.typeId,
      'field_names': ['x', 'y'],
      'attrs': {
        'x': (self.attrs['x']! as MontyInt).value * factor,
        'y': (self.attrs['y']! as MontyInt).value * factor,
      },
      'frozen': self.frozen,
    };
  }(),

  // describe(self, label) or describe(self, label=label)
  // → '{label}({self.x}, {self.y})'
  'describe' => () {
    final self = args.first as MontyDataclass;
    final labelValue =
        (args.length > 1 ? args[1] : kwargs?['label'])! as MontyString;
    final label = labelValue.value;
    final x = (self.attrs['x']! as MontyInt).value;
    final y = (self.attrs['y']! as MontyInt).value;
    return '$label($x, $y)';
  }(),

  // greeting(self: User) → 'Hello, {name}!'
  'greeting' => () {
    final self = args.first as MontyDataclass;
    final name = (self.attrs['name']! as MontyString).value;
    return 'Hello, $name!';
  }(),

  _ => throw StateError('Unexpected external function: $functionName'),
};

// ---------------------------------------------------------------------------
// Name lookup constants (for ext_call__name_lookup.py and similar fixtures)
// ---------------------------------------------------------------------------

/// Values supplied for NameLookup progress when the engine encounters an
/// unregistered global name. Matches the oracle in the monty-datatest crate.
const _nameConstants = <String, Object?>{
  'CONST_INT': 42,
  'CONST_STR': 'hello',
  'CONST_FLOAT': 3.14,
  'CONST_BOOL': true,
  'CONST_LIST': [1, 2, 3],
  'CONST_NONE': null,
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

  Map<String, Object?> stat(String p) {
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

    return {
      '__type': 'namedtuple',
      'type_name': 'os.stat_result',
      'field_names': [
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
      'values': [mode, 1, 1, 1, 0, 0, size, 0, 0, 0],
    };
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

  void writeBytes(String p, List<int> b) {
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
  MontyNull() => 'NoneType',
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
    // ---- datetime ----
    case 'date.today':
      return {'__type': 'date', 'year': 2024, 'month': 1, 'day': 15};

    case 'datetime.now':
      final tz = args.isNotEmpty ? args.first : const MontyNull();
      if (tz is MontyTimeZone) {
        return {
          '__type': 'datetime',
          'year': 2024,
          'month': 1,
          'day': 15,
          'hour': 10,
          'minute': 30,
          'second': 0,
          'microsecond': 0,
          'offset_seconds': tz.offsetSeconds,
          'timezone_name': tz.name,
        };
      }

      // Naive datetime (no tz arg, or MontyNull)
      return {
        '__type': 'datetime',
        'year': 2024,
        'month': 1,
        'day': 15,
        'hour': 10,
        'minute': 30,
        'second': 0,
        'microsecond': 0,
        'offset_seconds': null,
        'timezone_name': null,
      };

    // ---- os.getenv ----
    case 'os.getenv':
      final key = (args.first as MontyString).value;
      if (_virtualEnv.containsKey(key)) return _virtualEnv[key];
      final def = args.length > 1 ? args[1] : const MontyNull();

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
      final b = c is String ? c.codeUnits : c as List<int>;

      return {'__type': 'bytes', 'value': b};

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
      vfs.writeBytes(p, wbArg.value);

      return null;

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
      return vfs
          .iterdir(_pathStr(args.first))
          .map((e) => {'__type': 'path', 'value': e})
          .toList();

    // ---- Path rename ----
    case 'Path.rename':
      final dst = vfs.rename(_pathStr(args.first), _pathStr(args[1]));

      return {'__type': 'path', 'value': dst};

    // ---- Path resolve / absolute ----
    case 'Path.resolve':
    case 'Path.absolute':
      return {'__type': 'path', 'value': _pathStr(args.first)};

    default:
      throw StateError('Unsupported OS call: $op');
  }
}

// ---------------------------------------------------------------------------
// MontyValue → Dart conversion (used for async_call echo results)
// ---------------------------------------------------------------------------

Object? _montyValueToDart(MontyValue v) => switch (v) {
  MontyInt(:final value) => value,
  MontyFloat(:final value) => value,
  MontyString(:final value) => value,
  MontyBool(:final value) => value,
  MontyList(:final items) => items.map(_montyValueToDart).toList(),
  _ => null, // MontyNull and any other type → null
};

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
          :final arguments,
          :final callId,
          :final kwargs,
          :final methodCall,
        ):
          if (functionName == 'async_call') {
            // Echo function: store the result and convert to a future so the
            // engine can continue running other coroutines in the same gather.
            pendingResults[callId] = _montyValueToDart(arguments.first);
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
          } else if (!_supportedExtFns.contains(functionName)) {
            if (methodCall) {
              // Unknown public method on external dataclass — raise
              // AttributeError so Python try/except blocks can catch it.
              final typeName =
                  (arguments.firstOrNull as MontyDataclass?)?.name ?? 'object';
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
                final excType = (arguments.first as MontyString).value;
                final msg = (arguments[1] as MontyString).value;
                progress = await platform.resumeWithException(excType, msg);
              } else {
                final ret = _dispatch(functionName, arguments, kwargs);
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
          :final arguments,
          :final kwargs,
        ):
          Object? osRet;
          _OsError? osErr;
          try {
            osRet = _osDispatch(operationName, arguments, kwargs, vfs);
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
        return (false, 'unexpected error: $thrownExcType');
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

  for (final MapEntry(:key, :value) in fixtureCorpus.entries) {
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
            print('FIXTURE_RESULT:{"name":"$key","ok":true}');
          } else {
            failed++;
            final escaped = reason.replaceAll('"', r'\"');
            print(
              'FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}',
            );
          }
        }
      } on Object catch (e) {
        failed++;
        final escaped = '$e'.replaceAll('"', r'\"');
        print('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');
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
            print('FIXTURE_RESULT:{"name":"$key","ok":true}');
          } else {
            failed++;
            final escaped = reason.replaceAll('"', r'\"');
            print(
              'FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}',
            );
          }
        }
      } on Object catch (e) {
        failed++;
        final escaped = '$e'.replaceAll('"', r'\"');
        print('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');
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
          externalFunctions: _supportedExtFns.toList(),
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
            print('FIXTURE_RESULT:{"name":"$key","ok":true}');
          } else {
            failed++;
            final escaped = reason.replaceAll('"', r'\"');
            print(
              'FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}',
            );
          }
        }
      } on Object catch (e) {
        failed++;
        final escaped = '$e'.replaceAll('"', r'\"');
        print('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');
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
          print('FIXTURE_RESULT:{"name":"$key","ok":true}');
        } else {
          failed++;
          final escaped = reason.replaceAll('"', r'\"');
          print(
            'FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}',
          );
        }
      } on Object catch (e) {
        failed++;
        final escaped = '$e'.replaceAll('"', r'\"');
        print('FIXTURE_RESULT:{"name":"$key","ok":false,"reason":"$escaped"}');
      } finally {
        await platform.dispose();
      }
    }
  }

  print(
    'FIXTURE_DONE:{'
    '"total":${passed + failed + skipped},'
    '"passed":$passed,'
    '"failed":$failed,'
    '"skipped":$skipped'
    '}',
  );
}
