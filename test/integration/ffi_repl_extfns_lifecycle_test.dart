// FFI binding for the MontyRepl externals lifecycle shared test body.
//
// Run: dart test test/integration/ffi_repl_extfns_lifecycle_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_repl_extfns_lifecycle_test_body.dart';

void main() => runReplExtFnsLifecycleTests();
