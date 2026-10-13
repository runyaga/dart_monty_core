// A program whose main starts the way a self-relaunching app's must: with
// runMontyWorkerIfChild. Spawned by self_relaunch_test.dart under the JIT,
// where the worker library is not bundled.
//
// When it returns, the probe prints whether this process may now relaunch
// itself, then `parent`.
//
// DCM: this is a spawned entry point, not a test.
// ignore_for_file: prefer-correct-test-file-name

import 'dart:io';

import 'package:dart_monty_core/src/worker/self_relaunch.dart';

void main(List<String> args) {
  runMontyWorkerIfChild(args);
  stdout
    ..writeln('available=${selfRelaunchAvailable()}')
    ..writeln('parent');
}
