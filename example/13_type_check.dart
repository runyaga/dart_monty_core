// 13 — Static type checking via Monty.typeCheck
//
// Monty ships a static analyser (a subset of Python's type system) that
// reports type errors without executing the code. Useful for IDE-shaped
// integrations: surface errors before the user clicks Run.
//
// The analyser uses a separate, pooled in-memory database scrubbed on
// drop, so it never touches an in-flight Monty.run / MontyRepl.feedRun
// execution heap.
//
// Covers: Monty.typeCheck, MontyTypingError (code, message, path,
//         line, column, url), prefixCode for input declarations.
//
// Run: dart run example/13_type_check.dart

import 'package:dart_monty_core/dart_monty_core.dart';

Future<void> main() async {
  await _cleanCode();
  await _annotatedMistake();
  await _inferenceWithoutAnnotations();
  await _prefixCodeForInputs();
  await _multipleDiagnostics();
}

// ── Clean code returns an empty list ─────────────────────────────────────────
// No diagnostics → `Monty.typeCheck` resolves to an empty `List<MontyTypingError>`.
Future<void> _cleanCode() async {
  print('\n── clean code ──');
  final errors = await Monty.typeCheck('x: int = 1\ny: int = x + 1');
  print('errors: ${errors.length}'); // 0
}

// ── Annotated mismatch flagged precisely ─────────────────────────────────────
// Each diagnostic carries a code (`invalid-assignment`), a message, the
// file path, and 1-indexed line/column — enough for an editor to render
// the error inline.
Future<void> _annotatedMistake() async {
  print('\n── annotated mistake ──');
  const code = 'x: int = "not an int"';
  final errors = await Monty.typeCheck(code, scriptName: 'incompat.py');
  for (final e in errors) {
    print('${e.path}:${e.line}:${e.column}  ${e.code}: ${e.message}');
    if (e.url != null) print('  doc: ${e.url}');
  }
}

// ── Inference catches obvious clashes even without annotations ───────────────
// `"a" + 1` is flagged as `unsupported-operator` because the analyser
// infers literal types eagerly. This means many real-world bugs are
// caught even when the user hasn't added annotations.
Future<void> _inferenceWithoutAnnotations() async {
  print('\n── inference (no annotations) ──');
  final errors = await Monty.typeCheck('x = "anything"\ny = x + 1');
  for (final e in errors) {
    print('  ${e.code}: ${e.message}');
  }
}

// ── prefixCode declares names visible to the analyser ────────────────────────
// Use prefixCode to inject `inputs` declarations or external function
// signatures so the analyser knows their types. Without it, references
// to those names look unresolved.
Future<void> _prefixCodeForInputs() async {
  print('\n── prefixCode ──');

  const main = 'doubled: int = x * 2';

  final without = await Monty.typeCheck(main);
  print('without prefixCode: ${without.length} errors');

  final with_ = await Monty.typeCheck(main, prefixCode: 'x: int = 0');
  print('with prefixCode:    ${with_.length} errors');
}

// ── Multiple diagnostics arrive sorted by line ───────────────────────────────
Future<void> _multipleDiagnostics() async {
  print('\n── multiple diagnostics ──');
  const code = '''
a: int = "first"
b: int = "second"
c: int = "third"
''';
  final errors = await Monty.typeCheck(code);
  for (final e in errors) {
    print('  line ${e.line}: ${e.message}');
  }
}
