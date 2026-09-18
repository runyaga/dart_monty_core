// FFI binding for the OS-call decline shared body.
//
// Run: dart test test/integration/ffi_oscall_decline_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_oscall_decline_test_body.dart';

void main() => runOsCallDeclineTests();
