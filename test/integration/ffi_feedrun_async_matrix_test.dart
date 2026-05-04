// FFI binding for the Layer 2 `MontyRepl.feedRun` async/sync matrix.
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_feedrun_async_matrix_body.dart';

void main() => runFeedRunAsyncMatrixTests();
