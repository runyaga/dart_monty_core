// WASM binding for the control (d) end-to-end contract body.
//
// Run: dart test test/integration/wasm_control_d_test.dart -p chrome
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_control_d_test_body.dart';

void main() => runControlDTests();
