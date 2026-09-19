// WASM binding for the E2 capability matrix body.
//
// Run: bash tool/test_wasm_unit.sh  (it is listed in SUITES)
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_capability_matrix_body.dart';

void main() => runCapabilityMatrix('wasm');
