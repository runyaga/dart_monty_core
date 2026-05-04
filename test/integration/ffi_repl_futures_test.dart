// FFI binding for the REPL futures shared test body.
//
// Run: dart test test/integration/ffi_repl_futures_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_repl_futures_test_body.dart';

void main() => runReplFuturesTests();
