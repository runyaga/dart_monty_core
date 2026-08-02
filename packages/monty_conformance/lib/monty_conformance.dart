/// monty's own conformance corpus, and the parser for its directives.
///
/// This is a **path-dependency package, not a published one.** It exists for a
/// single reason: Dart only lets one package import another package's `lib/`,
/// never its `test/`. The corpus and parser were under
/// `dart_monty_core/test/integration/`, which made them unreachable from
/// `packages/dart_monty_web` — and the alternative, generating a second copy
/// into the demo, is exactly the duplication that let the two drive loops
/// diverge earlier in this project.
///
/// So there is ONE copy, here, and everything that needs it depends on it:
/// core's oracle and WASM fixture harnesses, and the web demo's conformance
/// panel.
///
/// It is deliberately dependency-free — no `test`, no `dart:io` — so it can be
/// compiled for the browser.
library;

export 'src/fixture_corpus.dart';
export 'src/fixture_dispatch.dart';
export 'src/fixture_externals.dart';
export 'src/fixture_failure.dart';
export 'src/fixture_os_handler.dart';
export 'src/fixture_parser.dart';
export 'src/unsupported_wasm_fixtures.dart';
