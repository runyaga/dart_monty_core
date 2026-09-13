// Subprocess driver for quarantined REPL fixtures.
//
// Some corpus fixtures do not return a wrong answer — they KILL THE HOST
// PROCESS. Those cannot be asserted in-process: the death takes the whole suite
// with it and hundreds of results vanish behind one crash. (The same constraint
// is recorded in ffi_repl_corpus_test.dart's "a bare MontyRepl() is UNBOUNDED"
// note, which measured five such fixtures by exactly this method.)
//
// So the quarantine in `knownReplCrashFixtures` excludes them from the
// in-process loop, and the guard test re-runs each one HERE, in a child
// process, asserting it still dies with the recorded exit code. If a fixture is
// fixed upstream the child exits 0, the guard goes red, and the stale entry has
// to be deleted — which is the whole point.
//
// Usage:  dart run test/integration/repl_crash_probe.dart <fixture-key>
// Exits:  0        the fixture ran to completion (crash is GONE)
//         139 etc. killed by a signal — the crash is still present
//         64       usage / unknown key (a test-harness problem, not a verdict)
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/monty_conformance.dart';

Future<void> main(List<String> args) async {
  if (args.length != 1) {
    stderr.writeln('usage: repl_crash_probe.dart <fixture-key>');
    exit(64);
  }
  final key = args.single;
  final src = fixtureCorpus[key];
  if (src == null) {
    stderr.writeln('unknown fixture key: $key');
    exit(64);
  }

  // Bounded exactly like ffi_repl_corpus_test.dart's session. An UNBOUNDED
  // MontyRepl() is already known to kill the process on five other fixtures,
  // so probing unbounded would prove nothing about this one.
  final repl = MontyRepl(
    limits: const MontyLimits(memoryBytes: 256 * 1024 * 1024, stackDepth: 1000),
  );
  try {
    await repl.feedRun(src);
  } on Object catch (e) {
    // A thrown Dart error is NOT the crash being pinned. Exit 0 so the guard
    // reports "stopped crashing" rather than mistaking an exception for a
    // signal death.
    stderr.writeln('fixture threw (not a crash): $e');
  } finally {
    await repl.dispose();
  }
  exit(0);
}
