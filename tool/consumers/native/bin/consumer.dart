import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  try {
    final result = await Monty.withPool(
      (monty) => monty.withSession((session) => session.feedRun('1 + 1')),
    );
    if (result != const MontyInt(2)) {
      stderr.writeln('unexpected result: $result');
      exitCode = 1;

      return;
    }
    stdout.writeln('result=2');
  } on Object catch (error, stackTrace) {
    stderr
      ..writeln('consumer failed: $error')
      ..writeln(stackTrace);
    exitCode = 1;
  }
}
