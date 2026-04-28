// FFI binding for the Monty.typeCheck shared test body.
//
// Run: dart test test/integration/ffi_type_check_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_type_check_test_body.dart';

void main() => runTypeCheckTests();
