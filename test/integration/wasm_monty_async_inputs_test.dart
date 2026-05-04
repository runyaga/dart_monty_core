// WASM binding for the async-inputs shared test body.
//
// Run with dart2js:  dart test test/integration/wasm_monty_async_inputs_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_monty_async_inputs_test.dart -p chrome --compiler dart2wasm --run-skipped
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_monty_async_inputs_test_body.dart';

void main() => runMontyAsyncInputsTests();
