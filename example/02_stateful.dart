// 02 — Stateful interpreter
//
// MontySession() keeps a live Rust REPL heap across run() calls —
// variables, functions, classes, and imports all persist without
// serialisation. For stateless single-shot evaluation see Monty(code) and
// Monty.exec.
//
// Covers: MontySession constructor, run, clearState, dispose, snapshot,
//         restore.
//
// Run: dart run example/02_stateful.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  // ── State persistence across calls ──────────────────────────────────────────
  final session = MontySession();

  await session.run('x = 10');
  await session.run('y = 20');
  final r = await session.run('x + y');
  print('x + y = ${r.value}'); // MontyInt(30)

  // Functions survive too.
  await session.run('def square(n): return n * n');
  final sq = await session.run('square(7)');
  print('square(7) = ${sq.value}'); // MontyInt(49)

  // ── inputs: per-call variable injection ────────────────────────────────────
  // Dart values are converted to Python literals and prepended as assignments.
  // They shadow globals for that call only — the heap is not permanently changed.
  final r2 = await session.run('square(n)', inputs: {'n': 5});
  print('square(5) = ${r2.value}'); // MontyInt(25)

  // Supported input types: null, bool, int, double, String, List, Map.
  await session.run(
    'total = sum(numbers)',
    inputs: {
      'numbers': [1, 2, 3, 4, 5],
    },
  );
  print('sum = ${(await session.run("total")).value}'); // MontyInt(15)

  // ── clearState ─────────────────────────────────────────────────────────────
  // Wipes globals. Next run() starts with an empty heap.
  session.clearState();
  final blank = await session.run('x');
  print('after clear — x error: ${blank.error?.excType}'); // NameError

  // ── snapshot / restore ─────────────────────────────────────────────────────
  // Capture the full heap as bytes, then restore it later.
  await session.run('counter = 0');
  await session.run('counter += 1');
  await session.run('counter += 1');
  print('counter before snap: ${(await session.run("counter")).value}'); // 2

  final snap = await session.snapshot();
  print('snapshot: ${snap.length} bytes');

  await session.run('counter += 100'); // mutate after snapshot
  print('mutated: ${(await session.run("counter")).value}'); // 102

  await session.restore(snap); // rewind
  print('restored: ${(await session.run("counter")).value}'); // 2

  // ── dispose ────────────────────────────────────────────────────────────────
  // Always dispose to free the native Rust handle.
  session.dispose();

  // ── Static one-shot helpers ─────────────────────────────────────────────────
  // Monty.exec — no state, no setup, dispose happens automatically.
  final quick = await Monty.exec('[i*i for i in range(5)]');
  print('list comp: ${quick.value}'); // MontyList
}
