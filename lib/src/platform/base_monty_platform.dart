import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/core_bindings.dart';
import 'package:dart_monty_core/src/platform/monty_error.dart';
import 'package:dart_monty_core/src/platform/monty_exception.dart';
import 'package:dart_monty_core/src/platform/monty_limits.dart';
import 'package:dart_monty_core/src/platform/monty_platform.dart';
import 'package:dart_monty_core/src/platform/monty_progress.dart';
import 'package:dart_monty_core/src/platform/monty_resource_usage.dart';
import 'package:dart_monty_core/src/platform/monty_result.dart';
import 'package:dart_monty_core/src/platform/monty_stack_frame.dart';
import 'package:dart_monty_core/src/platform/monty_state_mixin.dart';
import 'package:dart_monty_core/src/platform/monty_value.dart';
import 'package:meta/meta.dart';

typedef _ErrorInfo = ({
  String message,
  String? excType,
  List<dynamic>? traceback,
  String? filename,
  int? lineNumber,
  int? columnNumber,
  String? sourceCode,
});

List<MontyStackFrame> _parseTraceback(List<dynamic>? traceback) {
  if (traceback == null) return const [];

  return MontyStackFrame.listFromJson(traceback);
}

List<MontyValue> _parseArgList(List<dynamic>? args) =>
    args != null ? args.map(MontyValue.fromJson).toList() : const [];

Map<String, MontyValue>? _parseKwargMap(Map<String, dynamic>? kwargs) =>
    kwargs?.map((k, v) => MapEntry(k, MontyValue.fromJson(v)));

String _encodeLimitsJson(MontyLimits? limits) {
  return json.encode({
    'memory_bytes': limits?.memoryBytes ?? BaseMontyPlatform.defaultMemoryBytes,
    'stack_depth': limits?.stackDepth ?? BaseMontyPlatform.defaultStackDepth,
    if (limits?.timeoutMs != null) 'timeout_ms': limits!.timeoutMs,
  });
}

String? _encodeExternalFunctionsJson(List<String>? fns) {
  if (fns == null || fns.isEmpty) return null;

  return json.encode(fns);
}

/// Abstract base that implements [MontyPlatform] by delegating to a
/// [MontyCoreBindings] and translating intermediate results into
/// domain types.
///
/// Subclasses provide a concrete [MontyCoreBindings] adapter and
/// override [backendName]:
///
/// ```dart
/// class MontyFfi extends BaseMontyPlatform {
///   MontyFfi() : super(bindings: FfiCoreBindings());
///   @override
///   String get backendName => 'MontyFfi';
/// }
/// ```
abstract class BaseMontyPlatform extends MontyPlatform with MontyStateMixin {
  /// Creates a [BaseMontyPlatform] backed by [bindings].
  BaseMontyPlatform({required MontyCoreBindings bindings})
    : _bindings = bindings;

  /// Default memory limit: 256 MB.
  static const int defaultMemoryBytes = 256 * 1024 * 1024;

  /// Default stack depth limit: 1000 (matches CPython).
  static const int defaultStackDepth = 1000;

  final MontyCoreBindings _bindings;

  /// The underlying bindings adapter for subclass use.
  @protected
  MontyCoreBindings get coreBindings => _bindings;

  static const _zeroUsage = MontyResourceUsage(
    memoryBytesUsed: 0,
    timeElapsedMs: 0,
    stackDepthUsed: 0,
  );

  bool _initialized = false;

  @override
  Future<MontyResult> run(
    String code, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('run');
    assertIdle('run');
    markActive();
    try {
      await _ensureInitialized();
      final result = await _bindings.run(
        code,
        limitsJson: _encodeLimitsJson(limits),
        scriptName: scriptName,
      );

      return _translateRunResult(result);
    } finally {
      markIdle();
    }
  }

