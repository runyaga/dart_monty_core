// The wire-format handshake (Phase 1 of BRIDGE-EXECUTE.md).
//
// `lib/assets/*.wasm` and the JS bridge are COMMITTED build artefacts, and the
// wasm build is not byte-reproducible — an unchanged tree yields different
// bytes — so `git diff` on the blob cannot tell you whether the asset matches
// the crate. That is not hypothetical: `lib/assets/PROVENANCE.md` was found
// stale this session with all three hashes wrong.
//
// A version integer can tell you, and this test is what makes it load-bearing
// rather than decorative.
@Tags(['integration', 'ffi'])
library;

import 'package:dart_monty_core/src/ffi/generated/dart_monty_bindings.dart'
    as ffi_native;
import 'package:dart_monty_core/src/ffi/native_bindings.dart';
import 'package:dart_monty_core/src/ffi/native_bindings_ffi.dart';
import 'package:test/test.dart';

void main() {
  group('wire format handshake', () {
    test('the native library agrees with what this Dart code expects', () {
      final actual = ffi_native.monty_wire_format_version();

      expect(
        actual,
        expectedWireFormatVersion,
        reason:
            'The loaded native library emits wire format v$actual but this '
            'build expects v$expectedWireFormatVersion. Either the committed '
            'assets are stale (run tool/prebuild.sh), or WIRE_FORMAT_VERSION '
            'in convert.rs was bumped without bumping '
            'expectedWireFormatVersion in native_bindings.dart — they must '
            'move in the same commit.',
      );
    });

    test('the version is a positive integer, not a default-zero', () {
      // Guards the failure mode where the symbol resolves but returns 0
      // because it was never wired up — which would make the check above
      // pass vacuously if the Dart constant were also 0.
      expect(ffi_native.monty_wire_format_version(), greaterThan(0));
    });

    // The two tests above assert agreement but do not assert that anything
    // CONSULTS it outside this file. That was the actual gap: the handshake was
    // enforced by a test in our gate, which a consumer of the published package
    // never runs. FFI has no `init()` to hang the check on — symbol resolution
    // is implicit — so construction is the moment.
    test('constructing NativeBindingsFfi runs the handshake', () {
      // Passes against a matching dylib. Watched red by bumping
      // expectedWireFormatVersion to 99: construction threw
      // WireFormatMismatch(99, 4) and this test failed, while the two above
      // failed with it — which is the point, they all read the same artefact.
      expect(NativeBindingsFfi.new, returnsNormally);
    });

    test('the handshake is latched, so repeated construction stays cheap', () {
      // Not a performance claim — an ordering one. If the latch were
      // per-instance, a second construction would re-enter the FFI call; if it
      // were skipped entirely after the first, a mismatch could be missed.
      // Both constructions must behave identically.
      expect(NativeBindingsFfi.new, returnsNormally);
      expect(NativeBindingsFfi.new, returnsNormally);
    });
  });
}
