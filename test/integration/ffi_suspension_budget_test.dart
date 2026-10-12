// FFI binding for the suspension-budget body (core#156).
//
// Run: dart test test/integration/ffi_suspension_budget_test.dart \
//        -p vm --run-skipped --tags=ffi
@Tags(['integration', 'ffi'])
library;

import 'package:test/test.dart';

import '_suspension_budget_body.dart';

void main() => runSuspensionBudgetTests('ffi');
