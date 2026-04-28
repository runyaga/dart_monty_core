// FFI binding for the MontyRepl snapshot/restore lifecycle shared body.
//
// Run: dart test test/integration/ffi_repl_snapshot_lifecycle_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_repl_snapshot_lifecycle_test_body.dart';

void main() => runReplSnapshotLifecycleTests();
