import 'package:dart_monty_core/dart_monty_core.dart';

/// What a failed fixture raised, as [describeFixtureFailure] reports it.
final class FixtureFailure {
  /// Creates a [FixtureFailure].
  const FixtureFailure({
    required this.excType,
    this.message,
    this.lineNumber,
    this.sourceCode,
  });

  /// The failure [error] is: its Python exception, and the innermost frame's
  /// line and source when it has a traceback.
  factory FixtureFailure.fromError(MontyError error) {
    final frames = switch (error) {
      MontySyntaxError(:final traceback) => traceback,
      MontyRuntimeError(:final traceback) => traceback,
      MontyTypingError() || MontyCrashedError() => const <Frame>[],
    };
    final innermost = frames.isEmpty ? null : frames.last;

    return FixtureFailure(
      excType: error.exception.excType,
      message: error.exception.message,
      lineNumber: innermost?.line,
      sourceCode: innermost?.sourceLine,
    );
  }

  /// The Python exception class, e.g. `'AssertionError'`.
  final String excType;

  /// The exception's message, when it has one.
  final String? message;

  /// The line the innermost frame starts on, when there is a frame.
  final int? lineNumber;

  /// The innermost frame's source line, when there is one.
  final String? sourceCode;
}

/// Renders a fixture failure as something a reader — or a model retrying its
/// own generated code — can act on.
///
/// Reports the exception type, its message, the line number and the source
/// line, because each answers a different question: what went wrong, why,
/// where, and in which statement (core#145).
String describeFixtureFailure(String fixture, FixtureFailure? failure) {
  if (failure == null) {
    return '$fixture failed with no exception detail from the backend';
  }
  final line = failure.lineNumber;
  final where = line != null ? '$fixture:$line' : fixture;
  final buffer = StringBuffer('$where — ${failure.excType}');
  final message = failure.message;
  if (message != null && message.isNotEmpty) buffer.write(': $message');
  final src = failure.sourceCode?.trim();
  if (src != null && src.isNotEmpty) buffer.write('\n    $src');

  return buffer.toString();
}
