import 'dart:typed_data';

import 'package:dart_monty_core/src/externals.dart';
import 'package:dart_monty_core/src/monty_factory.dart';
import 'package:dart_monty_core/src/monty_session.dart';
import 'package:dart_monty_core/src/platform/monty_limits.dart';
import 'package:dart_monty_core/src/platform/monty_platform.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';

/// Monty sandboxed Python interpreter.
///
/// Variables persist across [run] calls:
/// ```dart
/// final monty = Monty();
/// await monty.run('x = 42');
/// await monty.run('y = x * 2');
/// final result = await monty.run('x + y');
/// print(result.value); // MontyInt(126)
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
  /// [scriptName] is used as the default filename in tracebacks and error
  /// messages. It can be overridden per-call in [run]. Equivalent to the
  /// `scriptName` option in the JS `@pydantic/monty` SDK.
  ///
  /// Pass [osHandler] to enable Python `pathlib`, `os`, and `datetime`
  /// access. Without it, OS calls resume with a permission error.
  factory Monty({
    OsCallHandler? osHandler,
    String scriptName = 'main.py',
  }) => Monty._(createPlatformMonty(), osHandler, scriptName);

  /// Creates a Monty interpreter with an explicit platform backend.
  factory Monty.withPlatform(
    MontyPlatform platform, {
    OsCallHandler? osHandler,
    String scriptName = 'main.py',
  }) => Monty._(platform, osHandler, scriptName);

  Monty._(MontyPlatform platform, OsCallHandler? osHandler, String scriptName)
    : _platform = platform,
      _scriptName = scriptName,
      _session = MontySession(platform: platform, osHandler: osHandler);

  final MontyPlatform _platform;
  final MontySession _session;

  /// The default script name used in tracebacks for this session.
  final String _scriptName;

  /// The underlying platform — for advanced use (iterative start/resume).
  MontyPlatform get platform => _platform;

  /// The current persisted state as a JSON-decoded map.
  Map<String, Object?> get state => _session.state;

  /// Executes Python [code] and returns the result.
  ///
  /// Variables defined in [code] persist for subsequent [run] calls.
  ///
  /// [scriptName] overrides the constructor's default for this call only.
  ///
  /// [inputs] injects per-invocation Python variables before [code] runs.
  /// Each key becomes a Python variable; values are converted to Python
  /// literals. Inputs are **not persisted** across calls.
  ///
  /// Throws [ArgumentError] if any value in [inputs] cannot be converted.
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
    Map<String, MontyCallback> externals = const {},
    Map<String, Object?>? inputs,
  }) => _session.run(
    code,
    limits: limits,
    scriptName: scriptName ?? _scriptName,
    externals: externals,
    inputs: inputs,
  );

  /// Executes pre-compiled [compiled] bytes and returns the result.
  ///
  /// Pre-compiled bytes are obtained from [compile]. Running pre-compiled
  /// code avoids re-parsing on repeated executions of the same script.
  ///
  /// State is **not** preserved across [runPrecompiled] calls. For stateful
  /// execution, use [run] instead.
  ///
  /// On WASM, throws [UnsupportedError] — snapshot support requires a
  /// future update to the WASM JS bridge.
  Future<MontyResult> runPrecompiled(
    Uint8List compiled, {
    MontyLimits? limits,
    String? scriptName,
  }) => _session.runPrecompiled(
    compiled,
    limits: limits,
    scriptName: scriptName,
  );

  /// Clears all persisted state.
  ///
  /// After calling this, the next [run] starts with empty globals.
  void clearState() => _session.clearState();

  /// Releases all resources.
  Future<void> dispose() async {
    _session.dispose();
    await _platform.dispose();
  }

  /// Compiles [code] and returns the bytecode as a binary blob.
  ///
  /// Use [runPrecompiled] or [MontySession.runPrecompiled] to execute the
  /// result. Pre-compiling avoids re-parsing on repeated executions of the
  /// same script.
  ///
  /// Equivalent to `Monty.dump()` in the JS `@pydantic/monty` SDK.
  ///
  /// On WASM, throws [UnsupportedError] — snapshot support requires a
  /// future update to the WASM JS bridge.
  ///
  /// ```dart
  /// final binary = await Monty.compile('x * 2 + y');
  /// // Run the same compiled code with different inputs:
  /// final r1 = await session.runPrecompiled(binary);
  /// ```
  static Future<Uint8List> compile(String code) async {
    final platform = createPlatformMonty();
    try {
      return await platform.compileCode(code);
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
