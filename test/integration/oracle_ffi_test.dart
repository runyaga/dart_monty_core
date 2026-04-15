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

import 'dart:io';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:test/test.dart';

import '_fixture_parser.dart';
import '_oracle_runner.dart';

void main() {
  final fixtureDir = Directory('test/fixtures/test_cases');

  if (!fixtureDir.existsSync()) {
    group('oracle_ffi', () {
      test('fixture directory missing', () {
        fail(
          'test/fixtures/test_cases not found. '
          'Create the symlink: ln -s /path/to/monty/crates/monty/test_cases '
          'test/fixtures/test_cases',
        );
      });
    });

    return;
  }

  final fixtures = fixtureDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.py'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));

  group('oracle_ffi', () {
    for (final file in fixtures) {
      final name = file.path.split('/').last;
      test(name, () async {
        final code = file.readAsStringSync();
        final expectation = parseFixture(code);
        if (expectation == null) return; // skipped fixture

        // Run the oracle to get the authoritative expected result.
        final oracleJson = await runOracle(code);
        final oracleResult = MontyResult.fromJson(
          Map<String, dynamic>.from(oracleJson),
        );

        // Run the FFI platform.
        final platform = MontyFfi();
        MontyResult? ffiResult;
        String? ffiExcType;
        try {
          ffiResult = await platform.run(code, scriptName: name);
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
            reason: 'excType mismatch for $name',
          );
        } else {
          // Both should succeed with the same value.
          expect(ffiResult?.error, isNull, reason: 'unexpected error in $name');
          expect(
            ffiResult?.value,
            equals(oracleResult.value),
            reason: 'value mismatch for $name',
          );
        }
      });
    }
  });
}
