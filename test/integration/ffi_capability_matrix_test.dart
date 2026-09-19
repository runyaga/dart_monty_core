// FFI binding for the E2 capability matrix body.
//
// Run: dart test test/integration/ffi_capability_matrix_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_capability_matrix_body.dart';

void main() => runCapabilityMatrix('ffi');
