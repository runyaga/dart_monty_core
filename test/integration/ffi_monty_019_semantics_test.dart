// FFI binding for the monty 0.19 semantics shared body.
//
// Run: dart test test/integration/ffi_monty_019_semantics_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_monty_019_semantics_test_body.dart';

void main() => runMonty019SemanticsTests();
