// WASM binding for the wire-contract type-identity property (Phase 1 of
// BRIDGE-EXECUTE.md).
//
// The web half is not a formality: invariant I1 must hold identically on FFI,
// dart2js and dart2wasm, and core#128 is a defect that exists ONLY here.
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_wire_contract_test_body.dart';

void main() => runWireContractTests();
