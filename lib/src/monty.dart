import 'dart:typed_data';

import 'package:dart_monty_core/src/externals.dart';
import 'package:dart_monty_core/src/monty_factory.dart';
import 'package:dart_monty_core/src/monty_session.dart';
import 'package:dart_monty_core/src/platform/monty_limits.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';

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
/// For one-shot execution that does not need to be reused, [Monty.exec] is
/// a static convenience.
///
/// For stateful execution (variables, functions, classes, imports
/// accumulating across runs) use [MontySession] instead.
class Monty {
  /// Holds [code] as a Python program.
  ///
  /// [scriptName] is used as the filename in tracebacks and error messages.
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
  /// [inputs] are converted to Python literals and prepended to the code
  /// as assignments; they shadow same-named variables for that call only.
  /// [externalFunctions] maps Python-callable names to Dart callbacks;
  /// Python can call them like any other function and the result is
  /// resumed automatically.
  ///
  /// Each call runs in a fresh interpreter — state from earlier calls does
  /// not persist. Use [MontySession] for stateful execution.
  Future<MontyResult> run({
    Map<String, Object?>? inputs,
    Map<String, MontyCallback> externalFunctions = const {},
    MontyLimits? limits,
    OsCallHandler? osHandler,
  }) async {
    final session = MontySession(
      osHandler: osHandler,
      scriptName: _scriptName,
    );
    try {
      return await session.run(
        _code,
        externalFunctions: externalFunctions,
        inputs: inputs,
        limits: limits,
      );
    } finally {
      session.dispose();
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
  /// Creates a temporary backend, runs once, and disposes. Does not affect
  /// any session state.
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

  /// One-shot evaluation — wraps [Monty] + [run] for code that runs once.
  ///
  /// ```dart
  /// final result = await Monty.exec('2 + 2');
  /// ```
  static Future<MontyResult> exec(
    String code, {
    Map<String, Object?>? inputs,
    Map<String, MontyCallback> externalFunctions = const {},
    MontyLimits? limits,
    String scriptName = 'main.py',
    OsCallHandler? osHandler,
  }) => Monty(code, scriptName: scriptName).run(
    inputs: inputs,
    externalFunctions: externalFunctions,
    limits: limits,
    osHandler: osHandler,
  );
}
