import 'dart:convert';

import 'package:dart_monty_core/src/platform/core_bindings.dart';
import 'package:dart_monty_core/src/platform/monty_resource_usage.dart';
import 'package:dart_monty_core/src/repl/repl_bindings.dart';
import 'package:dart_monty_core/src/wasm/wasm_bindings.dart';

/// WASM implementation of [ReplBindings].
///
/// Manages a persistent REPL session inside a Web Worker via
/// [WasmBindings].
class WasmReplBindings implements ReplBindings {
  /// Creates [WasmReplBindings] backed by [bindings].
  WasmReplBindings({required WasmBindings bindings}) : _bindings = bindings;

  final WasmBindings _bindings;
  bool _created = false;

  @override
  Future<void> create({String? scriptName}) async {
    await _bindings.replCreate(scriptName: scriptName);
    _created = true;
  }

  @override
  Future<CoreRunResult> feedRun(String code) async {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }
    final result = await _bindings.replFeedRun(code);

    return _translateWasmRunResult(result);
  }

  @override
  Future<int> detectContinuation(String source) {
    return _bindings.replDetectContinuation(source);
  }

  @override
  void setExtFns(List<String> names) {
    // Fire-and-forget — the Worker processes this synchronously.
    // ignore: discarded_futures
    _bindings.replSetExtFns(names.join(','));
  }

  @override
  Future<CoreProgressResult> feedStart(String code) async {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }
    final result = await _bindings.replFeedStart(code);

    return _translateWasmProgressResult(result);
  }

  @override
  Future<CoreProgressResult> resume(String valueJson) async {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }
    final result = await _bindings.replResume(valueJson);

    return _translateWasmProgressResult(result);
  }

  @override
  Future<CoreProgressResult> resumeWithError(String errorMessage) async {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }
    final errorJson = json.encode(errorMessage);
    final result = await _bindings.replResumeWithError(errorJson);

    return _translateWasmProgressResult(result);
  }

  @override
  Future<void> dispose() async {
    if (!_created) return;
    await _bindings.replFree();
    _created = false;
  }

  // -----------------------------------------------------------------------
  // Translation
  // -----------------------------------------------------------------------

  CoreRunResult _translateWasmRunResult(WasmRunResult result) {
    if (result.ok) {
      return CoreRunResult(
        ok: true,
        value: result.value,
        usage: const MontyResourceUsage(
          memoryBytesUsed: 0,
          timeElapsedMs: 0,
          stackDepthUsed: 0,
        ),
        printOutput: result.printOutput,
      );
    }

    return CoreRunResult(
      ok: false,
      error: result.error,
      excType: result.excType,
      traceback: result.traceback,
      filename: result.filename,
      lineNumber: result.lineNumber,
      columnNumber: result.columnNumber,
      sourceCode: result.sourceCode,
    );
  }

  CoreProgressResult _buildCompleteResult(WasmProgressResult r) =>
      CoreProgressResult(
        state: 'complete',
        value: r.value,
        usage: const MontyResourceUsage(
          memoryBytesUsed: 0,
          timeElapsedMs: 0,
          stackDepthUsed: 0,
        ),
        printOutput: r.printOutput,
      );

  CoreProgressResult _buildPendingResult(WasmProgressResult r) =>
      CoreProgressResult(
        state: 'pending',
        functionName: r.functionName,
        arguments: r.arguments,
        kwargs: r.kwargs,
        callId: r.callId,
        methodCall: r.methodCall,
      );

  CoreProgressResult _buildOsCallResult(WasmProgressResult r) =>
      CoreProgressResult(
        state: 'os_call',
        functionName: r.functionName,
        arguments: r.arguments,
        kwargs: r.kwargs,
        callId: r.callId,
      );

  CoreProgressResult _translateWasmProgressResult(
    WasmProgressResult result,
  ) {
    if (!result.ok) {
      return CoreProgressResult(
        state: 'error',
        error: result.error,
        excType: result.excType,
        traceback: result.traceback,
      );
    }
    return switch (result.state ?? 'complete') {
      'complete' => _buildCompleteResult(result),
      'pending' => _buildPendingResult(result),
      'os_call' => _buildOsCallResult(result),
      'resolve_futures' => CoreProgressResult(
        state: 'resolve_futures',
        pendingCallIds: result.pendingCallIds,
      ),
      final s => CoreProgressResult(
        state: 'error',
        error: 'Unknown progress state: $s',
      ),
    };
  }
}
