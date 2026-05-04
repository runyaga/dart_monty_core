import 'dart:typed_data';

import 'package:dart_monty_core/src/externals.dart';
import 'package:dart_monty_core/src/monty_factory.dart';
import 'package:dart_monty_core/src/platform/monty_limits.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';
import 'package:dart_monty_core/src/platform/monty_typing_error.dart';
import 'package:dart_monty_core/src/repl/monty_repl.dart';

/// A compiled Python program.
///
/// `Monty(code)` holds a Python source string; subsequent calls to [run]
/// execute it with different inputs. Each [run] runs in a fresh
/// interpreter — state from earlier calls does not persist. Mirrors the
/// reference `pydantic_monty.Monty(code).run(...)` shape.
///
/// ```dart
/// final program = Monty('x * 2');
/// final r = await program.run(inputs: {'x': 21});
/// print(r.value); // MontyInt(42)
/// ```
///
/// For one-shot execution that does not need to be reused, [Monty.exec]
/// is a static convenience.
///
/// For stateful execution (variables, functions, classes, imports
/// accumulating across runs) use [MontyRepl] instead.
class Monty {
  /// Holds [code] as a Python program.
  ///
  /// [scriptName] is used as the filename in tracebacks and error
  /// messages.
  factory Monty(String code, {String scriptName = 'main.py'}) =>
      Monty._(code: code, scriptName: scriptName);

  Monty._({required String code, required String scriptName})
    : _code = code,
      _scriptName = scriptName;

  final String _code;
  final String _scriptName;

  /// Script name used as the filename in tracebacks and error messages.
  String get scriptName => _scriptName;

  /// Runs the held code with optional [inputs], [externalFunctions],
  /// [limits], and [osHandler].
  ///
  /// [inputs] are converted to Python literals and prepended to the
  /// code as assignments; they shadow same-named variables for that
  /// call only. [externalFunctions] maps Python-callable names to Dart
  /// callbacks; Python can call them like any other function and the
  /// result is resumed automatically.
  ///
  /// Each call runs in a fresh interpreter — state from earlier calls
  /// does not persist. Use [MontyRepl] for stateful execution.
  ///
  /// Python-level exceptions land in [MontyResult.error] rather than
  /// throwing, matching the reference Python class. Binding-level
  /// failures (e.g. resource limits) still throw.
  Future<MontyResult> run({
    Map<String, Object?>? inputs,
    Map<String, MontyCallback> externalFunctions = const {},
    Map<String, MontyCallback> externalAsyncFunctions = const {},
    MontyLimits? limits,
    OsCallHandler? osHandler,
    void Function(String stream, String text)? printCallback,
  }) async {
    final repl = MontyRepl(scriptName: _scriptName);
    try {
      return await repl.feedRun(
        _code,
        externalFunctions: externalFunctions,
        externalAsyncFunctions: externalAsyncFunctions,
        osHandler: osHandler,
        inputs: inputs,
        printCallback: printCallback,
      );
    } finally {
      await repl.dispose();
    }
  }

  /// Compiles [code] and returns the bytecode as a binary blob.
  ///
  /// Use [runPrecompiled] to execute the result. Pre-compiling avoids
  /// re-parsing on repeated executions of the same script.
  static Future<Uint8List> compile(String code) async {
    final platform = createPlatformMonty();
    try {
      return await platform.compileCode(code);
    } finally {
      await platform.dispose();
    }
  }

  /// Runs pre-compiled bytecode from [compile] in a stateless context.
  ///
  /// Creates a temporary backend, runs once, and disposes. Does not
  /// affect any session state.
  static Future<MontyResult> runPrecompiled(
    Uint8List compiled, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    final platform = createPlatformMonty();
    try {
      return await platform.runPrecompiled(
        compiled,
        limits: limits,
        scriptName: scriptName,
      );
    } finally {
      await platform.dispose();
    }
  }

  /// Runs static type checking on [code] without executing it.
  ///
  /// Returns the list of typing diagnostics — empty when the code
  /// type-checks cleanly. Stateless: uses an isolated analysis heap
  /// scrubbed on completion, so it never touches an in-flight execution.
  ///
  /// [prefixCode] is prepended before checking — useful for declaring
  /// inputs or external function signatures so the analyser knows their
  /// types. [scriptName] sets the filename surfaced in diagnostic spans.
  ///
  /// ```dart
  /// final errors = await Monty.typeCheck('x: int = "not an int"');
  /// for (final e in errors) {
  ///   print('${e.path}:${e.line}:${e.column} ${e.code}: ${e.message}');
  /// }
  /// ```
  static Future<List<MontyTypingError>> typeCheck(
    String code, {
    String? prefixCode,
    String scriptName = 'main.py',
  }) async {
    final platform = createPlatformMonty();
    try {
      final json = await platform.typeCheck(
        code,
        prefixCode: prefixCode,
        scriptName: scriptName,
      );

      return MontyTypingError.listFromJson(json);
    } finally {
      await platform.dispose();
    }
  }

  /// One-shot evaluation — wraps [Monty] + [run] for code that runs once.
  ///
  /// ```dart
  /// final result = await Monty.exec('2 + 2');
  /// ```
  static Future<MontyResult> exec(
    String code, {
    Map<String, Object?>? inputs,
    Map<String, MontyCallback> externalFunctions = const {},
    Map<String, MontyCallback> externalAsyncFunctions = const {},
    MontyLimits? limits,
    String scriptName = 'main.py',
    OsCallHandler? osHandler,
    void Function(String stream, String text)? printCallback,
  }) => Monty(code, scriptName: scriptName).run(
    inputs: inputs,
    externalFunctions: externalFunctions,
    externalAsyncFunctions: externalAsyncFunctions,
    limits: limits,
    osHandler: osHandler,
    printCallback: printCallback,
  );
}
