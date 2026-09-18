// VfsContent's two shapes, and the one that can throw.
//
// lib/src/mount/vfs_content.dart sat at 63.6% (14/22). The uncovered part was
// `VfsText.hashCode` and ALL of `VfsBytes` — byteLength, text, == and
// hashCode. VfsBytes is the binary content type for the mounted filesystem, so
// every non-UTF-8 file a host seeds or Monty writes goes through it.
//
// THE EDGE THAT MATTERS. `VfsBytes.text` is `utf8.decode(bytes)`, which THROWS
// on malformed input rather than substituting replacement characters:
//
//     VfsBytes([0xC3, 0x28]).text
//       -> FormatException: Missing extension byte (at offset 1)
//
// So `text` is not a safe accessor on a binary file — it is a decode that can
// fail, and a caller reaching for `.text` to log or display arbitrary bytes
// gets an exception rather than mojibake. Measured, then asserted; nothing had
// exercised it either way.
@Tags(['unit'])
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/dart_monty_core.dart';
import 'package:test/test.dart';

VfsBytes _bytes(List<int> b) => VfsBytes(Uint8List.fromList(b));

void main() {
  group('VfsBytes', () {
    test('byteLength is the byte count, not a character count', () {
      // 'é' is two bytes and one character. A length that counted characters
      // would report a file size the filesystem disagrees with.
      expect(_bytes([1, 2, 3]).byteLength, 3);
      expect(_bytes(utf8.encode('é')).byteLength, 2);
      expect(_bytes(const []).byteLength, 0);
    });

    test('text decodes valid UTF-8', () {
      expect(_bytes([104, 105]).text, 'hi');
      expect(_bytes(utf8.encode('héllo')).text, 'héllo');
      expect(_bytes(const []).text, isEmpty);
    });

    test(
      'text THROWS on malformed UTF-8 — it is a decode, not an accessor',
      () {
        expect(
          () => _bytes([0xC3, 0x28]).text,
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              contains('Missing extension byte'),
            ),
          ),
          reason:
              'a caller reaching for .text on arbitrary bytes must get an '
              'exception, not silent replacement characters',
        );
      },
    );

    test('equality is DEEP over the bytes, and hashCode agrees', () {
      final a = _bytes([1, 2, 3]);
      final b = _bytes([1, 2, 3]);

      expect(identical(a.bytes, b.bytes), isFalse, reason: 'distinct lists');
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
    });

    test('differing length or content breaks equality', () {
      expect(_bytes([1, 2, 3]), isNot(_bytes([1, 2])));
      expect(_bytes([1, 2, 3]), isNot(_bytes([1, 2, 4])));
      expect(_bytes(const []), isNot(_bytes([0])));
    });
  });

  group('VfsText', () {
    test('equality and hashCode follow the text', () {
      // TWO DISTINCT INSTANCES, deliberately. Collapsing these to one
      // variable would make equality and hashCode agree by identity and the
      // test would pass against a class that defines neither.
      final a1 = VfsText('a');
      final a2 = VfsText('a');
      expect(a1, equals(a2));
      expect(a1.hashCode, a2.hashCode);
      expect(a1, isNot(VfsText('b')));
    });
  });

  group('the two shapes never compare equal', () {
    test('VfsText and VfsBytes are distinct even with the same content', () {
      // Both can represent "hi". They are different types with different
      // semantics — one is decoded, the other is not — and `==` must say so,
      // or a test asserting `file.content == VfsText('hi')` would pass for a
      // binary file that merely happens to decode.
      final asBytes = _bytes(utf8.encode('hi'));

      expect(asBytes, isNot(VfsText('hi')));
      expect(VfsText('hi'), isNot(asBytes));
      expect(asBytes.text, VfsText('hi').text);
    });
  });
}
