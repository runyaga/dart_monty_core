// 05 — MontyRepl: lowest-level API
//
// MontyRepl wraps a single Rust REPL handle. All state (variables, imports,
// functions, dataclasses) persists on that handle across feed() calls.
//
// Key differences from Monty/MontySession:
//  - feed() auto-dispatches externals (convenient)
//  - feedStart()/resume() lets YOU drive the loop (flexible)
//  - detectContinuation() tells you if input is syntactically complete
//  - snapshot()/restore() at the REPL level
//  - Multiple independent MontyRepl instances share NO state
//
// Covers: MontyRepl, feed, feedStart, resume, resumeWithError,
//         detectContinuation, ReplContinuationMode, snapshot, restore,
//         dispose, preamble, multi-REPL isolation.
//
// Run: dart run example/05_repl.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await _basicFeed();
  await _continuationDetection();
  await _manualFeedLoop();
  await _snapshotRestore();
  await _multiReplIsolation();
  await _preamble();
}

// ── feed(): auto-dispatch ─────────────────────────────────────────────────────
Future<void> _basicFeed() async {
  print('\n── basic feed ──');
  final repl = MontyRepl();

  // State persists: x survives across calls.
  await repl.feed('x = 42');
  final r = await repl.feed('x + 1');
  print('x + 1 = ${r.value}'); // MontyInt(43)

  // Externals auto-dispatched — no manual loop needed.
  await repl.feed(
    'result = double(x)',
    externals: {'double': (args) async => (args['_0'] as int) * 2},
  );
  print('double(42) = ${(await repl.feed("result")).value}'); // 84

  // inputs inject variables for that call only.
  final r3 = await repl.feed('y * 3', inputs: {'y': 7});
  print('7*3 = ${r3.value}'); // 21

  // Print output is captured in printOutput.
  final r4 = await repl.feed('print("from python")');
  print('captured: "${r4.printOutput?.trim()}"');

  await repl.dispose();
}

// ── detectContinuation(): REPL prompt logic ──────────────────────────────────
// Returns complete, incompleteImplicit, or incompleteBlock.
// Use this to show '>>>' vs '...' in a REPL UI.
Future<void> _continuationDetection() async {
  print('\n── continuation detection ──');
  final repl = MontyRepl();

  final cases = [
    '1 + 1',           // complete
    'def f(',          // incompleteImplicit (open paren)
    'if True:',        // incompleteBlock    (open block)
    'x = {',          // incompleteImplicit (open brace)
    '"hello"',         // complete
  ];

  for (final code in cases) {
    final mode = await repl.detectContinuation(code);
    final prompt = switch (mode) {
      ReplContinuationMode.complete => '>>> ',
      ReplContinuationMode.incompleteImplicit => '... ',
      ReplContinuationMode.incompleteBlock => '... ',
    };
    print('$prompt$code  ($mode)');
  }

  await repl.dispose();
}

// ── feedStart/resume: manual loop ────────────────────────────────────────────
// feedStart() returns immediately when Python hits a registered external.
// You call resume() with the result, then loop until MontyComplete.
Future<void> _manualFeedLoop() async {
  print('\n── manual feed loop ──');
  final repl = MontyRepl();

  var progress = await repl.feedStart(
    'total = fetch(1) + fetch(2) + fetch(3)',
    externalFunctions: ['fetch'],
  );

  var step = 0;
  while (true) {
    switch (progress) {
      case MontyComplete(:final result):
        print('total: ${result.value}');
        await repl.dispose();
        return;

      case MontyPending(:final functionName, :final arguments):
        step++;
        final n = arguments.first.dartValue as int;
        print('  step $step: $functionName($n) → ${n * 10}');
        progress = await repl.resume(n * 10); // return value

      case MontyOsCall():
        progress = await repl.resumeWithError('os not supported');

      default:
        progress = await repl.resume(null);
    }
  }
}

// ── snapshot / restore at REPL level ─────────────────────────────────────────
Future<void> _snapshotRestore() async {
  print('\n── snapshot/restore ──');
  final repl = MontyRepl();

  await repl.feed('import pathlib');
  await repl.feed('items = [1, 2, 3]');
  await repl.feed('items.append(4)');
  print('before snap: ${(await repl.feed("items")).value}');

  final bytes = await repl.snapshot();
  print('snapshot: ${bytes.length} bytes');

  await repl.feed('items.append(999)'); // mutate
  print('after mutate: ${(await repl.feed("items")).value}');

  await repl.restore(bytes); // rewind to snapshot point
  print('after restore: ${(await repl.feed("items")).value}');

  await repl.dispose();
}

// ── multi-REPL isolation ─────────────────────────────────────────────────────
// Each MontyRepl has its own Rust handle — variables in A are invisible in B.
Future<void> _multiReplIsolation() async {
  print('\n── multi-REPL isolation ──');
  final replA = MontyRepl();
  final replB = MontyRepl();

  await replA.feed('x = "from A"');
  await replB.feed('x = "from B"');

  print('A: ${(await replA.feed("x")).value}'); // from A
  print('B: ${(await replB.feed("x")).value}'); // from B — fully independent

  await replA.dispose();
  await replB.dispose();
}

// ── preamble ─────────────────────────────────────────────────────────────────
// Code fed into the REPL before any user calls — useful for setup, imports.
Future<void> _preamble() async {
  print('\n── preamble ──');
  final repl = MontyRepl(
    preamble: 'PI = 3.14159\ndef circle_area(r): return PI * r * r',
  );

  // preamble functions are available immediately.
  final r = await repl.feed('circle_area(5)');
  print('circle_area(5) = ${r.value}');

  await repl.dispose();
}
