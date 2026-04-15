// Integration tests: compare dart_monty_core FFI output against the oracle.
//
// The oracle binary runs Python code through the same Monty Rust crate the FFI
// uses and outputs JSON in the exact same format. Dart tests pipe code to the
// oracle, parse both results into MontyResult, and assert they agree on value
// and error type.
//
// Run: dart test test/integration/oracle_ffi_test.dart -p vm --run-skipped
//
// Build oracle first: cd native && cargo build --bin oracle
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:test/test.dart';

import '_fixture_corpus.dart';
import '_fixture_parser.dart';
import '_oracle_runner.dart';

void main() {
  group('oracle_ffi', () {
    for (final MapEntry(:key, :value) in fixtureCorpus.entries) {
      test(key, () async {
        final expectation = parseFixture(value);
        if (expectation == null) return; // skipped fixture

        // Run the oracle to get the authoritative expected result.
        final oracleJson = await runOracle(value);
        final oracleResult = MontyResult.fromJson(
          Map<String, dynamic>.from(oracleJson),
        );

        // Run the FFI platform.
        final platform = MontyFfi();
        MontyResult? ffiResult;
        String? ffiExcType;
        try {
          ffiResult = await platform.run(value, scriptName: key);
          ffiExcType = ffiResult.error?.excType;
        } on MontyScriptError catch (e) {
          ffiExcType = e.excType;
        } on MontyResourceError {
          ffiExcType = 'MemoryLimitExceeded';
        } finally {
          await platform.dispose();
        }

        if (oracleResult.error != null) {
          // Both should agree on the exception type.
          expect(
            ffiExcType,
            equals(oracleResult.error!.excType),
            reason: 'excType mismatch for $key',
          );
        } else {
          // Both should succeed with the same value.
          expect(ffiResult?.error, isNull, reason: 'unexpected error in $key');
          expect(
            ffiResult?.value,
            equals(oracleResult.value),
            reason: 'value mismatch for $key',
          );
        }
      });
    }
  });
}
