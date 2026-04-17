// 02 — Stateful interpreter
//
// Monty() keeps a live Rust REPL heap across run() calls — variables,
// functions, classes, and imports all persist without serialisation.
//
// Covers: Monty constructor, run, clearState, dispose, snapshot, restore.
//
// Run: dart run example/02_stateful.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  // ── State persistence across calls ──────────────────────────────────────────
  final monty = Monty();

  await monty.run('x = 10');
  await monty.run('y = 20');
  final r = await monty.run('x + y');
  print('x + y = ${r.value}'); // MontyInt(30)

  // Functions survive too.
  await monty.run('def square(n): return n * n');
  final sq = await monty.run('square(7)');
  print('square(7) = ${sq.value}'); // MontyInt(49)

  // ── inputs: per-call variable injection ────────────────────────────────────
  // Dart values are converted to Python literals and prepended as assignments.
  // They shadow globals for that call only — the heap is not permanently changed.
  final r2 = await monty.run(
    'square(n)',
    inputs: {'n': 5},
  );
  print('square(5) = ${r2.value}'); // MontyInt(25)

  // Supported input types: null, bool, int, double, String, List, Map.
  await monty.run(
    'total = sum(numbers)',
    inputs: {'numbers': [1, 2, 3, 4, 5]},
  );
  print('sum = ${(await monty.run("total")).value}'); // MontyInt(15)

  // ── clearState ─────────────────────────────────────────────────────────────
  // Wipes globals. Next run() starts with an empty heap.
  monty.clearState();
  final blank = await monty.run('x');
  print('after clear — x error: ${blank.error?.excType}'); // NameError

  // ── snapshot / restore ─────────────────────────────────────────────────────
  // Capture the full heap as bytes, then restore it later.
  await monty.run('counter = 0');
  await monty.run('counter += 1');
  await monty.run('counter += 1');
  print('counter before snap: ${(await monty.run("counter")).value}'); // 2

  final snap = await monty.snapshot();
  print('snapshot: ${snap.length} bytes');

  await monty.run('counter += 100'); // mutate after snapshot
  print('mutated: ${(await monty.run("counter")).value}'); // 102

  await monty.restore(snap); // rewind
  print('restored: ${(await monty.run("counter")).value}'); // 2

  // ── dispose ────────────────────────────────────────────────────────────────
  // Always dispose to free the native Rust handle.
  monty.dispose();

  // ── Static one-shot helpers ─────────────────────────────────────────────────
  // Monty.exec — no state, no setup, dispose happens automatically.
  final quick = await Monty.exec('[i*i for i in range(5)]');
  print('list comp: ${quick.value}'); // MontyList
}
