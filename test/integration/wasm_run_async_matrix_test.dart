// WASM binding for the Layer 3 `Monty.run` async/sync matrix.
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_run_async_matrix_body.dart';

void main() => runRunAsyncMatrixTests();
