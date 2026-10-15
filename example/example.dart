// Examples print what they show.
// ignore_for_file: avoid_print
//
// dart_monty_core — featured example
//
// Covers the five main usage patterns:
//
//  1. Pool and session — Monty.withPool, Monty.withSession, feedRun
//  2. Inputs           — feed one result into the next as a Python variable
//  3. Externals        — Dart functions Python calls, sync and async
//  4. State            — globals, functions and imports persist in a session
//  5. VFS              — sandboxed in-memory filesystem via Python pathlib
//
// Run: dart run example/example.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main(List<String> args) async {
  // In an AOT executable (`dart build cli`) the worker can be this very
  // program, relaunched; this call serves as that worker when it is one.
  // Under `dart run` it returns at once.
  runMontyWorkerIfChild(args);

  // A pool of worker processes. Each session holds one worker for itself.
  await Monty.withPool((monty) async {
    await monty.withSession((session) async {
      // ── 1. Run code ───────────────────────────────────────────────────────
      final pow = await session.feedRun('2 ** 10');
      print('2**10 = ${pow.dartValue}');
      _check(pow == const MontyInt(1024), '2 ** 10');

      // ── 2. Inputs: chain programs ─────────────────────────────────────────
      // A value from one run becomes a Python variable in the next.
      final squares = await session.feedRun('[x**2 for x in range(10)]');
      final total = await session.feedRun(
        'sum(squares)',
        inputs: {'squares': squares},
      );
      print('sum of squares 0-9 = ${total.dartValue}');
      _check(total == const MontyInt(285), 'sum(squares)');

      // ── 3. Externals ──────────────────────────────────────────────────────
      // A call to a name in `externalLookup` runs the Dart function. A returned
      // Future is awaited, and its value is the call's result.
      final shout = await session.feedRun(
        'shout(msg)',
        inputs: {'msg': const MontyString('hello')},
        externalLookup: {
          'shout': MontyHostFunction(
            'shout',
            (args, _) =>
                MontyString((args[0] as MontyString).value.toUpperCase()),
          ),
        },
      );
      print(shout.dartValue);
      _check(shout == const MontyString('HELLO'), 'shout');

      final fetched = await session.feedRun(
        'fetch(1) + fetch(2)',
        externalLookup: {
          'fetch': MontyHostFunction('fetch', (args, _) async {
            await Future<void>.delayed(const Duration(milliseconds: 1));

            return MontyInt((args[0] as MontyInt).value * 10);
          }),
        },
      );
      print('fetch(1) + fetch(2) = ${fetched.dartValue}');
      _check(fetched == const MontyInt(30), 'fetch');

      // ── 4. State persists across feeds ────────────────────────────────────
      await session.feedRun(
        'def fib(n): return n if n < 2 else fib(n-1) + fib(n-2)',
      );
      await session.feedRun('result = fib(10)');
      final fib = await session.feedRun('result');
      print('fib(10) = ${fib.dartValue}');
      _check(fib == const MontyInt(55), 'fib(10)');

      // ── 5. VFS: sandboxed in-memory filesystem ────────────────────────────
      // Writes update the very objects passed in, so Dart reads the result
      // with no serialisation.
      final input = MontyMemoryFile('/data/input.txt', 'hello from Dart');
      final output = MontyMemoryFile('/data/output.txt', '');
      final handler = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/data')],
        files: [input, output],
      );
      await session.feedRun('''
from pathlib import Path
text = Path("/data/input.txt").read_text()
Path("/data/output.txt").write_text(text.upper())
''', os: handler);
      print(output.content.text);
      _check(output.content.text == 'HELLO FROM DART', 'VFS write');
    });
  });
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}
