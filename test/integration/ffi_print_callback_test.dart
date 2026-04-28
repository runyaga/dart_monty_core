// FFI binding for the printCallback shared test body.
//
// Run: dart test test/integration/ffi_print_callback_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_print_callback_test_body.dart';

void main() => runPrintCallbackTests();
