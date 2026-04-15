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
import 'package:test/test.dart';

import '_fixture_corpus.dart';
import '_fixture_parser.dart';

void main() {
  group('wasm_fixture', () {
    for (final MapEntry(:key, :value) in fixtureCorpus.entries) {
      test(key, () async {
        final expectation = parseFixture(value, skipWasm: true);
        if (expectation == null) return; // skipped fixture

        final platform = createPlatformMonty();
        MontyResult? result;
        String? thrownExcType;
        try {
          result = await platform.run(value, scriptName: key);
          thrownExcType = result.error?.excType;
        } on MontyScriptError catch (e) {
          thrownExcType = e.excType;
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
              reason: 'unexpected error in $key',
            );
          case ExpectReturn(:final value):
            expect(
              thrownExcType,
              isNull,
              reason: 'unexpected error in $key',
            );
            expect(
              result?.value,
              equals(MontyValue.fromDart(value)),
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
