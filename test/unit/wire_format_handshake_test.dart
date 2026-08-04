// The shared half of the wire-format handshake.
//
// `assertWireFormatVersion` is the one predicate both backends now call. The
// backend-specific tests (`ffi_wire_format_test.dart`,
// `wasm_wire_format_test.dart`) prove each artefact reports the right NUMBER;
// this proves the predicate reacts to that number correctly, including the two
// cases no real artefact can produce on demand — a stale version, and an
// artefact too old to have the symbol at all.
//
// Pure Dart on purpose, so it runs on the VM *and* under dart2js/dart2wasm.
// Per `feedback_run_pure_dart_tests_on_chrome`: a comparison of ints is exactly
// the shape that passes on the VM while being wrong on a web backend.
//
// The expected values do not come from the implementation. `expected` on a
// mismatch must be `expectedWireFormatVersion` because that is what the caller
// was built against, and `actual: -1` for a missing symbol is asserted as a
// literal, not by re-deriving the sentinel from the code under test.

import 'package:dart_monty_core/src/ffi/native_bindings.dart';
import 'package:test/test.dart';

void main() {
  group('assertWireFormatVersion', () {
    test('accepts the version this build expects', () {
      expect(
        () => assertWireFormatVersion(expectedWireFormatVersion),
        returnsNormally,
      );
    });

    test('rejects an older version', () {
      expect(
        () => assertWireFormatVersion(expectedWireFormatVersion - 1),
        throwsA(
          isA<WireFormatMismatch>()
              .having((e) => e.expected, 'expected', expectedWireFormatVersion)
              .having((e) => e.actual, 'actual', expectedWireFormatVersion - 1),
        ),
      );
    });

    test('rejects a NEWER version too — skew in either direction is skew', () {
      // A newer artefact than this Dart code is just as unsafe as an older
      // one: the decoder accepts what it was written for, not "at least".
      expect(
        () => assertWireFormatVersion(expectedWireFormatVersion + 1),
        throwsA(isA<WireFormatMismatch>()),
      );
    });

    test('treats a missing symbol (null) as a mismatch reporting -1', () {
      // An artefact predating the version export must NOT be able to opt out
      // of the check that exists to catch it. -1 is chosen because no build has
      // ever emitted it, so it cannot be confused with a real version.
      expect(
        () => assertWireFormatVersion(null),
        throwsA(
          isA<WireFormatMismatch>()
              .having((e) => e.expected, 'expected', expectedWireFormatVersion)
              .having((e) => e.actual, 'actual', -1),
        ),
      );
    });

    test('rejects zero — an unwired symbol must not read as agreement', () {
      // The failure mode where the symbol resolves but returns a default 0.
      // This is only a real guard while expectedWireFormatVersion != 0, which
      // the assertion below pins so the test cannot rot into a tautology.
      expect(expectedWireFormatVersion, greaterThan(0));
      expect(
        () => assertWireFormatVersion(0),
        throwsA(isA<WireFormatMismatch>()),
      );
    });

    test('names both versions and the remedy in its message', () {
      // The message is the whole value of failing at init rather than later:
      // someone reads it once, at 2am, and needs to know what to run.
      const e = WireFormatMismatch(expectedWireFormatVersion, 1);
      final message = e.toString();

      expect(message, contains('v$expectedWireFormatVersion'));
      expect(message, contains('v1'));
      expect(message, contains('tool/prebuild.sh'));
    });
  });
}
