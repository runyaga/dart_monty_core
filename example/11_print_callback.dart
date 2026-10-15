// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 11 — Printed output: printCallback and the collectors
//
// What the sandbox prints goes to the process's stdout and stderr by
// default. A feed's printCallback receives it instead, as (stream, text)
// fragments in order, while the feed runs: pipe it to a logger, a UI
// buffer or a stream.
//
// CollectString and CollectStreams are ready-made callbacks that keep the
// output under a byte cap: one string, or the (stream, text) records.
//
// Covers: printCallback, CollectString, CollectStreams, maxBytes.
//
// Run: dart run example/11_print_callback.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await Monty.withPool(
    (monty) => monty.withSession((session) async {
      // ── Default: straight to this process's stdout ────────────────────────
      print('\n── default ──');
      await session.feedRun('print("printed by Python")');

      // ── A callback ────────────────────────────────────────────────────────
      print('\n── printCallback ──');
      // A fragment may hold several lines: the worker batches printed text.
      final fragments = <(String, String)>[];
      await session.feedRun('''
import sys
for i in range(3):
    print("line", i)
print("oops", file=sys.stderr)
''', printCallback: (stream, text) => fragments.add((stream, text)));
      for (final (stream, text) in fragments) {
        print('  $stream: ${text.trimRight().replaceAll('\n', r'\n')}');
      }
      _check(
        fragments.map((f) => f.$2).join().contains('line 2'),
        'stdout fragments',
      );
      _check(fragments.any((f) => f.$1 == 'stderr'), 'stderr fragment');

      // ── CollectString ─────────────────────────────────────────────────────
      print('\n── CollectString ──');
      final text = CollectString();
      await session.feedRun(
        'print("hello"); print("world")',
        printCallback: text.call,
      );
      print(text);
      _check(text.output == 'hello\nworld\n', 'CollectString');

      // ── CollectStreams ────────────────────────────────────────────────────
      print('\n── CollectStreams ──');
      final streams = CollectStreams();
      await session.feedRun(
        'print("out"); print("err", file=sys.stderr)',
        printCallback: streams.call,
      );
      for (final (stream, text) in streams.output) {
        print('  $stream: ${text.trimRight()}');
      }
      _check(streams.output.length >= 2, 'CollectStreams');

      // ── A cap ends the feed with MemoryError ──────────────────────────────
      print('\n── maxBytes ──');
      final capped = CollectString(maxBytes: 64);
      try {
        await session.feedRun(
          'for i in range(100):\n    print("x" * 10)',
          printCallback: capped.call,
        );
        throw StateError('the cap was not enforced');
      } on MontyRuntimeError catch (e) {
        print('raised: $e');
        print('kept ${capped.output.length} characters');
        _check(e.exception.excType == 'MemoryError', 'cap');
      }
    }),
  );
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}
