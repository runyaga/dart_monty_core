// Fresh-process absence checks: another test isolate may have loaded dmfs.
// This is a subprocess entry point, not a test suite.
// ignore_for_file: prefer-correct-test-file-name
import 'dart:io';

import 'package:dart_monty_core/src/worker/monty_error.dart';
import 'package:dart_monty_core/src/worker/self_relaunch.dart';
import 'package:dart_monty_core/src/worker/worker_locator.dart';

Future<void> main() async {
  final before = selfRelaunchAvailable();
  stdout.writeln('before=$before');
  runMontyWorkerIfChild(const ['--other']);
  final after = selfRelaunchAvailable();
  stdout.writeln('after=$after');
  try {
    final launch = await locateWorker(
      selfRelaunch: const SelfRelaunchOptions(isAot: true),
    );
    throw StateError('unbundled process offered $launch');
  } on MontyCrashedError catch (error) {
    if (error.cause != CrashCause.spawn) rethrow;
    stdout.writeln('locator=spawn failure');
  }
}
