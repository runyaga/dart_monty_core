// WASM binding for the output-depth truncation property (PT-S2.1).
//
// The at-and-over-cap rows do not run here: the browser backend exhausts its
// linear memory in (400, 600], before monty's 1000-deep truncation can fire,
// and the failure poisons the page for every later test. The ceiling and the
// measurement behind it are documented at `_wasmDepthCeiling`.
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_output_depth_test_body.dart';

void main() => runOutputDepthTests(depthCeiling: wasmDepthCeiling);
