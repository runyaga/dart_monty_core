// WASM binding for the inbound-float shared body.
//
// Run with dart2js:  dart test test/integration/wasm_float_roundtrip_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_float_roundtrip_test.dart -p chrome --compiler dart2wasm --run-skipped
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_float_roundtrip_test_body.dart';

void main() => runFloatRoundtripTests();
