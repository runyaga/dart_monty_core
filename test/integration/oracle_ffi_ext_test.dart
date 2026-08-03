// Integration tests: external-function dispatch on the FFI backend.
//
// The sibling `oracle_ffi_test.dart` runs every fixture through FFI but
// silently skips `# call-external` fixtures (via parseFixture's default
// `skipCallExternal: true`). That leaves ext-fn dispatch on FFI completely
// uncovered — a real regression class (e.g. upstream VM changes, ext fn
// protocol drift) would go undetected.
//
// This file closes that gap: it runs every `# call-external` fixture through
// FFI with a real dispatch loop (parallel to `wasm_runner.dart`'s loop for
// WASM) and asserts against the fixture's declared expectation.
//
// Run: dart test test/integration/oracle_ffi_ext_test.dart -p vm --run-skipped
//
// Build prerequisites:
//   cd native && cargo build --release    # libdart_monty_core_native.dylib
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:dart_monty_core/src/ffi/monty_ffi.dart';
import 'package:monty_conformance/monty_conformance.dart';
import 'package:test/test.dart';

// ---------------------------------------------------------------------------
// External-function dispatch table.
// ---------------------------------------------------------------------------
// Mirrors `_supportedExtFns` / `_dispatch` from wasm_runner.dart for the
// subset of ext fns actually called by fixtures in this corpus. Kept minimal
// on purpose — extend as new fixtures require new ext fns.

// ---------------------------------------------------------------------------
// Dispatch loop — minimal version of wasm_runner.dart's for FFI.
// ---------------------------------------------------------------------------

/// Runs a `# call-external` fixture through the SHARED dispatch loop.
///
/// This file used to carry its own copy of the loop and its own 4-function
/// table, while `wasm_runner.dart` carried a 15-function one. The two had
/// drifted, so FFI silently asserted fewer fixtures than the browser did.
/// Both backends implement `MontyPlatform`, so there was never a reason for
/// two loops — see package:monty_conformance.
Future<(String?, MontyValue?, bool, MontyException?)> _runDispatch(
  String source,
  String key,
) async {
  final platform = MontyFfi();
  try {
    final o = await runCallExternalFixture(platform, source, scriptName: key);

    return (o.excType, o.value, o.skipped, o.exception);
  } finally {
    await platform.dispose();
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('oracle_ffi_ext', () {
    // Register ONLY the `# call-external` fixtures.
    //
    // This harness exists to exercise external-function dispatch, which the
    // other fixtures do not use. Previously all 531 were registered and the
    // ~475 non-call-external ones hit a bare `return` — so they reported as
    // PASSING while asserting nothing, and this harness advertised 531 green
    // tests on the strength of 51 real assertions (core#130).
    //
    // A test that can never run is not a test. Filtering at registration is
    // honest in a way that skipping inside the body is not: the count now
    // matches the work actually done.
    final callExternalFixtures = Map.fromEntries(
      fixtureCorpus.entries.where((e) => fixtureIsCallExternal(e.value)),
    );

    test('the corpus still contains call-external fixtures', () {
      // Guards the filter itself: if a corpus regeneration or a directive
      // rename silently emptied this harness, every other test here would
      // vanish and the suite would still be green.
      expect(
        callExternalFixtures,
        isNotEmpty,
        reason:
            'no `# call-external` fixtures found — the filter or the '
            'corpus is broken, and this harness is now testing nothing',
      );
    });

    for (final MapEntry(:key, :value) in callExternalFixtures.entries) {
      test(key, () async {
        final expectation = parseFixture(
          value,
          skipCallExternal: false,
        );
        if (expectation == null) {
          markTestSkipped('no Return=/Raise= directive to assert against');

          return;
        }

        final broken = knownBrokenExtFixtures[key];
        if (broken != null) {
          markTestSkipped(broken);

          return;
        }

        final (
          thrownExcType,
          resultValue,
          skipped,
          thrownException,
        ) = await _runDispatch(
          value,
          key,
        );
        if (skipped) {
          markTestSkipped('dispatch harness could not run this fixture');

          return;
        }

        switch (expectation) {
          case ExpectNoException():
            expect(
              thrownExcType,
              isNull,
              reason: describeFixtureFailure(key, thrownException),
            );
          case ExpectReturn(value: final expected):
            expect(
              thrownExcType,
              isNull,
              reason: describeFixtureFailure(key, thrownException),
            );
            expect(
              resultValue,
              equals(MontyValue.fromDart(expected)),
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