  @override
  Future<MontyProgress> start(
    String code, {
    List<String>? externalFunctions,
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('start');
    assertIdle('start');
    markActive();
    try {
      await _ensureInitialized();
      final progress = await _bindings.start(
        code,
        extFnsJson: _encodeExternalFunctionsJson(externalFunctions),
        limitsJson: _encodeLimitsJson(limits),
        scriptName: scriptName,
      );

      return translateProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  @override
  Future<MontyProgress> resume(Object? returnValue) async {
    assertNotDisposed('resume');
    assertActive('resume');
    try {
      final progress = await _bindings.resume(json.encode(returnValue));

      return translateProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  @override
  Future<MontyProgress> resumeWithError(String errorMessage) async {
    assertNotDisposed('resumeWithError');
    assertActive('resumeWithError');
    try {
      final progress = await _bindings.resumeWithError(errorMessage);

      return translateProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  @override
  Future<MontyProgress> resumeWithException(
    String excType,
    String errorMessage,
  ) async {
    assertNotDisposed('resumeWithException');
    assertActive('resumeWithException');
    try {
      final progress = await _bindings.resumeWithException(
        excType,
        errorMessage,
      );

      return translateProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  @override
  Future<MontyProgress> resumeNotFound(String fnName) async {
    assertNotDisposed('resumeNotFound');
    assertActive('resumeNotFound');
    try {
      final progress = await _bindings.resumeNotFound(fnName);

      return translateProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  @override
  Future<Uint8List> compileCode(String code) async {
    assertNotDisposed('compileCode');
    await _ensureInitialized();
    try {
      return await _bindings.compileCode(code);
    } on MontyScriptError catch (e) {
      if (e.excType == 'SyntaxError') {
        throw MontySyntaxError(
          e.message,
          excType: e.excType,
          exception: e.exception,
        );
      }

      rethrow;
    }
  }

  @override
  Future<String?> typeCheck(
    String code, {
    String? prefixCode,
    String scriptName = 'main.py',
  }) async {
    assertNotDisposed('typeCheck');
    await _ensureInitialized();

    return _bindings.typeCheck(
      code,
      prefixCode: prefixCode,
      scriptName: scriptName,
    );
  }

  @override
  Future<MontyResult> runPrecompiled(
    Uint8List compiled, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('runPrecompiled');
    assertIdle('runPrecompiled');
    markActive();
    try {
      await _ensureInitialized();
      final result = await _bindings.runPrecompiled(
        compiled,
        limitsJson: _encodeLimitsJson(limits),
        scriptName: scriptName,
      );

      return _translateRunResult(result);
    } finally {
      markIdle();
    }
  }

  @override
  Future<MontyProgress> startPrecompiled(
    Uint8List compiled, {
    MontyLimits? limits,
    String? scriptName,
  }) async {
    assertNotDisposed('startPrecompiled');
    assertIdle('startPrecompiled');
    markActive();
    try {
      await _ensureInitialized();
      final progress = await _bindings.startPrecompiled(
        compiled,
        limitsJson: _encodeLimitsJson(limits),
        scriptName: scriptName,
      );

      return translateProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  @override
  Future<void> dispose() async {
    if (isDisposed) return;
    // Force idle if active — allows dispose during test teardown and
    // crash-recovery scenarios. The in-flight operation will fail on
    // next resume (handle already freed).
    if (isActive) markIdle();
    await _bindings.dispose();
    markDisposed();
  }

  /// Translates a [CoreProgressResult] into a [MontyProgress] domain type.
  @protected
  MontyProgress translateProgress(CoreProgressResult p) {
    switch (p.state) {
      case 'complete':
        return _buildComplete(p);
      case 'pending':
        return _buildPending(p);
      case 'os_call':
        return _buildOsCall(p);
      case 'resolve_futures':
        markActive();

        return MontyResolveFutures(
          pendingCallIds: p.pendingCallIds ?? const [],
        );
      case 'name_lookup':
        markActive();

        return MontyNameLookup(variableName: p.variableName ?? '');
      case 'error':
        markIdle();
        _throwError((
          message: p.error ?? 'Unknown error',
          excType: p.excType,
          traceback: p.traceback,
          filename: p.filename,
          lineNumber: p.lineNumber,
          columnNumber: p.columnNumber,
          sourceCode: p.sourceCode,
        ));
      default:
        markIdle();
        throw StateError('Unknown progress state: ${p.state}');
    }
  }

  /// Resumes a name lookup by providing [value] for [name].
  @override
  Future<MontyProgress> resumeNameLookup(
    String name,
    Object? value,
  ) async {
    assertNotDisposed('resumeNameLookup');
    assertActive('resumeNameLookup');
    try {
      final progress = await _bindings.resumeNameLookupValue(
        json.encode(value),
      );

      return translateProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  /// Resumes a name lookup indicating [name] is undefined (raises NameError).
  @override
  Future<MontyProgress> resumeNameLookupUndefined(String name) async {
    assertNotDisposed('resumeNameLookupUndefined');
    assertActive('resumeNameLookupUndefined');
    try {
      final progress = await _bindings.resumeNameLookupUndefined();

      return translateProgress(progress);
    } catch (e) {
      markIdle();
      rethrow;
    }
  }

  // -- Private translation helpers --

  Future<void> _ensureInitialized() async {
    if (!_initialized) {
      await _bindings.init();
      _initialized = true;
    }
  }

  MontyResult _translateRunResult(CoreRunResult r) {
    if (r.ok) {
      return MontyResult(
        value: MontyValue.fromJson(r.value),
        error: _buildError(r.error, r.excType, r.traceback),
        usage: r.usage ?? _zeroUsage,
        printOutput: r.printOutput,
      );
    }
    _throwError((
      message: r.error ?? 'Unknown error',
      excType: r.excType,
      traceback: r.traceback,
      filename: r.filename,
      lineNumber: r.lineNumber,
      columnNumber: r.columnNumber,
      sourceCode: r.sourceCode,
    ));
  }

  MontyException? _buildError(
    String? error,
    String? excType,
    List<dynamic>? traceback,
  ) {
    if (error == null) return null;

    return MontyException(
      message: error,
      excType: excType,
      traceback: _parseTraceback(traceback),
    );
  }

  MontyComplete _buildComplete(CoreProgressResult p) {
    markIdle();

    return MontyComplete(
      result: MontyResult(
        value: MontyValue.fromJson(p.value),
        error: _buildError(p.error, p.excType, p.traceback),
        usage: p.usage ?? _zeroUsage,
        printOutput: p.printOutput,
      ),
    );
  }

  MontyPending _buildPending(CoreProgressResult p) {
    markActive();

    return MontyPending(
      functionName: p.functionName ?? '',
      arguments: _parseArgList(p.arguments),
      kwargs: _parseKwargMap(p.kwargs),
      callId: p.callId ?? 0,
      methodCall: p.methodCall ?? false,
    );
  }

  MontyOsCall _buildOsCall(CoreProgressResult p) {
    markActive();

    return MontyOsCall(
      operationName: p.functionName ?? '',
      arguments: _parseArgList(p.arguments),
      kwargs: _parseKwargMap(p.kwargs),
      callId: p.callId ?? 0,
    );
  }

  /// Throws the appropriate sealed [MontyError] subtype for a failed run.
  ///
  /// Resource errors (`MemoryLimitExceeded`) throw [MontyResourceError].
  /// Syntax errors (`SyntaxError`) throw [MontySyntaxError].
  /// All other Python exceptions throw [MontyScriptError] wrapping a full
  /// [MontyException] with traceback and source location details.
  Never _throwError(_ErrorInfo e) {
    if (e.excType == 'MemoryLimitExceeded') throw MontyResourceError(e.message);
    final exception = MontyException(
      message: e.message,
      excType: e.excType,
      traceback: _parseTraceback(e.traceback),
      filename: e.filename,
      lineNumber: e.lineNumber,
      columnNumber: e.columnNumber,
      sourceCode: e.sourceCode,
    );
    if (e.excType == 'SyntaxError') {
      throw MontySyntaxError(
        e.message,
        excType: e.excType,
        exception: exception,
      );
    }
    throw MontyScriptError(e.message, excType: e.excType, exception: exception);
  }
}
