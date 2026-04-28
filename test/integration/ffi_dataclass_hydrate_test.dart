// FFI binding for the MontyDataclass.hydrate shared body.
//
// Run: dart test test/integration/ffi_dataclass_hydrate_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_dataclass_hydrate_test_body.dart';

void main() => runDataclassHydrateTests();
