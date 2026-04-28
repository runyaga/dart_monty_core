/// Utilities for converting Dart values to Python literal strings.
///
/// Used by Monty(code).run and MontyRepl.feedRun to inject per-invocation
/// variables into the Python scope before execution.
library;

/// Converts a Dart value to a Python source literal.
///
/// Handles: `null` (→ `None`), `bool` (→ `True`/`False`), `int`, `double`
/// (including `NaN` and `Infinity`), `String`, `List<dynamic>`, and
/// `Map<dynamic, dynamic>`.
///
/// Throws [ArgumentError] for unsupported types such as arbitrary objects
/// or [DateTime].
String toPythonLiteral(Object? value) => switch (value) {
  null => 'None',
  final bool b => b ? 'True' : 'False',
  final int n => '$n',
  final double d when d.isNaN => "float('nan')",
  final double d when d.isInfinite => d < 0 ? "float('-inf')" : "float('inf')",
  final double d => '$d',
  final String s => _escapePythonString(s),
  final List<Object?> l => '[${l.map(toPythonLiteral).join(', ')}]',
  final Map<Object?, Object?> m =>
    '{${m.entries.map(_mapEntryLiteral).join(', ')}}',
  _ => throw ArgumentError(
    'Cannot convert ${value.runtimeType} to Python literal',
  ),
};

/// Generates Python assignment statements from [inputs].
///
/// Returns an empty string when [inputs] is empty. Each key must be a
/// valid Python identifier. Values are converted via [toPythonLiteral].
///
/// ```dart
/// inputsToCode({'x': 10, 'name': 'Alice'})
/// // returns "x = 10\nname = 'Alice'"
/// ```
///
/// Throws [ArgumentError] if any value cannot be converted.
String inputsToCode(Map<String, Object?> inputs) {
  if (inputs.isEmpty) return '';

  return inputs.entries
      .map((e) => '${e.key} = ${toPythonLiteral(e.value)}')
      .join('\n');
}

String _escapePythonString(String s) {
  final esc = s
      .replaceAll(r'\', r'\\')
      .replaceAll("'", r"\'")
      .replaceAll('\n', r'\n')
      .replaceAll('\r', r'\r')
      .replaceAll('\t', r'\t');

  return "'$esc'";
}

String _mapEntryLiteral(MapEntry<Object?, Object?> entry) =>
    '${toPythonLiteral(entry.key)}: ${toPythonLiteral(entry.value)}';
