/// Utilities for converting Dart values to Python literal strings.
///
/// Used by Monty(code).run and MontyRepl.feedRun to inject per-invocation
/// variables into the Python scope before execution.
library;

import 'package:dart_monty_core/src/platform/double_text.dart';
import 'package:dart_monty_core/src/platform/monty_internal_error.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart' show MontyNone;

/// Converts a Dart value to a Python source literal.
///
/// Handles: [MontyNone] (→ `None`), `bool` (→ `True`/`False`),
/// `int`, `double` (including `NaN` and `Infinity`), `String`,
/// `List<dynamic>`, and `Map<dynamic, dynamic>`.
///
/// Use [MontyNone] explicitly to represent Python `None` — Dart `null` is
/// treated as an unsupported type and will throw [ArgumentError].
///
/// Throws [ArgumentError] for unsupported types such as `null`, arbitrary
/// objects, or [DateTime].
String toPythonLiteral(Object? value) => switch (value) {
  null => throw MontyInternalError(
    'toPythonLiteral: Dart null is not a valid Python literal. '
    'Use MontyNone() to represent Python None.',
  ),
  MontyNone() => 'None',
  final bool b => b ? 'True' : 'False',
  // The non-finite guards MUST come before the `int` arm. On dart2js
  // `double.infinity is int` is **true** (the check is essentially
  // `Math.floor(x) === x`, and that holds for the infinities), so with the
  // `int` arm first an infinite input rendered as `f = Infinity` — a NameError
  // in Python — while the VM emitted `float('inf')`. These two guards are
  // value-based rather than type-based, which is why reordering fixes them
  // where it cannot fix the integral case below.
  final double d when d.isNaN => "float('nan')",
  final double d when d.isInfinite => d < 0 ? "float('-inf')" : "float('inf')",
  final int n => '$n',
  // Reached only on the VM. On dart2js `4.0 is int` is true, so an integral
  // double is consumed by the `int` arm above and arrives in Python as an
  // `int` — see [exactDoubleText] and core#137. That is NOT fixable here: the
  // parameter is `Object?`, and dart2js has already destroyed the distinction
  // between `4` and `4.0` before this function is entered. Only the caller can
  // still express it.
  final double d => exactDoubleText(d),
  final String s => _escapePythonString(s),
  final List<Object?> l => '[${l.map(toPythonLiteral).join(', ')}]',
  final Map<Object?, Object?> m =>
    '{${m.entries.map(_mapEntryLiteral).join(', ')}}',
  _ => throw ArgumentError(
    'Cannot convert ${value.runtimeType} to Python literal',
  ),
};

/// Matches a Python identifier, approximating CPython's `XID_Start` /
/// `XID_Continue`.
///
/// Unicode is allowed on purpose: Python 3 accepts `café` as an identifier, so
/// an ASCII-only rule would reject keys that work today. What this rejects is
/// everything that is not an identifier at all — whitespace, newlines,
/// operators, quotes, semicolons and NUL — which is the whole of the injection
/// surface.
final _identifier = RegExp(
  r'^[\p{L}\p{Nl}_][\p{L}\p{Nl}\p{Mn}\p{Mc}\p{Nd}\p{Pc}]*$',
  unicode: true,
);

/// Generates Python assignment statements from [inputs].
///
/// Returns an empty string when [inputs] is empty. Values are converted via
/// [toPythonLiteral].
///
/// ```dart
/// inputsToCode({'x': 10, 'name': 'Alice'})
/// // returns "x = 10\nname = 'Alice'"
/// ```
///
/// **Each key must be a valid Python identifier, and this is now enforced.**
/// It was documented here and never checked, while the key was interpolated
/// into program text raw — so a key was a working code-injection primitive
/// (core#137):
///
/// ```dart
/// // executed as Python, before this check existed:
/// inputsToCode({'ignored = 0\nanswer = "INJECTED"\nz': 1})
/// ```
///
/// Rejecting is the G2-correct response rather than sanitising: a key that is
/// not an identifier cannot express what the caller meant, so silently
/// rewriting it would substitute our guess for their intent.
///
/// This is a **guard, not a boundary.** Two things survive it, and they are
/// different problems:
///
/// - **The value still round-trips through source text.** An escaping bug here
///   is a code-execution bug, and a NUL in a value truncates the whole program
///   at the C boundary (FB-6). Binding inputs as VALUES retires this class; it
///   is blocked on the REPL handle having no name-lookup support (FB-5).
/// - **A bound name shadows whatever it collides with** — `{'print': 1}` makes
///   `print("x")` raise `TypeError`. Value-binding does **not** help: shadowing
///   is what binding a name into a scope means, however the pair arrives.
///   Retiring it would take a builtin denylist or a non-shadowing namespace,
///   and neither is obviously right — `print = 1` is legal Python, and a caller
///   who asks for that name may mean it.
///
/// Throws [ArgumentError] if a key is not a valid Python identifier, or if any
/// value cannot be converted.
String inputsToCode(Map<String, Object?> inputs) {
  if (inputs.isEmpty) return '';

  return inputs.entries
      .map((e) {
        if (!_identifier.hasMatch(e.key)) {
          throw ArgumentError.value(
            e.key,
            'inputs',
            'input names are interpolated into Python source, so each '
                'must be a valid Python identifier',
          );
        }

        return '${e.key} = ${toPythonLiteral(e.value)}';
      })
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
