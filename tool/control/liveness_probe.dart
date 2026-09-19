// E4 liveness probe — the core#156 reproducer, run as its OWN PROCESS.
//
// This file is meant to be launched by tool/control/watchdog.sh, never by the
// test suite. That is the whole point: a script that calls an external
// function in a loop has no suspension budget on this backend, so an in-suite
// probe would hang the run instead of reporting. Only an external process
// holder can turn "never terminates" into an observation.
//
// It prints progress so a kill leaves evidence of how far it got, and aborts
// itself at a ceiling so that a RUN THAT ENDS tells you the limit fired rather
// than that the probe ran out of patience.
import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';

/// High enough that a working limit fires long before it, low enough that the
/// probe cannot run for ever if the watchdog itself fails.
/// Deliberately far past anything a working limit would allow. With the
/// watchdog holding the clock, the probe SHOULD be killed rather than reach
/// this -- the ceiling exists only so a failed watchdog cannot leave a process
/// running for ever. Measured at 500ms timeoutMs: ~327k suspensions/sec, so
/// 5M is ~15s of unbounded running.
const _ceiling = 5000000;

Future<void> main(List<String> args) async {
  final timeoutMs = int.parse(args.isEmpty ? '500' : args[0]);
  final sw = Stopwatch()..start();
  var calls = 0;

  final repl = MontyRepl(limits: MontyLimits(timeoutMs: timeoutMs));
  try {
    final r = await repl.feedRun(
      'while True:\n    ping()',
      externalFunctions: {
        'ping': (args, kwargs) async {
          calls++;
          if (calls % 5000 == 0) {
            // STDERR, AND FLUSHED. Progress on buffered stdout is lost when
            // the watchdog SIGKILLs the process -- which is exactly the run
            // whose progress matters most. Measured: the first version
            // reported calls=0 on a kill that had in fact made hundreds of
            // thousands of calls.
            stderr.writeln('PROGRESS:$calls:${sw.elapsedMilliseconds}');
          }
          if (calls >= _ceiling) {
            // The probe gives up. This is NOT the limit working.
            throw StateError('probe ceiling $_ceiling reached');
          }
          return null;
        },
      },
    );
    stdout.writeln(
      'DONE:selfterminated:$calls:${sw.elapsedMilliseconds}:'
      'isError=${r.isError}:${r.error}',
    );
  } on Object catch (e) {
    stdout.writeln(
      'DONE:threw:$calls:${sw.elapsedMilliseconds}:${e.runtimeType}: $e',
    );
  } finally {
    await repl.dispose();
  }
}
