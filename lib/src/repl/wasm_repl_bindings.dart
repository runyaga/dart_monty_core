import 'dart:convert';
import 'dart:typed_data';

import 'package:dart_monty_core/src/platform/core_bindings.dart';
import 'package:dart_monty_core/src/platform/monty_resource_usage.dart';
import 'package:dart_monty_core/src/repl/repl_bindings.dart';
import 'package:dart_monty_core/src/wasm/wasm_bindings.dart';

/// WASM implementation of [ReplBindings].
///
/// Manages a persistent REPL session inside a Web Worker via
/// [WasmBindings]. Each instance generates a unique [_replId] so that
/// multiple concurrent [WasmReplBindings] instances can coexist within the
/// same Worker without clobbering each other's Rust heap handle.
class WasmReplBindings implements ReplBindings {
  /// Creates [WasmReplBindings] backed by [bindings].
  WasmReplBindings({required WasmBindings bindings})
    : _bindings = bindings,
      _replId = _nextReplId();

  /// Monotonically increasing counter used to generate unique REPL IDs.
  static int _counter = 0;

  /// Generates a new unique REPL ID.
  static String _nextReplId() => 'repl-${++_counter}';

  final WasmBindings _bindings;

  /// Unique identifier for this REPL handle within the shared Worker.
  final String _replId;

  bool _created = false;

  @override
  Future<void> create({String? scriptName}) async {
    await _bindings.replCreate(scriptName: scriptName, replId: _replId);
    _created = true;
  }

  @override
  Future<CoreRunResult> feedRun(String code) async {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }
    final result = await _bindings.replFeedRun(code, replId: _replId);

    return _translateWasmRunResult(result);
  }

  @override
  Future<int> detectContinuation(String source) {
    return _bindings.replDetectContinuation(source);
  }

  @override
  Future<void> setExtFns(List<String> names) =>
      _bindings.replSetExtFns(names.join(','), replId: _replId);

  @override
  Future<CoreProgressResult> feedStart(String code) async {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }
    final result = await _bindings.replFeedStart(code, replId: _replId);

    return _translateWasmProgressResult(result);
  }

  @override
  Future<CoreProgressResult> resume(String valueJson) async {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }
    final result = await _bindings.replResume(valueJson, replId: _replId);

    return _translateWasmProgressResult(result);
  }

  @override
  Future<CoreProgressResult> resumeWithError(String errorMessage) async {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }
    final errorJson = json.encode(errorMessage);
    final result = await _bindings.replResumeWithError(
      errorJson,
      replId: _replId,
    );

    return _translateWasmProgressResult(result);
  }

  @override
  Future<CoreProgressResult> resumeNotFound(String fnName) async {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }
    final fnNameJson = json.encode(fnName);
    final result = await _bindings.replResumeNotFound(
      fnNameJson,
      replId: _replId,
    );

    return _translateWasmProgressResult(result);
  }

  @override
  Future<CoreProgressResult> resumeNameLookupUndefined() async {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }

    return _translateWasmProgressResult(
      await _bindings.resumeNameLookupUndefined(),
    );
  }

  @override
  Future<CoreProgressResult> resumeAsFuture() async {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }
    final result = await _bindings.replResumeAsFuture(replId: _replId);

    return _translateWasmProgressResult(result);
  }

  @override
  Future<CoreProgressResult> resolveFutures(
    String resultsJson,
    String errorsJson,
  ) async {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }
    final result = await _bindings.replResolveFutures(
      resultsJson,
      errorsJson,
      replId: _replId,
    );

    return _translateWasmProgressResult(result);
  }

  @override
  Future<Uint8List> snapshot() {
    if (!_created) {
      throw StateError('REPL not created. Call create() first.');
    }

    return _bindings.replSnapshot(replId: _replId);
  }

  @override
  Future<void> restore(Uint8List bytes) async {
    // replRestore in the Worker frees the old handle and stores the new one
    // under the same replId — no explicit free needed here.
    await _bindings.replRestore(replId: _replId, data: bytes);
    _created = true;
  }

  @override
  Future<void> dispose() async {
    if (!_created) return;
    await _bindings.replFree(replId: _replId);
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
        args: r.args,
        kwargs: r.kwargs,
        callId: r.callId,
        methodCall: r.methodCall,
      );

  CoreProgressResult _buildOsCallResult(WasmProgressResult r) =>
      CoreProgressResult(
        state: 'os_call',
        functionName: r.functionName,
        args: r.args,
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
