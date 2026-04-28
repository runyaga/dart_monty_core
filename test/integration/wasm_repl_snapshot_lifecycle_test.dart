// WASM binding for the MontyRepl snapshot/restore lifecycle shared body.
//
// Run with dart2js:  dart test test/integration/wasm_repl_snapshot_lifecycle_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_repl_snapshot_lifecycle_test.dart -p chrome --compiler dart2wasm --run-skipped
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_repl_snapshot_lifecycle_test_body.dart';

void main() => runReplSnapshotLifecycleTests();
