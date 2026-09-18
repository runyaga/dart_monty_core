// WASM binding for the OS-call decline shared body.
//
// Run with dart2js:  dart test test/integration/wasm_oscall_decline_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_oscall_decline_test.dart -p chrome --compiler dart2wasm --run-skipped
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_oscall_decline_test_body.dart';

void main() => runOsCallDeclineTests();
