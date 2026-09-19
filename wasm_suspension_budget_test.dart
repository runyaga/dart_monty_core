// WASM binding for the suspension-budget body (core#156).
//
// The budget is enforced HOST-SIDE, so it needs no backend support and
// applies here even though the web REPL refuses engine session limits
// (core#140). That is the property this mirror exists to pin.
//
// Run: bash tool/test_wasm_unit.sh  (it is listed in SUITES)
@Tags(['integration', 'wasm'])
library;

import 'package:test/test.dart';

import '_suspension_budget_body.dart';

void main() => runSuspensionBudgetTests('wasm');
