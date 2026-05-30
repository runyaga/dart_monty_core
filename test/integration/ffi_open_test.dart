// FFI binding for the open() / file-I/O shared body.
//
// Run: dart test test/integration/ffi_open_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_open_test_body.dart';

void main() => runOpenTests();
