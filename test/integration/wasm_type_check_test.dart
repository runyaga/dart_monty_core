// WASM binding for the Monty.typeCheck shared test body.
//
// Run with dart2js:  dart test test/integration/wasm_type_check_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_type_check_test.dart -p chrome --compiler dart2wasm --run-skipped
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_type_check_test_body.dart';

void main() => runTypeCheckTests();
