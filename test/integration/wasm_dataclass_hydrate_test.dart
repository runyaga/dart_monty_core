// WASM binding for the MontyDataclass.hydrate shared body.
//
// Run with dart2js:  dart test test/integration/wasm_dataclass_hydrate_test.dart -p chrome --run-skipped
// Run with dart2wasm: dart test test/integration/wasm_dataclass_hydrate_test.dart -p chrome --compiler dart2wasm --run-skipped
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_dataclass_hydrate_test_body.dart';

void main() => runDataclassHydrateTests();
