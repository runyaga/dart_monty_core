import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/monty_core_bindings.dart';
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
import 'package:dart_monty_core/src/platform/wire_json.dart';
import 'package:meta/meta.dart';

typedef _ErrorInfo = ({
  String message,
  String? excType,
  List<Object?>? traceback,
  String? filename,
  int? lineNumber,
  int? columnNumber,
  String? sourceCode,
});

List<MontyStackFrame> _parseTraceback(List<Object?>? traceback) {
  if (traceback == null) return const [];

  return MontyStackFrame.listFromJson(traceback);
}

List<MontyValue> _parseArgList(List<Object?>? args) =>
    args != null ? args.map(MontyValue.fromJson).toList() : const [];

Map<String, MontyValue>? _parseKwargMap(Map<String, dynamic>? kwargs) =>
    kwargs?.map((k, v) => MapEntry(k, MontyValue.fromJson(v)));

/// Encodes [limits] as the JSON the native and web backends both accept.
///
/// Shared with `MontyRepl`, which applies limits at session creation, so the
/// two paths cannot disagree about the shape.
String encodeLimitsJson(MontyLimits? limits) {
  final timeoutMs = limits?.timeoutMs;

  return json.encode({
    'memory_bytes': limits?.memoryBytes ?? BaseMontyPlatform.defaultMemoryBytes,
    'stack_depth': limits?.stackDepth ?? BaseMontyPlatform.defaultStackDepth,
    // WAS `if (limits?.timeoutMs != null) 'timeout_ms': limits!.timeoutMs`.
    // The condition does not promote `limits`, which is why the assertion was
    // there. The null-aware element says the same thing with neither.
    'timeout_ms': ?timeoutMs,
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

  /// Default recursion limit, applied whenever a caller omits `stackDepth`.
  ///
  /// NOT CPython's 1000, and the difference is physical rather than stylistic.
  /// Monty's recursion guard is a COUNTER: it raises `RecursionError` after N
  /// nested frames. Reaching N costs real native stack, and this binding runs
  /// the engine IN-PROCESS — an FFI call on a Dart isolate thread, or a wasm32
  /// stack living in linear memory — where upstream runs it in SUBPROCESS
  /// WORKERS with a full main-thread stack. Set this deeper than the stack can
  /// sustain and the stack overflows BEFORE the counter trips:
  ///
  ///     FFI    SIGSEGV — the HOST PROCESS DIES, nothing to catch
  ///     WASM   the module traps (contained, but still a failure)
  ///
  /// This was 1000, "matches CPython", and that is what made five corpus
  /// fixtures kill the host for months — they were quarantined as upstream
  /// monty bugs. They are not: `pydantic-monty 0.0.23`, the tag
  /// native/Cargo.toml pins, raises RecursionError on the same scripts and its
  /// parent survives. monty's own `ResourceLimits::default()` is also 1000
  /// (monty-types/src/resource.rs:105) — correct for a subprocess embedding,
  /// fatal for an in-process one.
  ///
  /// MEASURED by bisecting each recursion shape's crash point, monty v0.0.23,
  /// linux/arm64 (`safe / crash`):
  ///
  ///     cyclic dict == dict     534 / 539   <-- worst case, sets this bound
  ///     cyclic deque == deque   765 / 781
  ///     cyclic list, deep repr, deep hash, heavy Python frames   >= 765
  ///
  /// Cost per frame is NOT uniform — a cyclic dict comparison burns far more
  /// native stack per level than a Python call frame — so the bound is the
  /// minimum across shapes, not the typical one. `ulimit -s` does not help:
  /// 8MB, 64MB and unlimited all segfault identically, because an isolate
  /// thread's stack is fixed at thread creation, not by the process rlimit.
  ///
  /// All three backends agree at 512 and all three fail at 1000. Guarded by
  /// test/integration/ffi_recursion_ceiling_test.dart and its wasm_ twin,
  /// which re-measure rather than trusting these numbers.
  static const int defaultStackDepth = 512;

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
        limitsJson: encodeLimitsJson(limits),
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
        limitsJson: encodeLimitsJson(limits),
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
      final progress = await _bindings.resume(
        WireJson.value(returnValue),
      );

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
        limitsJson: encodeLimitsJson(limits),
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
        limitsJson: encodeLimitsJson(limits),
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
        WireJson.value(value),
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
    List<Object?>? traceback,
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
      args: _parseArgList(p.args),
      kwargs: _parseKwargMap(p.kwargs),
      callId: p.callId ?? 0,
      methodCall: p.methodCall ?? false,
    );
  }

  MontyOsCall _buildOsCall(CoreProgressResult p) {
    markActive();

    return MontyOsCall(
      operationName: p.functionName ?? '',
      args: _parseArgList(p.args),
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
