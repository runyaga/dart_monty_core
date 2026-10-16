/// Defines test-only self-relaunch inputs.
library;

import 'package:dart_monty_core/src/worker/self_relaunch.dart';
import 'package:meta/meta.dart';

/// Test-only inputs for self-relaunch selection and diagnosis.
@immutable
class SelfRelaunchOptions {
  /// Creates test-only inputs for self-relaunch selection and diagnosis.
  const SelfRelaunchOptions({
    this.isAot = const bool.fromEnvironment('dart.vm.product'),
    this.diagnose,
  });

  /// Whether worker selection runs in an AOT executable.
  final bool isAot;

  /// Diagnoses why a self-relaunch cannot serve a worker.
  final SelfRelaunchStatus Function()? diagnose;
}
