// 03 — External functions and OS calls
//
// Python code can call back into Dart via two mechanisms:
//
//  1. externalFunctions — named host functions declared before execution.
//     Python calls them like regular functions; Dart handles each call.
//
//  2. osHandler — intercepts pathlib, os.getenv, os.environ, datetime
//     operations. Lets you provide a virtual filesystem or sandbox.
//
// Covers: MontyCallback, OsCallHandler, OsCallException, externalFunctions param,
//         Monty(osHandler:), MontyPath, MontyResult.printOutput.
//
// Run: dart run example/03_externals_and_os.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await _externalFunctions();
  await _osCallsVirtualFs();
  await _osCallError();
}

// ── External functions ────────────────────────────────────────────────────────
// MontyCallback = Future<Object?> Function(Map<String, Object?> args)
//
// Positional args arrive as '_0', '_1', ... in the map.
// Keyword args arrive under their Python names.
Future<void> _externalFunctions() async {
  print('\n── externalFunctions ──');

  final session = MontySession();

  await session.run(
    '''
result = add(3, 4)
greeting = greet(name="World")
''',
    externalFunctions: {
      // Synchronous-style: return the value directly.
      'add': (args) async => (args['_0'] as int) + (args['_1'] as int),

      // Keyword args land under their Python names.
      'greet': (args) async => 'Hello, ${args['name']}!',
    },
  );

  print('add(3,4) = ${(await session.run("result")).value}'); // 7
  print('greet = ${(await session.run("greeting")).value}'); // Hello, World!

  // Return complex types: Dart List/Map are converted to Python list/dict.
  await session.run(
    'data = fetch_data()',
    externalFunctions: {
      'fetch_data': (_) async => {
        'name': 'alice',
        'scores': [98, 87, 92],
      },
    },
  );
  final data = await session.run('data["scores"]');
  print('scores: $data'); // MontyList

  session.dispose();
}

// ── OS calls: virtual filesystem ─────────────────────────────────────────────
// OsCallHandler = Future<Object?> Function(String op, List<Object?> args, Map?)
//
// Python `pathlib.Path`, `os.getenv`, `os.environ`, `datetime.now()` etc.
// all route through the osHandler. Each operation has a dotted name like
// "Path.read_text" or "os.getenv".
Future<void> _osCallsVirtualFs() async {
  print('\n── virtual filesystem ──');

  // In-memory VFS.
  final vfs = <String, String>{
    '/data/hello.txt': 'Hello from VFS!',
    '/data/config.ini': 'debug=true\nversion=2',
  };

  Future<Object?> osHandler(
    String op,
    List<Object?> args,
    Map<String, Object?>? kwargs,
  ) async {
    switch (op) {
      case 'Path.read_text':
        final path = args.first as String;
        return vfs[path] ?? '';
      case 'Path.write_text':
        vfs[args[0] as String] = args[1] as String;
        return null;
      case 'Path.exists':
        return vfs.containsKey(args.first as String);
      case 'Path.unlink':
        vfs.remove(args.first as String);
        return null;
      case 'os.getenv':
        final key = args.first as String;
        return {'APP_ENV': 'production', 'DEBUG': 'false'}[key];
      default:
        throw OsCallException('$op not supported');
    }
  }

  final session = MontySession(osHandler: osHandler);

  // pathlib works across calls because state persists on the Rust REPL heap.
  await session.run('import pathlib');
  final content = await session.run(
    'pathlib.Path("/data/hello.txt").read_text()',
  );
  print('file content: ${content.value}');

  // Write then read back.
  await session.run(
    'pathlib.Path("/data/new.txt").write_text("written from Python")',
  );
  print('wrote to VFS: ${vfs["/data/new.txt"]}');

  // os.getenv
  final env = await session.run('import os; os.getenv("APP_ENV")');
  print('APP_ENV = ${env.value}');

  // MontyPath: Python Path objects round-trip as MontyPath values.
  final pathVal = await session.run('pathlib.Path("/data/hello.txt")');
  switch (pathVal.value) {
    case MontyPath(:final value):
      print('path object: $value');
    default:
      print('path: ${pathVal.value}');
  }

  session.dispose();
}

// ── OS call errors ────────────────────────────────────────────────────────────
// Throw OsCallException from the handler to raise a Python exception.
// pythonExceptionType lets you choose the Python exception class (default RuntimeError).
Future<void> _osCallError() async {
  print('\n── os call errors ──');

  final session = MontySession(
    osHandler: (op, args, kwargs) async {
      if (op == 'Path.read_text') {
        throw OsCallException(
          'Permission denied: ${args.first}',
          pythonExceptionType:
              'PermissionError', // becomes a Python PermissionError
        );
      }
      throw OsCallException('$op not supported');
    },
  );

  await session.run('import pathlib');
  final r = await session.run('''
try:
    pathlib.Path("/secret").read_text()
except PermissionError as e:
    result = f"caught: {e}"
''');
  print(r.printOutput ?? ''); // (empty — result is in variable)
  print(await session.run('result')); // MontyResult with MontyString
  session.dispose();
}
