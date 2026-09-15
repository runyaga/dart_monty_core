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
Future<(String?, MontyValue?, bool, MontyException?, String?)> _runDispatch(
  String source,
  String key,
) async {
  final platform = MontyFfi();
  try {
    final o = await runCallExternalFixture(platform, source, scriptName: key);

    // skipReason is CARRIED OUT, not dropped. DispatchOutcome has always had
    // the real reason; this record shape was what stopped it reaching the
    // report, so every skip routed through the dispatch loop collapsed to
    // "dispatch harness could not run this fixture" -- a message naming no
    // fixture, no external and no cause, and identical whether the backend
    // cannot do futures, cannot inject a named constant, or simply never
    // modelled the function.
    //
    // Measured: 1 of the 9 skips took this path today (dataclass__basic.py,
    // "needs an external we do not model: nonexistent_method"). The other 8
    // come from different markTestSkipped sites and were already specific --
    // 6 "no Return=/Raise= directive", 2 from the `broken` list. So this
    // widens 1 message, not 9; the value is that the dispatch loop's THREE
    // distinct reasons stop being indistinguishable as more fixtures land.
    return (o.excType, o.value, o.skipped, o.exception, o.skipReason);
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

    test('every knownBrokenExtFixtures entry STILL fails', () async {
      // Without this, the set is write-only. An entry names a fixture we skip
      // "because it is broken everywhere"; the day it gets FIXED the skip
      // persists, the fixture silently stops running, and the entry's reason
      // goes on describing something that is no longer true.
      //
      // That is not hypothetical here. dataclass__basic.py sat behind a stale
      // WEB-ONLY skip while nothing ran it on FFI either -- the doc comment on
      // knownBrokenExtFixtures says so in as many words -- and five dormant
      // DCM exclusions of the same shape were deleted from this repo on
      // 2026-09-15. A declared-broken list needs the same treatment the WASM
      // corpus already gets from tool/wasm-corpus-expected-failures.txt, which
      // fails in BOTH directions.
      final stale = <String>[];
      for (final MapEntry(:key, :value) in callExternalFixtures.entries) {
        if (!knownBrokenExtFixtures.containsKey(key)) continue;
        final expectation = parseFixture(value, skipCallExternal: false);
        if (expectation == null) continue;

        final (thrownExcType, resultValue, skipped, _, _) = await _runDispatch(
          value,
          key,
        );
        if (skipped) continue; // cannot run it, so cannot call it fixed

        final met = switch (expectation) {
          ExpectNoException() => thrownExcType == null,
          ExpectReturn(value: final expected) =>
            thrownExcType == null &&
                resultValue == MontyValue.fromDart(expected),
          ExpectRaise(excType: final want) => thrownExcType == want,
        };
        if (met) stale.add(key);
      }
      expect(
        stale,
        isEmpty,
        reason:
            'STALE: these are listed in knownBrokenExtFixtures but now MEET '
            'their expectation: $stale. Delete the entry -- a fixture that '
            'passes must not stay skipped, or it stops being tested.',
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
          skipReason,
        ) = await _runDispatch(
          value,
          key,
        );
        if (skipped) {
          markTestSkipped(
            skipReason ?? 'dispatch harness could not run this fixture',
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
