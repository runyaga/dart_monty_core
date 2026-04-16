import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/monty_limits.dart';
import 'package:dart_monty_core/src/platform/monty_platform.dart';
import 'package:dart_monty_core/src/platform/monty_progress.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';
import 'package:dart_monty_core/src/repl/monty_repl.dart';

/// Adapts [MontyRepl] to the [MontyPlatform] interface.
///
/// This allows `MontyRepl` to be used anywhere a [MontyPlatform] is
/// expected — for example with `MontySession` — while keeping REPL heap
/// state (variables, functions, classes) persistent across calls.
///
/// ```dart
/// final repl = MontyRepl();
/// final platform = ReplPlatform(repl: repl);
/// final session = MontySession(platform: platform);
/// await session.run('x = 42');
/// await repl.dispose();
/// ```
class ReplPlatform implements MontyPlatform {
  /// Creates a [ReplPlatform] wrapping [repl].
  const ReplPlatform({required MontyRepl repl}) : _repl = repl;

  final MontyRepl _repl;

  @override
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) => _repl.feed(code);

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) => _repl.feedStart(code, externalFunctions: externalFunctions);

  @override
  Future<MontyProgress> resume(Object? returnValue) =>
      _repl.resume(returnValue);

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) =>
      _repl.resumeWithError(errorMessage);

  @override
  Future<MontyProgress> resumeWithException(
    String excType,
    String errorMessage,
  ) =>
      // REPL does not yet support typed exceptions — fall back to RuntimeError.
      _repl.resumeWithError(errorMessage);

  @override
  Future<MontyProgress> resumeNameLookup(String name, Object? value) =>
      throw UnsupportedError('NameLookup not supported by ReplPlatform');

  @override
  Future<MontyProgress> resumeNameLookupUndefined(String name) =>
      throw UnsupportedError('NameLookup not supported by ReplPlatform');

  @override
  Future<Uint8List> compileCode(String code) =>
      throw UnsupportedError('compileCode() is not supported by ReplPlatform');

  @override
  Future<MontyResult> runPrecompiled(
    Uint8List compiled, {
    MontyLimits? limits,
    String? scriptName,
  }) => throw UnsupportedError(
    'runPrecompiled() is not supported by ReplPlatform',
  );

  @override
  Future<MontyProgress> startPrecompiled(
    Uint8List compiled, {
    MontyLimits? limits,
    String? scriptName,
  }) => throw UnsupportedError(
    'startPrecompiled() is not supported by ReplPlatform',
  );

  @override
  Future<void> dispose() => _repl.dispose();
}
