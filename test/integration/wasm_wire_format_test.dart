// Run with dart2js:  dart test test/integration/wasm_wire_format_test.dart -p chrome
// Run with dart2wasm: dart test test/integration/wasm_wire_format_test.dart -p chrome --compiler dart2wasm
//
// The WASM half of the wire-format handshake (Phase 1 of BRIDGE-EXECUTE.md),
// and the half that was missing when it mattered.
//
// `ffi_wire_format_test.dart` shipped without this twin, so the handshake
// covered only the backend that reads the crate it was built from. The web
// backend is the one that loads the COMMITTED `lib/assets/*.wasm`, i.e. the only
// backend that can go stale — and it was unguarded by any named test. A stale
// asset was duly committed, and the web assertion surfaced as 519 identical
// fixture failures in CI rather than as one legible red line.
//
// This asserts the same fact once, by name. It cannot be satisfied vacuously:
// the version is read back out of the loaded asset, not out of a Dart constant.
@Tags(['integration', 'wasm'])
library;

import 'package:dart_monty_core/src/ffi/native_bindings.dart'
    show WireFormatMismatch, expectedWireFormatVersion;
import 'package:dart_monty_core/src/wasm/wasm_bindings_js.dart';
import 'package:test/test.dart';

void main() {
  group('wire format handshake (WASM)', () {
    late WasmBindingsJs bindings;

    setUp(() async {
      bindings = WasmBindingsJs();
      // init() asserts the handshake internally and THROWS on disagreement.
      // Swallowing that here is deliberate, and was measured: letting it escape
      // makes every test in the group report the same exception from setUp, so
      // the reason strings below — the ones naming which version was seen and
      // what to do about it — never render. The session is created before the
      // assertion runs, so the reported version is readable either way, and the
      // tests then fail with the NUMBER.
      try {
        await bindings.init();
      } on WireFormatMismatch {
        // Asserted on below, where it produces a legible expected/actual.
      }
    });

    test(
      'the committed WASM asset agrees with what this Dart code expects',
      () {
        final actual = bindings.reportedWireFormatVersion;
        final reported = actual == null
            ? 'reports no wire-format version at all, so the committed asset '
                  'predates the export entirely'
            : 'emits wire format v$actual';

        expect(
          actual,
          expectedWireFormatVersion,
          reason:
              'lib/assets/dart_monty_core_native.wasm $reported, '
              'but this build expects v$expectedWireFormatVersion. Either run '
              'tool/prebuild.sh AND COMMIT the result, or WIRE_FORMAT_VERSION '
              'in convert.rs moved without expectedWireFormatVersion in '
              'native_bindings.dart — they must move in the same commit.',
        );
      },
    );

    test('the version is a positive integer, not a default-zero', () {
      // Mirrors the FFI twin: guards the case where the export resolves but
      // returns 0 because it was never wired up, which would make the check
      // above pass vacuously if the Dart constant were also 0. This project
      // measured 646 of 1593 tests asserting nothing, so that failure mode is
      // native here.
      //
      // `?? -1` because a missing export reads as null, and matching null
      // against greaterThan throws a NoSuchMethodError on dart2js — a stack
      // trace where a number belongs. Substituting the same sentinel the
      // handshake uses keeps the failure legible on all three targets.
      expect(bindings.reportedWireFormatVersion ?? -1, greaterThan(0));
    });
  });
}
