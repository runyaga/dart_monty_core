// FFI binding for the Monty.exec externals shared test body.
//
// Run: dart test test/integration/ffi_monty_exec_externals_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_monty_exec_externals_test_body.dart';

void main() => runMontyExecExternalsTests();
