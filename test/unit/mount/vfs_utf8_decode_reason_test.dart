// `read_text` on invalid UTF-8 must name WHICH KIND of byte was wrong.
//
// memory_mounted_os_handler.dart:856 picks the reason:
//
//     byte >= 0xC2 && byte <= 0xF4 ? 'invalid continuation byte'
//                                  : 'invalid start byte'
//
// Found by a MECHANICAL mutation pass: flipping that `&&` to `||` makes the
// condition ALWAYS TRUE -- every byte is either >= 0xC2 or <= 0xF4 -- so every
// failure reports "invalid continuation byte", and the suite stayed green.
// Nothing anywhere asserted either string.
//
// It matters more than a typo would. This package exists so a model can read a
// failure and retry; the Rust side deliberately mirrors CPython's message
// (monty-types/src/exceptions.rs:765-779), and `check_no_vague_errors.sh` is a
// gate in this repo. A diagnostic that always says the same thing is the same
// defect that check exists to prevent, one level down.
//
// MEASURED, both the byte offsets Dart reports and the resulting message:
//     [0xC3, 0xC3] -> dart offset 1 -> 0xC3 in range  -> continuation byte
//     [0xFF]       -> dart offset 0 -> 0xFF out       -> start byte
//     [0x80]       -> dart offset 0 -> 0x80 out       -> start byte
//
// Falsifier: make that `&&` an `||`; the start-byte rows fail.
@Tags(['unit'])
library;

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

void main() {
  group('UTF-8 decode failure names the right kind of byte', () {
    Future<String> reasonFor(List<int> bytes) async {
      final h = memoryMountedOsHandler(
        mounts: const [MountDir(virtualPath: '/m')],
        files: [MontyMemoryFile('/m/f.bin', bytes)],
      );
      try {
        await h('Path.read_text', ['/m/f.bin'], null);

        return 'decoded';
      } on OsCallException catch (e) {
        return e.message;
      }
    }

    test('a LEAD byte where a continuation was expected', () async {
      // 0xC3 opens a 2-byte sequence; a second 0xC3 cannot continue it.
      expect(
        await reasonFor([0xC3, 0xC3]),
        "'utf-8' codec can't decode byte 0xc3 in position 1: "
        'invalid continuation byte',
      );
    });

    test('a byte that cannot START any sequence', () async {
      expect(
        await reasonFor([0xFF]),
        "'utf-8' codec can't decode byte 0xff in position 0: "
        'invalid start byte',
      );
    });

    test('a stray continuation byte cannot start one either', () async {
      expect(
        await reasonFor([0x80]),
        "'utf-8' codec can't decode byte 0x80 in position 0: "
        'invalid start byte',
      );
    });

    // A SEPARATE DEFECT, pinned as CURRENT behaviour rather than asserted as
    // correct. For a TRUNCATED sequence Dart reports an offset PAST the last
    // byte, so `bytes.elementAtOrNull(pos) ?? 0` invents a byte:
    //
    //     [0xC3]             -> "byte 0x00 in position 1"
    //     [0xE2, 0x82]       -> "byte 0x00 in position 2"
    //
    // There is no 0x00 in either input. CPython says "unexpected end of data"
    // for exactly these. Changing the message is a behaviour change and needs
    // its own decision, so this row records what happens today and will fail
    // loudly when someone fixes it.
    test(
      'TRUNCATED input reports a phantom 0x00 (current behaviour)',
      () async {
        expect(
          await reasonFor([0xC3]),
          "'utf-8' codec can't decode byte 0x00 in position 1: "
          'invalid start byte',
          reason:
              'if this now says "unexpected end of data", the phantom-byte '
              'defect was fixed and this row should be updated, not deleted',
        );
      },
    );
  });
}
