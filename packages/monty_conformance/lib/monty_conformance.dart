/// The strict adjudicator for upstream's fixture directives, the directive
/// parser, and the host tables `# call-external` fixtures expect.
///
/// This is a **path-dependency package, not a published one.** It exists
/// because Dart lets one package import another package's `lib/`, never its
/// `test/`: core's corpus tests and the web demo's conformance panel share one
/// copy of the parser and the adjudicator here.
///
/// It is deliberately dependency-light (no `test`, no `dart:io`) so it can be
/// compiled for the browser. The corpus itself and its runner are in
/// `worker_conformance.dart`.
library;

export 'src/fixture_adjudicator.dart';
export 'src/fixture_externals.dart';
export 'src/fixture_failure.dart';
export 'src/fixture_os_handler.dart';
export 'src/fixture_parser.dart';
