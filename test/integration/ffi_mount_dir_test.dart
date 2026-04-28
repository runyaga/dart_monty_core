// FFI binding for the MountDir + memoryMountedOsHandler shared body.
//
// Run: dart test test/integration/ffi_mount_dir_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_mount_dir_test_body.dart';

void main() => runMountDirTests();
