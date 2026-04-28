// 02 — Stateful interpreter
//
// MontyRepl() keeps a live Rust REPL heap across run() calls —
// variables, functions, classes, and imports all persist without
// serialisation. For stateless single-shot evaluation see Monty(code) and
// Monty.exec.
//
// Covers: MontyRepl constructor, run, clearState, dispose, snapshot,
//         restore.
//
// Run: dart run example/02_stateful.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  // ── State persistence across calls ──────────────────────────────────────────
  final repl = MontyRepl();

  await repl.feedRun('x = 10');
  await repl.feedRun('y = 20');
  final r = await repl.feedRun('x + y');
  print('x + y = ${r.value}'); // MontyInt(30)

  // Functions survive too.
  await repl.feedRun('def square(n): return n * n');
  final sq = await repl.feedRun('square(7)');
  print('square(7) = ${sq.value}'); // MontyInt(49)

  // ── inputs: per-call variable injection ────────────────────────────────────
  // Dart values are converted to Python literals and prepended as assignments.
  // They shadow globals for that call only — the heap is not permanently changed.
  final r2 = await repl.feedRun('square(n)', inputs: {'n': 5});
  print('square(5) = ${r2.value}'); // MontyInt(25)

  // Supported input types: null, bool, int, double, String, List, Map.
  await repl.feedRun(
    'total = sum(numbers)',
    inputs: {
      'numbers': [1, 2, 3, 4, 5],
    },
  );
  print('sum = ${(await repl.feedRun("total")).value}'); // MontyInt(15)

  // ── clearState ─────────────────────────────────────────────────────────────
  // Wipes globals. Next feedRun() starts with an empty heap. Looking
  // up a previously-defined name raises Python NameError, which lands
  // in MontyResult.error rather than throwing.
  await repl.clearState();
  final blank = await repl.feedRun('x');
  print('after clear — x error: ${blank.error?.excType}'); // NameError

  // ── snapshot / restore ─────────────────────────────────────────────────────
  // Capture the full heap as bytes, then restore it later.
  await repl.feedRun('counter = 0');
  await repl.feedRun('counter += 1');
  await repl.feedRun('counter += 1');
  print('counter before snap: ${(await repl.feedRun("counter")).value}'); // 2

  final snap = await repl.snapshot();
  print('snapshot: ${snap.length} bytes');

  await repl.feedRun('counter += 100'); // mutate after snapshot
  print('mutated: ${(await repl.feedRun("counter")).value}'); // 102

  await repl.restore(snap); // rewind
  print('restored: ${(await repl.feedRun("counter")).value}'); // 2

  // ── dispose ────────────────────────────────────────────────────────────────
  // Always dispose to free the native Rust handle.
  repl.dispose();

  // ── Static one-shot helpers ─────────────────────────────────────────────────
  // Monty.exec — no state, no setup, dispose happens automatically.
  final quick = await Monty.exec('[i*i for i in range(5)]');
  print('list comp: ${quick.value}'); // MontyList
}
