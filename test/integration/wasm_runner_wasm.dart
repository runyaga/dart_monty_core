// Standalone fixture runner for headless-Chrome CI — the dart2wasm entry point,
// twin of wasm_runner.dart.
//
// Compile with (this file, and dart2wasm — the header was once a copy of its
// dart2js sibling's and named the wrong file AND the wrong compiler, which is
// the sort of instruction that only fails for whoever follows it):
//   dart compile wasm test/integration/wasm_runner_wasm.dart \
//     -o test/integration/web/wasm_runner.wasm
//
// That is what CI runs — .github/workflows/ci.yaml:583. NOTE that no local
// script compiles this file: tool/test_wasm.sh and tool/test_cm_wasm.sh both
// build the dart2js entry point, so CI is the only place the dart2wasm twin is
// exercised. That asymmetry is exactly why the shared body below matters.
//
// Output protocol:
//   FIXTURE_RESULT:{"name":"<file>","ok":<bool>}
//   FIXTURE_RESULT:{"name":"<file>","ok":false,"reason":"<msg>"}
//   FIXTURE_DONE:{"total":<n>,"passed":<n>,"failed":<n>,"skipped":<n>}
//
// The CI job greps for FIXTURE_RESULT / FIXTURE_DONE from Chrome stderr.
//
// ---------------------------------------------------------------------------
// There is deliberately almost nothing here — see the note in wasm_runner.dart.
// The only thing this file may legitimately own is the logging shim: dart2wasm
// has no `print` that reaches Chrome's stderr, so it goes through
// `dart:js_interop` to `console.log`. Anything else added here is a divergence
// waiting to happen; put it in package:monty_conformance instead.
// ---------------------------------------------------------------------------

// DCM: this is a compiled entry-point, not a test file.
// ignore_for_file: prefer-correct-test-file-name

import 'dart:js_interop';

import 'package:monty_conformance/monty_conformance.dart';

@JS('console.log')
external void _consoleLog(JSAny? message);

/// Logs [message] to the browser console.
void _log(String message) => _consoleLog(message.toJS);

Future<void> main() => runFixtureCorpus(log: _log);
