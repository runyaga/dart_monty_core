// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 02 — Stateful sessions
//
// A MontySession keeps its interpreter between feeds: variables, functions,
// classes and imports persist. Sessions share nothing with each other, and
// dump() captures one as bytes that loadSession() restores into a fresh
// session, in the same pool or another.
//
// Covers: Monty.start, checkout, feedRun, inputs, dump, loadSession,
//         session isolation, close.
//
// Run: dart run example/02_stateful.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  final monty = await Monty.start(maxProcesses: 2);
  try {
    final session = await monty.checkout();
    try {
      // ── State persists across feeds ───────────────────────────────────────
      await session.feedRun('x = 10');
      await session.feedRun('y = 20');
      final r = await session.feedRun('x + y');
      print('x + y = $r');
      _check(r == const MontyInt(30), 'x + y');

      await session.feedRun('def square(n): return n * n');
      final sq = await session.feedRun('square(7)');
      print('square(7) = $sq');
      _check(sq == const MontyInt(49), 'square(7)');

      // ── Inputs are bound as globals ───────────────────────────────────────
      await session.feedRun(
        'total = sum(numbers)',
        inputs: {
          'numbers': MontyValue.fromDart([1, 2, 3, 4, 5]),
        },
      );
      final total = await session.feedRun('total');
      print('sum = $total');
      _check(total == const MontyInt(15), 'total');

      // ── dump / loadSession ────────────────────────────────────────────────
      await session.feedRun('counter = 2');
      final saved = await session.dump();
      print('dump: ${saved.length} bytes');

      await session.feedRun('counter += 100'); // changes this session only
      final mutated = await session.feedRun('counter');
      print('mutated: $mutated');
      _check(mutated == const MontyInt(102), 'mutated');

      // Restore into a fresh session: it starts where the dump was taken.
      final restored = await monty.checkout();
      try {
        await restored.loadSession(saved);
        final counter = await restored.feedRun('counter');
        print('restored: $counter');
        _check(counter == const MontyInt(2), 'restored counter');
        _check(
          await restored.feedRun('square(3)') == const MontyInt(9),
          'restored function',
        );
      } finally {
        await restored.close();
      }
    } finally {
      await session.close();
    }

    // ── Sessions are isolated ───────────────────────────────────────────────
    final other = await monty.withSession(
      (s) => s.feedRun('''
try:
    x
    seen = True
except NameError:
    seen = False
seen
'''),
    );
    print('a new session sees x: $other');
    _check(other == const MontyBool(false), 'isolation');
  } finally {
    await monty.close();
  }
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}
