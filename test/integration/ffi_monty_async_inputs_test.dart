// FFI binding for the async-inputs shared test body.
//
// Run: dart test test/integration/ffi_monty_async_inputs_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_monty_async_inputs_test_body.dart';

void main() => runMontyAsyncInputsTests();
