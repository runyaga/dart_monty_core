// WASM binding for the monty 0.19 semantics shared body.
//
// Run: dart test test/integration/wasm_monty_019_semantics_test.dart -p chrome
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_monty_019_semantics_test_body.dart';

void main() => runMonty019SemanticsTests();
