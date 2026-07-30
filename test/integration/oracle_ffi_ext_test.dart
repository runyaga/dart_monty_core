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
import 'package:test/test.dart';

import '_fixture_corpus.dart';
import '_fixture_parser.dart';

// ---------------------------------------------------------------------------
// External-function dispatch table.
// ---------------------------------------------------------------------------
// Mirrors `_supportedExtFns` / `_dispatch` from wasm_runner.dart for the
// subset of ext fns actually called by fixtures in this corpus. Kept minimal
// on purpose — extend as new fixtures require new ext fns.

const _supportedExtFns = {
  'add_ints',
  'concat_strings',
  'return_value',
  'get_list',
};

Object? _dispatch(String name, List<MontyValue> args) => switch (name) {
  'add_ints' => (args[0].dartValue! as int) + (args[1].dartValue! as int),
  'concat_strings' => '${args[0].dartValue}${args[1].dartValue}',
  'return_value' => args[0].dartValue,
  'get_list' => [1, 2, 3],
  _ => throw StateError('unsupported ext fn: $name'),
};

const _nameConstants = <String, Object?>{
  'CONST_INT': 42,
  'CONST_STR': 'hello',
  'CONST_FLOAT': 3.14,
  'CONST_BOOL': true,
  'CONST_LIST': [1, 2, 3],
  'CONST_NONE': null,
};

// ---------------------------------------------------------------------------
// Dispatch loop — minimal version of wasm_runner.dart's for FFI.
// ---------------------------------------------------------------------------

/// Returns `(thrownExcType, resultValue, skipped)`.
///
/// Skipped is true when the fixture uses an ext fn outside [_supportedExtFns].
Future<(String?, MontyValue?, bool)> _runDispatch(
  String source,
  String key,
) async {
  final platform = MontyFfi();
  String? thrownExcType;
  MontyValue? resultValue;
  var skipped = false;

  try {
    MontyProgress? progress;
    try {
      progress = await platform.start(
        source,
        externalFunctions: _supportedExtFns.toList(),
        scriptName: key,
      );
    } on MontyScriptError catch (e) {
      thrownExcType = e.excType;
    }

    dispatchLoop:
    while (progress != null) {
      switch (progress) {
        case MontyComplete(:final result):
          thrownExcType = result.error?.excType;
          resultValue = result.value;
          break dispatchLoop;

        case MontyPending(:final functionName, :final args):
          if (!_supportedExtFns.contains(functionName)) {
            skipped = true;
            break dispatchLoop;
          }
          try {
            final ret = _dispatch(functionName, args);
            progress = await platform.resume(ret);
          } on MontyScriptError catch (e) {
            thrownExcType = e.excType;
            break dispatchLoop;
          }

        case MontyNameLookup(:final variableName):
          // FFI does not implement resumeNameLookupValue (constant injection
          // is WASM-only today). Fixtures that rely on injecting a named
          // constant are skipped here — they are covered by the WASM runner.
          if (_nameConstants.containsKey(variableName)) {
            skipped = true;
            break dispatchLoop;
          }
          try {
            progress = await platform.resumeNameLookupUndefined(variableName);
          } on MontyScriptError catch (e) {
            thrownExcType = e.excType;
            break dispatchLoop;
          }

        case MontyOsCall() || MontyResolveFutures():
          // Out of scope for this narrow test — skip.
          skipped = true;
          break dispatchLoop;
      }
    }
  } finally {
    await platform.dispose();
  }

  return (thrownExcType, resultValue, skipped);
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

        final (thrownExcType, resultValue, skipped) = await _runDispatch(
          value,
          key,
        );
        if (skipped) {
          markTestSkipped('dispatch harness could not run this fixture');

          return;
        }

        switch (expectation) {
          case ExpectNoException():
            expect(thrownExcType, isNull, reason: 'unexpected error in $key');
          case ExpectReturn(value: final expected):
            expect(thrownExcType, isNull, reason: 'unexpected error in $key');
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
