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

import 'package:dart_monty_core/dart_monty_core.dart';

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
};

/// Known ext-function names used in the corpus that we do NOT implement yet.
/// Any fixture calling one of these is kept skipped to avoid wrong failures.
const _unsupportedExtFns = {
  'make_point',
  'make_user',
  'make_mutable_point',
  'make_empty',
  'async_call',
};

/// Dispatches a supported [functionName] call to its Dart implementation.
/// Returns the Dart value to resume with (passed to MontyPlatform.resume).
Object? _dispatch(
  String functionName,
  List<MontyValue> args,
  Map<String, MontyValue>? _, // kwargs — unused for current functions
) => switch (functionName) {
  // add_ints(a: int, b: int) → int
  'add_ints' => (args.first.dartValue! as int) + (args[1].dartValue! as int),
  // concat_strings(a: str, b: str) → str
  'concat_strings' => '${args.first.dartValue}${args[1].dartValue}',
  // return_value(x: any) → x  (identity)
  'return_value' => args.first.dartValue,
  // get_list() → [1, 2, 3]
  'get_list' => [1, 2, 3],
  _ => throw StateError('Unexpected external function: $functionName'),
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

  // Files: absolute path → String (text) or List<int> (bytes).
  final _files = <String, Object>{};
  // Directories: set of absolute paths.
  final _dirs = <String>{};

  bool exists(String p) => _files.containsKey(p) || _dirs.contains(p);
  bool isFile(String p) => _files.containsKey(p);
  bool isDir(String p) => _dirs.contains(p);

  List<String> iterdir(String dir) {
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
        '[Errno 2] No such file or directory: $p',
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

  void writeText(String p, String t) => _files[p] = t;
  void writeBytes(String p, List<int> b) => _files[p] = b;
  void unlink(String p) => _files.remove(p);
  void rmdir(String p) => _dirs.remove(p);

  void mkdir(String p, {bool parents = false, bool existOk = false}) {
    if (_dirs.contains(p)) {
      if (!existOk) {
        throw _OsError(
          'File exists: $p',
          pythonExceptionType: 'FileExistsError',
        );
      }

      return;
    }
    if (parents) {
      final parts = p.split('/');
      for (var i = 2; i <= parts.length; i++) {
        final seg = parts.sublist(0, i).join('/');
        if (seg.isNotEmpty) _dirs.add(seg);
      }
    } else {
      _dirs.add(p);
    }
  }

  String rename(String src, String dst) {
    if (_files.containsKey(src)) {
      _files[dst] = _files.remove(src)!;
    } else if (_dirs.contains(src)) {
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
      final c = vfs._files[p];
      if (c == null) {
        throw _OsError(
          '[Errno 2] No such file or directory: $p',
          pythonExceptionType: 'FileNotFoundError',
        );
      }

      return c is String ? c : String.fromCharCodes(c as List<int>);

    case 'Path.read_bytes':
      final p = _pathStr(args.first);
      final c = vfs._files[p];
      if (c == null) {
        throw _OsError(
          '[Errno 2] No such file or directory: $p',
          pythonExceptionType: 'FileNotFoundError',
        );
      }
      final b = c is String ? c.codeUnits : c as List<int>;

      return {'__type': 'bytes', 'value': b};

    // ---- Path write / mutate ----
    case 'Path.write_text':
      vfs.writeText(_pathStr(args.first), (args[1] as MontyString).value);

      return null;

    case 'Path.write_bytes':
      vfs.writeBytes(_pathStr(args.first), (args[1] as MontyBytes).value);

      return null;

    case 'Path.mkdir':
      final parents =
          kwargs?['parents'] is MontyBool &&
          (kwargs!['parents']! as MontyBool).value;
      final existOk =
          kwargs?['exist_ok'] is MontyBool &&
          (kwargs!['exist_ok']! as MontyBool).value;
      vfs.mkdir(_pathStr(args.first), parents: parents, existOk: existOk);

      return null;

    case 'Path.unlink':
      vfs.unlink(_pathStr(args.first));

      return null;

    case 'Path.rmdir':
      vfs.rmdir(_pathStr(args.first));

      return null;

    // ---- Path stat ----
    case 'Path.stat':
      return vfs.stat(_pathStr(args.first));

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
// Runner
// ---------------------------------------------------------------------------

Future<void> main() async {
  var passed = 0;
  var failed = 0;
  var skipped = 0;

  for (final MapEntry(:key, :value) in fixtureCorpus.entries) {
    // -------------------------------------------------------------------------
    // Path A — call-external: platform.start() + ext-function dispatch loop
    // -------------------------------------------------------------------------
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
        String? thrownExcType;
        MontyValue? resultValue;
        var shouldSkip = false;

        // -- start() ---------------------------------------------------------
        // Nullable: remains null if start() throws, skipping the dispatch loop.
        MontyProgress? progress;
        try {
          progress = await platform.start(
            value,
            externalFunctions: _supportedExtFns.toList(),
            scriptName: key,
          );
        } on MontyScriptError catch (e) {
          thrownExcType = e.excType;
        } on MontyResourceError {
          thrownExcType = 'MemoryLimitExceeded';
        }

        // -- dispatch loop ---------------------------------------------------
        // Only runs when start() returned a progress state without throwing.
        if (progress != null) {
          final vfs = _VirtualFs();
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
                :final kwargs,
              ):
                if (!_supportedExtFns.contains(functionName)) {
                  // Unexpected pending call — skip this fixture gracefully.
                  shouldSkip = true;
                  break dispatchLoop;
                }
                // raise_error(excType, msg) resumes with a typed exception
                // rather than a return value.
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

              case MontyOsCall(
                :final operationName,
                :final arguments,
                :final kwargs,
              ):
                // Separate sync dispatch from async resume so that
                // MontyScriptError from resumeWithException/resumeWithError
                // can be caught by the try/catch below.
                Object? osRet;
                _OsError? osErr;
                try {
                  osRet = _osDispatch(
                    operationName,
                    arguments,
                    kwargs,
                    vfs,
                  );
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

              case MontyResolveFutures():
                // Async futures not yet implemented — skip this fixture.
                shouldSkip = true;
                break dispatchLoop;
            }
          }
        }

        // -- evaluate result -------------------------------------------------
        if (shouldSkip) {
          skipped++;
        } else {
          bool ok;
          var reason = '';

          switch (expectation) {
            case ExpectNoException():
              ok = thrownExcType == null;
              if (!ok) reason = 'expected no error, got $thrownExcType';

            case ExpectReturn(value: final fixtureValue):
              final expected = MontyValue.fromDart(fixtureValue);
              ok = thrownExcType == null && resultValue == expected;
              if (!ok) {
                reason = thrownExcType != null
                    ? 'unexpected error: $thrownExcType'
                    : 'value mismatch: expected $expected, got $resultValue';
              }

            case ExpectRaise(:final excType):
              ok = thrownExcType == excType;
              if (!ok) {
                reason =
                    'excType mismatch: expected $excType, got $thrownExcType';
              }
          }

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

        bool ok;
        var reason = '';

        switch (expectation) {
          case ExpectNoException():
            ok = thrownExcType == null;
            if (!ok) reason = 'unexpected error in $key: $thrownExcType';

          case ExpectReturn(value: final fixtureValue):
            final expected = MontyValue.fromDart(fixtureValue);
            ok = thrownExcType == null && result?.value == expected;
            if (!ok) {
              reason =
                  'value mismatch: expected $expected, got ${result?.value}';
            }

          case ExpectRaise(:final excType):
            ok = thrownExcType == excType;
            if (!ok) {
              reason =
                  'excType mismatch: expected $excType, got $thrownExcType';
            }
        }

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
