// Unit tests for WireFormatMismatch — the exception the wire-format handshake
// throws when the loaded native library disagrees with this build.
//
// Written because the patch-coverage gate, on the first verdict it has ever
// rendered, reported these five lines as the only uncovered ones in the change
// (68% against a 70% floor). It was right to: the whole value of this exception
// is the sentence it prints, that sentence is the only instruction a consumer
// or CI log ever gets, and nothing asserted a word of it.
//
// Pure value-level tests: no interpreter, no FFI, no WASM.
@Tags(['unit'])
library;

import 'package:dart_monty_core/src/ffi/native_bindings.dart';
import 'package:test/test.dart';

void main() {
  group('WireFormatMismatch', () {
    test('keeps both versions as given', () {
      const e = WireFormatMismatch(1, 2);

      expect(e.expected, 1);
      expect(e.actual, 2);
    });

    test('names both versions and what to do about it', () {
      final message = const WireFormatMismatch(3, 7).toString();

      // Both numbers must survive into the text. A message naming only one of
      // them cannot tell you which side moved.
      expect(message, contains('v3'));
      expect(message, contains('v7'));
      // The actionable half. This is the line a consumer sees at init and the
      // line CI shows when a committed asset goes stale, so it has to say what
      // to run — that exact sequence happened on this branch.
      expect(message, contains('lib/assets/'));
      expect(message, contains('tool/prebuild.sh'));
    });

    test('reports the absent-export sentinel as a version, not as a crash', () {
      // The web path substitutes -1 when the asset predates the export
      // entirely, so `v-1` is a real message that real people read. Asserted
      // here so nobody "tidies" the sentinel into something that formats as
      // "vnull" or throws while building the string.
      final message = const WireFormatMismatch(1, -1).toString();

      expect(message, contains('v-1'));
    });

    test('is an Exception', () {
      expect(const WireFormatMismatch(1, 2), isA<Exception>());
    });
  });
}
