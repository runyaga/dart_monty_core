// ignore_for_file: avoid_print
//
// dart_monty_core — featured example
//
// Covers the four main usage patterns:
//
//  1. One-shot  — Monty.exec / Monty.run
//  2. Inputs    — chain programs: feed one result into the next as a Python variable
//  3. Externals — sync and async Dart callbacks from Python
//  4. REPL      — stateful interpreter with persistent variables
//
// Run: dart run example/example.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  // ── 1. One-shot ─────────────────────────────────────────────────────────────
  final r = await Monty.exec('2 ** 10');
  print('2**10 = ${r.value.dartValue}'); // 1024

  // ── 2. Inputs — chaining programs ───────────────────────────────────────────
  // Run a data program, then feed its result into a second program.
  // The Dart value returned by the first run becomes a named Python variable
  // in the next — no serialisation boilerplate required.
  final squares = await Monty('[x**2 for x in range(10)]').run();

  final total = await Monty('sum(squares)').run(
    inputs: {'squares': squares.value.dartValue},
  );
  print('sum of squares 0–9² = ${total.value.dartValue}'); // 285

  // ── 3. Externals ────────────────────────────────────────────────────────────
  // externalFunctions: Python calls Dart synchronously.
  final sync = await Monty('shout(msg)').run(
    inputs: {'msg': 'hello'},
    externalFunctions: {
      'shout': (args, _) async => (args[0] as String).toUpperCase(),
    },
  );
  print(sync.value.dartValue); // HELLO

  // externalAsyncFunctions: Python can `await` the Dart callback directly.
  // asyncio.gather over multiple calls runs them concurrently in Dart.
  final async_ = await Monty('''
import asyncio
a, b = await asyncio.gather(fetch(1), fetch(2))
a + b
''').run(
    externalAsyncFunctions: {
      'fetch': (args, _) async => (args[0] as int) * 10,
    },
  );
  print(async_.value.dartValue); // 30  (10 + 20)

  // ── 4. Stateful REPL ────────────────────────────────────────────────────────
  // Variables, functions, and imports persist across feedRun calls.
  final repl = MontyRepl();
  await repl.feedRun('def fib(n): return n if n < 2 else fib(n-1) + fib(n-2)');
  await repl.feedRun('result = fib(10)');
  final fib = await repl.feedRun('result');
  print('fib(10) = ${fib.value.dartValue}'); // 55
  await repl.dispose();
}
