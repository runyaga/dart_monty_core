// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 03 — External functions and OS calls
//
// Python code calls back into Dart two ways:
//
//  1. externals — named host functions given to a feed. Python calls them
//     like any function; each receives the positional and keyword
//     arguments as MontyValues and returns a MontyValue (or a Future of
//     one, which is awaited).
//
//  2. os — an OsHandler that answers the sandbox's OS calls: pathlib,
//     os.getenv, os.environ and the like. Each call arrives with a dotted
//     name such as "Path.read_text" or "os.getenv". Throwing
//     OsCallNotHandledException declines the call, and throwing
//     ExternalException raises a chosen Python exception.
//
// Covers: externals, ExternalException, OsHandler, OsCallNotHandledException,
//         MontyPath.
//
// Run: dart run example/03_externals_and_os.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await Monty.withPool((monty) async {
    await monty.withSession(_externalFunctions);
    await monty.withSession(_osCallsVirtualFs);
    await monty.withSession(_osCallErrors);
  });
}

// ── External functions ───────────────────────────────────────────────────────
Future<void> _externalFunctions(MontySession session) async {
  print('\n── externals ──');

  await session.feedRun(
    '''
result = add(3, 4)
greeting = greet(name="World")
''',
    externals: {
      // Positional arguments arrive in the list.
      'add': (args, _) =>
          MontyInt((args[0] as MontyInt).value + (args[1] as MontyInt).value),
      // Keyword arguments arrive in the map.
      'greet': (_, kwargs) =>
          MontyString('Hello, ${(kwargs['name']! as MontyString).value}!'),
    },
  );
  final result = await session.feedRun('result');
  final greeting = await session.feedRun('greeting');
  print('add(3,4) = $result');
  print('greet = $greeting');
  _check(result == const MontyInt(7), 'add');
  _check(greeting == const MontyString('Hello, World!'), 'greet');

  // Return structured data; MontyValue.fromDart builds it from Dart.
  await session.feedRun(
    'data = fetch_data()',
    externals: {
      'fetch_data': (_, _) async => MontyValue.fromDart({
        'name': 'alice',
        'scores': [98, 87, 92],
      }),
    },
  );
  final scores = await session.feedRun('max(data["scores"])');
  print('best score: $scores');
  _check(scores == const MontyInt(98), 'scores');

  // A host function raises a Python exception by throwing ExternalException.
  final caught = await session.feedRun(
    '''
try:
    lookup("missing")
    out = "no error"
except KeyError as e:
    out = "caught KeyError"
out
''',
    externals: {
      'lookup': (args, _) =>
          throw const ExternalException('KeyError', 'missing'),
    },
  );
  print('lookup: $caught');
  _check(caught == const MontyString('caught KeyError'), 'KeyError');
}

// ── OS calls: a virtual filesystem ───────────────────────────────────────────
Future<void> _osCallsVirtualFs(MontySession session) async {
  print('\n── virtual filesystem ──');

  final vfs = <String, String>{
    '/data/hello.txt': 'Hello from VFS!',
    '/data/config.ini': 'debug=true\nversion=2',
  };
  const env = {'APP_ENV': 'production', 'DEBUG': 'false'};

  MontyValue os(String name, List<MontyValue> args, Map<String, MontyValue> _) {
    switch (name) {
      case 'Path.read_text':
        return MontyString(vfs[_text(args[0])] ?? '');
      case 'Path.write_text':
        final text = _text(args[1]);
        vfs[_text(args[0])] = text;

        return MontyInt(text.length);
      case 'Path.exists':
        return MontyBool(vfs.containsKey(_text(args[0])));
      case 'os.getenv':
        final value = env[_text(args[0])];

        return value == null ? const MontyNone() : MontyString(value);
      default:
        // Decline: the sandbox raises the call's own default error.
        throw const OsCallNotHandledException();
    }
  }

  final content = await session.feedRun(
    'import pathlib\npathlib.Path("/data/hello.txt").read_text()',
    os: os,
  );
  print('file content: $content');
  _check(content == const MontyString('Hello from VFS!'), 'read_text');

  await session.feedRun(
    'pathlib.Path("/data/new.txt").write_text("written from Python")',
    os: os,
  );
  print('wrote to VFS: ${vfs["/data/new.txt"]}');
  _check(vfs['/data/new.txt'] == 'written from Python', 'write_text');

  final appEnv = await session.feedRun(
    'import os\nos.getenv("APP_ENV")',
    os: os,
  );
  print('APP_ENV = $appEnv');
  _check(appEnv == const MontyString('production'), 'getenv');

  // Path objects come back to Dart as MontyPath.
  final path = await session.feedRun('pathlib.Path("/data") / "hello.txt"');
  switch (path) {
    case MontyPath(:final value):
      print('path object: $value');
      _check(value == '/data/hello.txt', 'MontyPath');
    default:
      throw StateError('expected a MontyPath, got $path');
  }
}

// ── OS call errors ───────────────────────────────────────────────────────────
Future<void> _osCallErrors(MontySession session) async {
  print('\n── os call errors ──');

  MontyValue os(String name, List<MontyValue> args, Map<String, MontyValue> _) {
    if (name == 'Path.read_text') {
      throw ExternalException(
        'PermissionError',
        'Permission denied: ${_text(args[0])}',
      );
    }
    throw const OsCallNotHandledException();
  }

  final r = await session.feedRun('''
import pathlib
try:
    pathlib.Path("/secret").read_text()
except PermissionError as e:
    result = f"caught: {e}"
result
''', os: os);
  print(r.dartValue);
  _check(r == const MontyString('caught: Permission denied: /secret'), 'r');

  // Without an OsHandler, OS calls are declined.
  try {
    await session.feedRun('pathlib.Path("/etc/passwd").read_text()');
    throw StateError('read without a handler did not raise');
  } on MontyRuntimeError catch (e) {
    print('no handler: $e');
    _check(e.exception.excType == 'PermissionError', 'declined');
  }
}

String _text(MontyValue value) => switch (value) {
  MontyString(:final value) || MontyPath(:final value) => value,
  _ => throw ArgumentError.value(value, 'value', 'not a string or path'),
};

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}
