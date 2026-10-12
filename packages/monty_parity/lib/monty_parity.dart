/// Parity runner for dart_monty_core against upstream pydantic-monty.
///
/// Cases and the scorer live in tool/parity; this package is the Dart half:
/// it runs a case through core's public API and returns the outcome.
library;

export 'src/api_probes.dart' show runProbes;
export 'src/canon.dart';
export 'src/case_runner.dart' show runCase, runOneShot;
