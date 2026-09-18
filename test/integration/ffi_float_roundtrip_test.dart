// FFI binding for the inbound-float shared body.
//
// Run: dart test test/integration/ffi_float_roundtrip_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_float_roundtrip_test_body.dart';

void main() => runFloatRoundtripTests();
