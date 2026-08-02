// Integration tests: verify WASM/JS output matches fixture directives.
//
// Unlike the FFI test, this test cannot use subprocess oracle binaries.
// Instead it relies on the `# Return=` and `# Raise=` directives in each
// fixture file as the source of truth.
//
// Run with dart2js:   dart test -p chrome --run-skipped --tags=wasm
// Run with dart2wasm: dart test -p chrome --compiler dart2wasm
//                     --run-skipped --tags=wasm
//
// The platform is selected at compile time:
// MontyWasm on Chrome (dart2js or dart2wasm), MontyFfi on VM.
@Tags(['integration', 'wasm'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:monty_conformance/monty_conformance.dart';
import 'package:test/test.dart';

void main() {
  group('wasm_fixture', () {
    for (final MapEntry(:key, :value) in fixtureCorpus.entries) {
      test(key, () async {
        // v0.0.18 features not yet wired into the WASM binding.
        if (unsupportedWasmFixtures.contains(key)) return;
        final expectation = parseFixture(value);
        if (expectation == null) {
          // Was a bare `return`: the test asserted nothing and reported
          // GREEN. Reporting a skip is the honest signal (core#130).
          markTestSkipped('no Return=/Raise= directive to assert against');

          return;
        }

        final platform = createPlatformMonty();
        MontyResult? result;
        String? thrownExcType;
        MontyException? thrownException;
        try {
          result = await platform.run(value, scriptName: key);
          thrownExcType = result.error?.excType;
          thrownException = result.error;
        } on MontyScriptError catch (e) {
          thrownExcType = e.excType;
          thrownException = e.exception;
        } on MontyResourceError {
          thrownExcType = 'MemoryLimitExceeded';
        } finally {
          await platform.dispose();
        }

        switch (expectation) {
          case ExpectNoException():
            expect(
              thrownExcType,
              isNull,
              reason: describeFixtureFailure(key, thrownException),
            );
          case ExpectReturn(value: final fixtureValue):
            expect(
              thrownExcType,
              isNull,
              reason: describeFixtureFailure(key, thrownException),
            );
            expect(
              result?.value,
              equals(MontyValue.fromDart(fixtureValue)),
              reason: 'value mismatch for $key',
            );
          case ExpectRaise(:final excType):
            expect(
              thrownExcType,
              equals(excType),
              reason: 'excType mismatch for $key',
            );
        }
      });
    }
  });
}
