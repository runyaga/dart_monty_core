// FFI binding for the Monty(code).run shared test body.
//
// Run: dart test test/integration/ffi_monty_compile_run_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_monty_compile_run_test_body.dart';

void main() => runMontyCompileRunTests();
