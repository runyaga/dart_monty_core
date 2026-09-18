// FFI binding for the control (d) shared body.
//
// Run: dart test test/integration/ffi_control_d_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_control_d_test_body.dart';

void main() => runControlDTests();
