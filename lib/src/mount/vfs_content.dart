import 'dart:convert';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// The content of a virtual file: text or bytes, never both, never `Object`.
///
/// Upstream stores `str | bytes` and preserves which one it was
/// (`os_access.py:638`, and the append rationale at `:923-928`). Dart has no
/// union types, and `Object` would push the question to every read site, so
/// this is a sealed ADT — the Dart 3 way to say the same thing with the
/// compiler enforcing exhaustiveness.
///
/// Keeping the distinction matters because two APIs disagree about what a
/// "length" is:
///
/// - `Path.write_text` returns a count of **characters**
/// - `stat().st_size` is a count of **bytes**
///
/// `'é'` is one character and two bytes, so a store that flattened both to one
/// representation would have to guess at one of those call sites.
@immutable
sealed class VfsContent {
  const VfsContent();

  /// Size in BYTES, whatever the underlying representation.
  ///
  /// This is what `stat().st_size` reports.
  int get byteLength;

  /// The content as bytes, encoding text as UTF-8.
  Uint8List get bytes;

  /// The content as text, decoding bytes as UTF-8.
  ///
  /// The symmetric partner of [bytes]: both are projections, and neither
  /// changes what is stored. Which one a file holds still decides
  /// `stat().st_size` and whether binary survives a round trip — that is the
  /// distinction the ADT exists to keep, and a projection does not erase it.
  ///
  /// Throws [FormatException] if the bytes are not valid UTF-8. Callers
  /// serving Python need CPython's `UnicodeDecodeError` instead, so the
  /// handler decodes at its own surface rather than through this getter.
  String get text;
}

/// Text content. Its [byteLength] is the UTF-8 encoded length, not
/// `String.length` — Dart's `String.length` counts UTF-16 code units.
final class VfsText extends VfsContent {
  /// Creates text content.
  VfsText(this.text);

  /// The text as written.
  @override
  final String text;

  // A deliberate lazy write-once cache, and the one place `late` earns itself
  // here. Encoding in the constructor would make seeding a text-only mount pay
  // for an encode it may never need; encoding per call would turn `stat()`,
  // which looks O(1), into O(n) in the file size.
  // ignore: avoid-late-keyword
  late final Uint8List _bytes = utf8.encode(text);

  @override
  int get byteLength => _bytes.length;

  @override
  Uint8List get bytes => _bytes;

  // Value equality: content is compared for what it holds, so a caller that
  // seeded a file and wants to know what Monty wrote can say
  // `expect(file.content, VfsText('...'))`.
  @override
  bool operator ==(Object other) => other is VfsText && other.text == text;

  @override
  int get hashCode => text.hashCode;
}

/// Binary content, stored verbatim.
///
/// The bytes are never round-tripped through a Dart `String`. That round trip
/// is what the previous `Map<String, String>` store did via
/// `utf8.decode(bytes, allowMalformed: true)`, which replaced every invalid
/// byte with U+FFFD and destroyed binary files at write time.
final class VfsBytes extends VfsContent {
  /// Creates binary content.
  const VfsBytes(this.bytes);

  /// The bytes as written.
  @override
  final Uint8List bytes;

  @override
  int get byteLength => bytes.length;

  @override
  String get text => utf8.decode(bytes);

  @override
  bool operator ==(Object other) =>
      other is VfsBytes &&
      other.bytes.length == bytes.length &&
      const IterableEquality<int>().equals(other.bytes, bytes);

  @override
  int get hashCode => const IterableEquality<int>().hash(bytes);
}
