@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// In-memory VFS shared across tests
// ---------------------------------------------------------------------------

Map<String, String> _makeVfs() => {
  '/data/hello.txt': 'Hello from the virtual filesystem!',
  '/data/config.txt': 'version=1.0\nenv=test',
};

OsCallHandler _vfsHandler(Map<String, String> vfs) => (op, args, kwargs) async {
  switch (op) {
    case 'Path.read_text':
      return vfs[args.first! as String] ?? '';
    case 'Path.write_text':
      vfs[args[0]! as String] = args[1]! as String;
      return null;
    case 'Path.exists':
      return vfs.containsKey(args.first! as String);
    case 'Path.unlink':
      vfs.remove(args.first! as String);
      return null;
    default:
      throw OsCallException('$op not supported');
  }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('ffi_repl_oscall', () {
    // Regression: two separate feed() calls — import on first, read_text on
    // second. This was broken before the REPL_PROGRESS vtable fix because
    // readProgress() called monty_os_call_fn_name() (session API) on a
    // MontyReplHandle*, returning null → operationName '' → default case.
    test('pathlib.read_text works across two feed() calls', () async {
      final vfs = _makeVfs();
      final handler = _vfsHandler(vfs);
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      final importResult = await repl.feed(
        'import pathlib',
        osHandler: handler,
      );
      expect(
        importResult.error,
        isNull,
        reason: 'import pathlib should not error',
      );

      final readResult = await repl.feed(
        "pathlib.Path('/data/hello.txt').read_text()",
        osHandler: handler,
      );
      expect(readResult.error, isNull);
      expect(
        readResult.value,
        const MontyString('Hello from the virtual filesystem!'),
      );
    });

    test('one-line import + read_text works (control case)', () async {
      final vfs = _makeVfs();
      final handler = _vfsHandler(vfs);
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      final result = await repl.feed(
        "import pathlib; pathlib.Path('/data/hello.txt').read_text()",
        osHandler: handler,
      );
      expect(result.error, isNull);
      expect(
        result.value,
        const MontyString('Hello from the virtual filesystem!'),
      );
    });

    test(
      'pathlib module persists across feed() calls without osHandler on import',
      () async {
        final vfs = _makeVfs();
        final handler = _vfsHandler(vfs);
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        // Import without osHandler (fast path)
        await repl.feed('import pathlib');

        // Use pathlib with osHandler
        final result = await repl.feed(
          "pathlib.Path('/data/hello.txt').read_text()",
          osHandler: handler,
        );
        expect(result.error, isNull);
        expect(
          result.value,
          const MontyString('Hello from the virtual filesystem!'),
        );
      },
    );

    test('VFS write then read across separate feed() calls', () async {
      final vfs = _makeVfs();
      final handler = _vfsHandler(vfs);
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feed('import pathlib', osHandler: handler);

      await repl.feed(
        "pathlib.Path('/data/new.txt').write_text('written!')",
        osHandler: handler,
      );
      expect(vfs['/data/new.txt'], 'written!');

      final result = await repl.feed(
        "pathlib.Path('/data/new.txt').read_text()",
        osHandler: handler,
      );
      expect(result.value, const MontyString('written!'));
    });

    test('missing file returns empty string', () async {
      final vfs = _makeVfs();
      final handler = _vfsHandler(vfs);
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feed('import pathlib', osHandler: handler);

      final result = await repl.feed(
        "pathlib.Path('/data/missing.txt').read_text()",
        osHandler: handler,
      );
      expect(result.error, isNull);
      expect(result.value, const MontyString(''));
    });

    test('Path.exists returns correct bool', () async {
      final vfs = _makeVfs();
      final handler = _vfsHandler(vfs);
      final repl = MontyRepl();
      addTearDown(repl.dispose);

      await repl.feed('import pathlib', osHandler: handler);

      final exists = await repl.feed(
        "pathlib.Path('/data/hello.txt').exists()",
        osHandler: handler,
      );
      expect(exists.value, const MontyBool(true));

      final missing = await repl.feed(
        "pathlib.Path('/data/nope.txt').exists()",
        osHandler: handler,
      );
      expect(missing.value, const MontyBool(false));
    });

    test(
      'OsCallException becomes Python RuntimeError, REPL survives',
      () async {
        // Handler that throws OsCallException for every op — ensures the
        // exception-to-RuntimeError translation is exercised even for ops like
        // read_text that we know are real OS calls.
        Future<Object?> alwaysThrows(
          String op,
          List<Object?> args,
          Map<String, Object?>? kwargs,
        ) async => throw OsCallException('handler rejected: $op');
        final repl = MontyRepl();
        addTearDown(repl.dispose);

        await repl.feed('import pathlib', osHandler: alwaysThrows);

        // read_text is a real OS call → alwaysThrows → Python RuntimeError
        final result = await repl.feed(
          "try:\n  pathlib.Path('/x').read_text()\nexcept RuntimeError as e:\n  str(e)",
          osHandler: alwaysThrows,
        );
        expect(result.error, isNull); // Python caught it — no Dart exception
        // REPL survives; subsequent calls still work
        final ok = await repl.feed('1 + 1');
        expect(ok.value, const MontyInt(2));
      },
    );
  });
}
