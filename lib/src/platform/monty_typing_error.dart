import 'dart:convert';

import 'package:meta/meta.dart';

/// A single static-type-check diagnostic produced by `Monty.typeCheck`.
///
/// Each diagnostic identifies a typing problem in the analysed source —
/// e.g. an incompatible assignment, an unresolvable reference, or a
/// disallowed return type. Diagnostics are surfaced as a `List` so that
/// IDE-style consumers can render them inline without parsing a single
/// concatenated string.
///
/// Field shape mirrors the upstream `monty-type-checking` JSON renderer
/// (formats listed in
/// `crates/monty-type-checking/src/type_check.rs::format_from_str`):
///
/// - [code] — diagnostic code, e.g. `'invalid-assignment'`. Useful for
///   filtering or muting specific rules.
/// - [message] — human-readable text.
/// - [path] — filename used in spans (the `scriptName` you passed to
///   `Monty.typeCheck`).
/// - [line] / [column] — 1-indexed start position.
/// - [endLine] / [endColumn] — 1-indexed exclusive end position.
/// - [url] — link to documentation for [code], if available.
@immutable
final class MontyTypingError {
  /// Creates a [MontyTypingError].
  const MontyTypingError({
    required this.code,
    required this.message,
    this.path,
    this.line,
    this.column,
    this.endLine,
    this.endColumn,
    this.url,
  });

  /// Parses one diagnostic from the upstream JSON shape.
  factory MontyTypingError.fromJson(Map<String, dynamic> map) {
    int? row(Object? loc) =>
        loc is Map<String, dynamic> ? (loc['row'] as num?)?.toInt() : null;
    int? col(Object? loc) =>
        loc is Map<String, dynamic> ? (loc['column'] as num?)?.toInt() : null;

    return MontyTypingError(
      code: map['code'] as String? ?? '',
      message: map['message'] as String? ?? '',
      path: map['filename'] as String?,
      line: row(map['location']),
      column: col(map['location']),
      endLine: row(map['end_location']),
      endColumn: col(map['end_location']),
      url: map['url'] as String?,
    );
  }

  /// Diagnostic rule code (e.g. `'invalid-assignment'`).
  final String code;

  /// Human-readable diagnostic message.
  final String message;

  /// Filename the diagnostic refers to.
  final String? path;

  /// Start line (1-indexed).
  final int? line;

  /// Start column (1-indexed).
  final int? column;

  /// End line (1-indexed, exclusive).
  final int? endLine;

  /// End column (1-indexed, exclusive).
  final int? endColumn;

  /// Documentation URL for [code], if available.
  final String? url;

  /// Parses the JSON-array string emitted by `Monty.typeCheck` into a
  /// list of diagnostics. An empty/null input returns an empty list.
  static List<MontyTypingError> listFromJson(String? jsonStr) {
    if (jsonStr == null || jsonStr.isEmpty) return const [];
    final decoded = json.decode(jsonStr);
    if (decoded is! List) return const [];

    return decoded
        .whereType<Map<String, dynamic>>()
        .map(MontyTypingError.fromJson)
        .toList(growable: false);
  }

  @override
  String toString() {
    final String loc;
    if (path != null && line != null && column != null) {
      loc = '$path:$line:$column';
    } else if (line != null) {
      loc = 'line $line';
    } else {
      loc = 'unknown';
    }

    return 'MontyTypingError($code at $loc: $message)';
  }
}
