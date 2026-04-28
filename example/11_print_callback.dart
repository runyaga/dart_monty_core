// 11 — printCallback
//
// Python's `print()` output is normally surfaced via `MontyResult.printOutput`
// after execution finishes. The `printCallback` parameter delivers the same
// output to a Dart callback before run/feedRun returns — useful for piping
// to a logger, UI buffer, or stream.
//
// printCallback is a *batch* callback: it fires once per call with the
// entire captured stdout text. Per-flush streaming requires Rust + WASM
// Worker postMessage extensions and is a separate item.
//
// Covers: printCallback on Monty.exec, Monty(code).run, MontyRepl.feedRun;
//         the stream argument is always 'stdout'.
//
// Run: dart run example/11_print_callback.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await _oneShot();
  await _replPerFeed();
  await _piping();
}

// ── Monty.exec / Monty(code).run ─────────────────────────────────────────────
// The callback fires once with the entire stdout buffer. `stream` is always
// 'stdout' for now (matches Python's Literal['stdout']).
Future<void> _oneShot() async {
  print('\n── one-shot exec ──');

  await Monty.exec(
    'print("hello")\nprint("from python")',
    printCallback: (stream, text) {
      print('[$stream] ${text.trimRight()}');
    },
  );
}

// ── MontyRepl.feedRun ────────────────────────────────────────────────────────
// On a stateful REPL the callback fires per feedRun call, not per print.
// The captured text is the full stdout buffer for that feed.
Future<void> _replPerFeed() async {
  print('\n── stateful repl ──');

  final repl = MontyRepl();
  try {
    await repl.feedRun(
      'print("first feed line 1")\nprint("first feed line 2")',
      printCallback: (stream, text) => print('[feed 1] ${text.trimRight()}'),
    );

    await repl.feedRun(
      'print("second feed")',
      printCallback: (stream, text) => print('[feed 2] ${text.trimRight()}'),
    );

    // Calls without printCallback still populate MontyResult.printOutput.
    final r = await repl.feedRun('print("third feed (read from result)")');
    print('[result.printOutput] ${r.printOutput?.trimRight()}');
  } finally {
    await repl.dispose();
  }
}

// ── Common idiom: pipe Python prints to a Dart logger or buffer ──────────────
// The callback closes over Dart-side state, so accumulating into a list,
// forwarding to a Logger, or pushing to a StreamController is direct.
Future<void> _piping() async {
  print('\n── piping ──');

  final lines = <String>[];

  void capture(String stream, String text) {
    for (final line in text.split('\n')) {
      if (line.isNotEmpty) lines.add(line);
    }
  }

  await Monty(
    'for i in range(3):\n'
    '    print(f"line {i}")',
  ).run(printCallback: capture);

  print('captured ${lines.length} lines:');
  for (final line in lines) {
    print('  - $line');
  }
}
