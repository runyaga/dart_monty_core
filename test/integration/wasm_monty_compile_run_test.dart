// WASM binding for the Monty(code).run shared test body.
//
// Run with dart2js:  dart test test/integration/wasm_monty_compile_run_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_monty_compile_run_test.dart -p chrome --compiler dart2wasm --run-skipped
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_monty_compile_run_test_body.dart';

void main() => runMontyCompileRunTests();
