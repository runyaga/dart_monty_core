import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/monty_conformance.dart';

Future<void> main() async {
  const key = 'args__dict_get_no_args.py';
  final src = fixtureCorpus[key]!;

  for (var i = 0; i < 20; i++) {
    stdout.writeln('iter $i');
    final repl = MontyRepl(
      limits: const MontyLimits(
        memoryBytes: 256 * 1024 * 1024,
        stackDepth: 1000,
      ),
    );
    try {
      await repl.feedRun(src);
    } finally {
      await repl.dispose();
    }
  }
}
