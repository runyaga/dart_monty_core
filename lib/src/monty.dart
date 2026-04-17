import 'dart:typed_data';

import 'package:dart_monty_core/src/externals.dart';
import 'package:dart_monty_core/src/monty_factory.dart';
import 'package:dart_monty_core/src/monty_session.dart';
import 'package:dart_monty_core/src/platform/monty_limits.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';

/// Monty sandboxed Python interpreter.
///
/// All Python state — variables, functions, classes, and module objects —
/// persists natively across [run] calls via the Rust REPL heap. No JSON
/// serialisation overhead, and two-call import patterns work naturally:
///
/// ```dart
/// final monty = Monty();
/// await monty.run('import pathlib');
/// final r = await monty.run('pathlib.Path("/data/f.txt").read_text()');
/// await monty.dispose();
/// ```
///
/// For one-shot evaluation:
/// ```dart
/// final result = await Monty.exec('2 + 2');
/// ```
///
/// To enable filesystem/environment/datetime access, provide an
/// [OsCallHandler]:
/// ```dart
/// final monty = Monty(osHandler: myOsCallHandler);
/// ```
class Monty {
  /// Creates a Monty interpreter with the auto-detected backend.
  ///
  /// [scriptName] is used as the filename in tracebacks and error messages.
  ///
  /// Pass [osHandler] to enable Python `pathlib`, `os`, and `datetime`
  /// access. Without it, OS calls resume with a permission error.
  factory Monty({
    OsCallHandler? osHandler,
    String scriptName = 'main.py',
  }) => Monty._(MontySession(osHandler: osHandler, scriptName: scriptName));

  Monty._(MontySession session) : _session = session;

  final MontySession _session;

  /// Executes Python [code] and returns the result.
  ///
  /// Variables, functions, classes, and module imports all persist across
  /// calls via the Rust REPL heap.
  ///
  /// [inputs] injects per-invocation Python variables before [code] runs.
  /// Each key becomes a Python variable; values are converted to Python
  /// literals.
  ///
  /// [limits] and [scriptName] are accepted for API compatibility but ignored
  /// — the REPL uses `NoLimitTracker` and the session-level scriptName.
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
    Map<String, MontyCallback> externals = const {},
    Map<String, Object?>? inputs,
  }) => _session.run(
    code,
    limits: limits,
    scriptName: scriptName,
    externals: externals,
    inputs: inputs,
  );

  /// Captures JSON-serialisable Python globals as a portable snapshot.
  ///
  /// Returns a self-contained binary snapshot. Pass to [restore] on the same
  /// or a new [Monty] instance to recreate the Python variable state.
  ///
  /// Functions, classes, and module objects are excluded (not serialisable).
  ///
  /// **Note on external functions:** [MontyCallback] closures cannot be
  /// serialised. Re-provide them in subsequent [run] calls after [restore].
  Future<Uint8List> snapshot() => _session.snapshot();

  /// Restores Python variables from a snapshot produced by [snapshot].
  ///
  /// The next [run] call will inject the restored variables. Throws
  /// [ArgumentError] if [bytes] is not a valid snapshot.
  void restore(Uint8List bytes) => _session.restore(bytes);

  /// Clears all persisted state.
  ///
  /// After calling this, the next [run] starts with empty globals.
  void clearState() => _session.clearState();

  /// Releases all resources.
  Future<void> dispose() async => _session.dispose();

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
  /// any session state. For stateful execution use [run] instead.
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

  /// One-shot evaluation — creates, runs, disposes automatically.
  ///
  /// Stateless — no variable persistence across calls.
  ///
  /// ```dart
  /// final result = await Monty.exec('2 + 2');
  /// ```
  static Future<MontyResult> exec(
    String code, {
    MontyLimits? limits,
    String? scriptName,
    OsCallHandler? osHandler,
    Map<String, Object?>? inputs,
  }) async {
    final monty = Monty(osHandler: osHandler);
    try {
      return await monty.run(
        code,
        limits: limits,
        scriptName: scriptName,
        inputs: inputs,
      );
    } finally {
      await monty.dispose();
    }
  }
}
