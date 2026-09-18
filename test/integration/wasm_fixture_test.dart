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

/// True on dart2js and dart2wasm, false on the VM.
///
/// `dart.library.io` is present only on native, so its absence is the one
/// signal that holds for BOTH web compilers — unlike `identical(1, 1.0)`,
/// which is a dart2js-only quirk and answers false on dart2wasm.
const bool _isWeb = !bool.fromEnvironment('dart.library.io');

void main() {
  group('wasm_fixture', () {
    for (final MapEntry(:key, :value) in fixtureCorpus.entries) {
      test(key, () async {
        // EXPECTED FAILURE, not a skip. A fixture in this set carries a CLAIM
        // -- "this diverges on web" -- and a bare `return` asserted nothing
        // while reporting GREEN, so the claim could never be contradicted. Two
        // entries were examined on 2026-08-03 and both were wrong:
        // dict__eq_self_referential.py had gone stale and passed on both
        // backends, and range__ops.py really did fail but for a different
        // reason than the one recorded.
        //
        // A skipped fixture is a fixture nobody runs, which is why a stale
        // reason can sit there indefinitely. So run it, require that it still
        // diverges, and go RED when it starts passing -- the entry is then
        // provably removable rather than merely suspected.
        //
        // This is the same bug this file already fixed one case below for
        // no-directive fixtures (core#130); it just was not applied here.
        // WEB ONLY. `alwaysUnsupportedWasmFixtures` is a claim about the web
        // backends; this same file runs on the VM (MontyFfi), where these
        // fixtures pass correctly — range__ops.py does. Asserting divergence
        // on VM would demand a failure that should not happen and would turn
        // a correct pass into a red test.
        // Only `alwaysUnsupportedWasmFixtures`. The retired
        // `unsupportedWasmFixtures` union also folded in
        // `testHooksWasmFixtures`, which is a different claim: "needs a build
        // we do not ship" cannot be falsified by running the fixture, whereas
        // "diverges on web" is exactly that. Measured with the union in place,
        // the five with__cm_* fixtures reported as STALE divergences because
        // they pass on web with no test-hooks build — they are not
        // divergences and never were.
        final expectDivergence =
            _isWeb && alwaysUnsupportedWasmFixtures.contains(key);

        // A DIFFERENT claim, so a different answer. "Needs a cargo feature we
        // never ship" is not falsifiable by running the fixture, unlike
        // "diverges on web". Report it as a skip WITH ITS REASON rather than a
        // bare `return`, which asserted nothing and reported green (core#130).
        // NOT web-gated, unlike the divergence check above. The shipped
        // engine has no test-hooks on EITHER platform — the VM's dylib is
        // built without it too (tool/test_cm.sh is what supplies it) — so the
        // reason to skip holds for both.
        if (testHooksWasmFixtures.contains(key)) {
          markTestSkipped('needs a --features test-hooks engine build');

          return;
        }
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

        if (expectDivergence) {
          // Did the run satisfy the fixture's own directive?
          final matched = switch (expectation) {
            ExpectNoException() => thrownExcType == null,
            ExpectReturn(value: final fixtureValue) =>
              thrownExcType == null &&
                  result?.value == MontyValue.fromDart(fixtureValue),
            ExpectRaise(:final excType) => thrownExcType == excType,
          };

          expect(
            matched,
            isFalse,
            reason:
                '$key is listed in alwaysUnsupportedWasmFixtures as '
                'diverging on web, but it PASSED here. The entry is stale — '
                'delete it and let the fixture assert normally. '
                '(dict__eq_self_referential.py was removed this way: it was '
                'listed as failing in the browser and passed on both web '
                'backends when actually run.)',
          );

          return;
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
