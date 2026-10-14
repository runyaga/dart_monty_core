/// The upstream 1.1.0 corpus on the worker engine.
///
/// A separate library from `monty_conformance.dart` on purpose: it reaches the
/// pool session, which is internal to `dart_monty_core` until the cutover, and
/// the old engine's consumers (the web demo, the 0.0.23 corpus jobs) must not
/// take that dependency.
library;

export 'src/fixture_corpus_v1.dart';
export 'src/worker_corpus_manifest.dart';
export 'src/worker_fixture_host.dart';
export 'src/worker_fixture_runner.dart';
