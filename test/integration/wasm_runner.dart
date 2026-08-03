// Standalone fixture runner for headless-Chrome CI — the dart2js entry point.
//
// Compile with:
//   dart compile js test/integration/wasm_runner.dart \
//     -o test/integration/web/wasm_runner.dart.js
//
// That is what tool/test_wasm.sh, tool/test_cm_wasm.sh and CI
// (.github/workflows/ci.yaml:577) run.
//
// Output protocol:
//   FIXTURE_RESULT:{"name":"<file>","ok":<bool>}
//   FIXTURE_RESULT:{"name":"<file>","ok":false,"reason":"<msg>"}
//   FIXTURE_DONE:{"total":<n>,"passed":<n>,"failed":<n>,"skipped":<n>}
//
// The CI job greps for FIXTURE_RESULT / FIXTURE_DONE from Chrome stderr.
//
// ---------------------------------------------------------------------------
// There is deliberately almost nothing here.
//
// This file and its dart2wasm twin `wasm_runner_wasm.dart` used to be ~1200
// near-identical lines each. The corpus loop, the dispatch loop, the
// expectation evaluator, the name constants and a private ~400-line
// `_VirtualFs` were duplicated verbatim, and the copies had already drifted:
// two `switch` arms in opposite orders, a `"ms"` field on one side only, and
// a filesystem store built on the files-map + directories-set model this repo
// replaced with a real tree — so `memoryMountedOsHandler`'s Phase 1-3 fixes
// (IsADirectoryError on writes, iterdir's three answers, CPython rename)
// existed in the shipped handler and NOT in the thing the corpus ran.
//
// The whole body now lives in `package:monty_conformance`
// (src/fixture_runner.dart), which is also where the OS handler comes from, so
// the two backends cannot answer a fixture differently again. All that differs
// is how a line reaches the console: `print` here, a `dart:js_interop`
// `console.log` shim there.
// ---------------------------------------------------------------------------

// DCM: this is a compiled entry-point, not a test file.
// ignore_for_file: prefer-correct-test-file-name

import 'package:monty_conformance/monty_conformance.dart';

Future<void> main() => runFixtureCorpus(log: print);
