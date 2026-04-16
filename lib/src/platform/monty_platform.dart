import 'package:dart_monty_core/src/platform/monty_limits.dart';
import 'package:dart_monty_core/src/platform/monty_progress.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';

/// The platform interface for the Monty sandboxed Python interpreter.
///
/// {@category Core}
///
/// Platform implementations (FFI, Web) extend this class to provide
/// concrete behavior.
///
/// See also:
/// - `MontyFfi` — native FFI implementation
/// - `MontyWasm` — web WASM implementation
abstract class MontyPlatform {
  /// Executes [code] and returns the result.
  ///
  /// Optionally pass [limits] to constrain resource usage, and
  /// [scriptName] to identify the script in error messages and tracebacks.
  ///
  /// ```dart
  /// final result = await platform.run(
  ///   'x + 1',
  ///   scriptName: 'math_helper.py',
  /// );
  /// ```
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) {
    throw UnimplementedError('run() has not been implemented.');
  }

  /// Starts a multi-step execution of [code].
  ///
  /// When the code calls an external function listed in
  /// [externalFunctions], execution pauses and returns a [MontyPending]
  /// progress. Use [resume] or [resumeWithError] to continue.
  ///
  /// Pass [scriptName] to identify this script in error tracebacks
  /// and exception filename fields. Useful for multi-script pipelines
  /// where each script needs distinct error attribution.
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) {
    throw UnimplementedError('start() has not been implemented.');
  }

  /// Resumes a paused execution with the given [returnValue].
  Future<MontyProgress> resume(Object? returnValue) {
    throw UnimplementedError('resume() has not been implemented.');
  }

  /// Resumes a paused execution by raising an error with [errorMessage].
  Future<MontyProgress> resumeWithError(String errorMessage) {
    throw UnimplementedError('resumeWithError() has not been implemented.');
  }

  /// Resumes a paused execution by raising a typed Python [excType] exception
  /// with [errorMessage]. Unknown [excType] names fall back to RuntimeError.
  Future<MontyProgress> resumeWithException(
    String excType,
    String errorMessage,
  ) {
    throw UnimplementedError('resumeWithException() has not been implemented.');
  }

  /// Resumes a name lookup by providing [value] for [name].
  Future<MontyProgress> resumeNameLookup(String name, Object? value) {
    throw UnimplementedError('resumeNameLookup() has not been implemented.');
  }

  /// Resumes a name lookup by indicating [name] is undefined.
  ///
  /// The engine raises NameError.
  Future<MontyProgress> resumeNameLookupUndefined(String name) {
    throw UnimplementedError(
      'resumeNameLookupUndefined() has not been implemented.',
    );
  }

  /// Releases resources held by this interpreter instance.
  Future<void> dispose() {
    throw UnimplementedError('dispose() has not been implemented.');
  }
}
