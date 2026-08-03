import 'package:dart_monty_core/dart_monty_core.dart';

/// Renders a fixture failure as something a reader — or a model retrying its
/// own generated code — can act on.
///
/// Reports the exception type, its message, the line number and the source
/// line, because each answers a different question: what went wrong, why,
/// where, and in which statement. The harness previously reported
/// `unexpected error in <fixture>`, which answers none of them (core#145).
String describeFixtureFailure(String fixture, MontyException? e) {
  if (e == null) {
    return '$fixture failed with no exception detail from the backend';
  }
  final where = e.lineNumber != null ? '$fixture:${e.lineNumber}' : fixture;
  final type = e.excType ?? 'error';
  final buffer = StringBuffer('$where — $type');
  if (e.message.isNotEmpty) buffer.write(': ${e.message}');
  final src = e.sourceCode?.trim();
  if (src != null && src.isNotEmpty) buffer.write('\n    $src');

  return buffer.toString();
}
