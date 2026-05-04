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
// MontyCallback = Future<Object?> Function(List<Object?> args, Map<String, Object?>? kwargs)
//
// Positional args arrive in the args list.
// Keyword args arrive in the kwargs map.
Future<void> _externalFunctions() async {
  print('\n── externalFunctions ──');

  final repl = MontyRepl();

  await repl.feedRun(
    '''
result = add(3, 4)
greeting = greet(name="World")
''',
    externalFunctions: {
      // Positional args arrive in the args list.
      'add': (args, _) async => (args[0]! as int) + (args[1]! as int),

      // Keyword args land in the kwargs map.
      'greet': (_, kwargs) async => 'Hello, ${kwargs!['name']}!',
    },
  );

  print('add(3,4) = ${(await repl.feedRun("result")).value}'); // 7
  print('greet = ${(await repl.feedRun("greeting")).value}'); // Hello, World!

  // Return complex types: Dart List/Map are converted to Python list/dict.
  await repl.feedRun(
    'data = fetch_data()',
    externalFunctions: {
      'fetch_data': (_, _) async => {
        'name': 'alice',
        'scores': [98, 87, 92],
      },
    },
  );
  final data = await repl.feedRun('data["scores"]');
  print('scores: $data'); // MontyList

  repl.dispose();
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

  final repl = MontyRepl();

  // pathlib works across calls because state persists on the Rust REPL heap.
  // The osHandler is passed per feedRun call.
  await repl.feedRun('import pathlib', osHandler: osHandler);
  final content = await repl.feedRun(
    'pathlib.Path("/data/hello.txt").read_text()',
    osHandler: osHandler,
  );
  print('file content: ${content.value}');

  // Write then read back.
  await repl.feedRun(
    'pathlib.Path("/data/new.txt").write_text("written from Python")',
    osHandler: osHandler,
  );
  print('wrote to VFS: ${vfs["/data/new.txt"]}');

  // os.getenv
  final env = await repl.feedRun(
    'import os; os.getenv("APP_ENV")',
    osHandler: osHandler,
  );
  print('APP_ENV = ${env.value}');

  // MontyPath: Python Path objects round-trip as MontyPath values.
  final pathVal = await repl.feedRun(
    'pathlib.Path("/data/hello.txt")',
    osHandler: osHandler,
  );
  switch (pathVal.value) {
    case MontyPath(:final value):
      print('path object: $value');
    default:
      print('path: ${pathVal.value}');
  }

  repl.dispose();
}

// ── OS call errors ────────────────────────────────────────────────────────────
// Throw OsCallException from the handler to raise a Python exception.
// pythonExceptionType lets you choose the Python exception class (default RuntimeError).
Future<void> _osCallError() async {
  print('\n── os call errors ──');

  final repl = MontyRepl();
  OsCallHandler osHandler = (op, args, kwargs) async {
    if (op == 'Path.read_text') {
      throw OsCallException(
        'Permission denied: ${args.first}',
        pythonExceptionType:
            'PermissionError', // becomes a Python PermissionError
      );
    }
    throw OsCallException('$op not supported');
  };

  await repl.feedRun('import pathlib', osHandler: osHandler);
  final r = await repl.feedRun('''
try:
    pathlib.Path("/secret").read_text()
except PermissionError as e:
    result = f"caught: {e}"
''', osHandler: osHandler);
  print(r.printOutput ?? ''); // (empty — result is in variable)
  print(await repl.feedRun('result')); // MontyResult with MontyString
  repl.dispose();
}
