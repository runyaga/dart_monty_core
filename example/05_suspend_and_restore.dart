// Examples print what they show; the number in the name is the reading order.
// ignore_for_file: avoid_print, file_names
//
// 05 — Suspending a feed and resuming it elsewhere
//
// A feed suspended on a host call can be dumped as bytes and resumed later,
// in another session, another worker or another process: loadSnapshot
// restores the dump into a fresh session and returns the same suspension,
// ready for its answer. A long-running workflow can park on a slow host call
// this way without holding a worker.
//
// Covers: feedStart, FunctionSnapshot.dump, MontySession.dump while
//         suspended, loadSnapshot, resume.
//
// Run: dart run example/05_suspend_and_restore.dart

import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';

const _workflow = '''
total = 0
for item in ["a", "bb", "ccc"]:
    total += approve(item)
total
''';

Future<void> main() async {
  await Monty.withPool((monty) async {
    // ── Start a workflow and park it on its first host call ─────────────────
    final parked = await monty.withSession<Uint8List>((session) async {
      final first = await session.feedStart(_workflow) as FunctionSnapshot;
      print('suspended on ${first.functionName}${first.args}');
      _check(first.args.single == const MontyString('a'), 'first call');

      final bytes = await first.dump();
      print('parked: ${bytes.length} bytes');
      // The session closes here; the suspension lives on in `bytes`.
      return bytes;
    });

    // ── Resume it in a new session ──────────────────────────────────────────
    final total = await monty.withSession((session) async {
      var snapshot = await session.loadSnapshot(parked);
      while (snapshot is FunctionSnapshot) {
        final call = snapshot;
        final item = (call.args.single as MontyString).value;
        print('approve($item) -> ${item.length}');
        snapshot = await call.resume(
          ExternalReturnValue(MontyInt(item.length)),
        );
      }

      return (snapshot as MontyComplete).output;
    });
    print('total: $total');
    _check(total == const MontyInt(6), 'total');

    // ── Dump the session itself while it waits ─────────────────────────────
    await monty.withSession((session) async {
      final waiting = await session.feedStart(_workflow) as FunctionSnapshot;
      final whole = await session.dump();
      // Answer here...
      final ahead = await waiting.resume(
        const ExternalReturnValue(MontyInt(100)),
      );
      _check(ahead is FunctionSnapshot, 'second call');

      // ...and restore the same moment elsewhere, answering differently.
      final replay = await monty.withSession((other) async {
        var snapshot = await other.loadSnapshot(whole);
        while (snapshot is FunctionSnapshot) {
          snapshot = await snapshot.resume(
            const ExternalReturnValue(MontyInt(1)),
          );
        }

        return (snapshot as MontyComplete).output;
      });
      print('replayed with other answers: $replay');
      _check(replay == const MontyInt(3), 'replay');
    });
  }, maxProcesses: 3);
}

void _check(bool ok, String what) {
  if (!ok) throw StateError('unexpected result: $what');
}
