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
  /// Pass [osHandler] to enable Python `pathlib`, `os`, and `datetime`
  /// access. Without it, OS calls resume with a permission error.
  factory Monty({OsCallHandler? osHandler}) =>
      Monty._(createPlatformMonty(), osHandler);

  /// Creates a Monty interpreter with an explicit platform backend.
  factory Monty.withPlatform(
    MontyPlatform platform, {
    OsCallHandler? osHandler,
  }) => Monty._(platform, osHandler);

  Monty._(MontyPlatform platform, OsCallHandler? osHandler)
    : _platform = platform,
      _session = MontySession(platform: platform, osHandler: osHandler);

  final MontyPlatform _platform;
  final MontySession _session;

  /// The underlying platform — for advanced use (iterative start/resume).
  MontyPlatform get platform => _platform;

  /// The current persisted state as a JSON-decoded map.
  Map<String, Object?> get state => _session.state;

  /// Executes Python [code] and returns the result.
  ///
  /// Variables defined in [code] persist for subsequent [run] calls.
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
    scriptName: scriptName,
    externals: externals,
    inputs: inputs,
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
